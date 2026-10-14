alias Valimc.Physics.{
  BlockCollisions,
  BlockEntityContext,
  BlockScan,
  Box,
  CollisionContext,
  PistonSnapshot,
  Shape
}

[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

directions = %{
  "none" => nil,
  "down" => :down,
  "up" => :up,
  "north" => :north,
  "south" => :south,
  "west" => :west,
  "east" => :east
}

pos = fn values -> values |> Enum.map(&trunc/1) |> List.to_tuple() end
region = fn {x, _, z} -> Valimc.World.region_key(Valimc.World.chunk_key(x, z)) end
# One reusable fixture process per region, never per candidate/case.
keys =
  cases
  |> Enum.flat_map(fn c ->
    [x0, _, z0, x1, _, z1] = c["box"]

    for x <- [floor(x0) - 2, floor(x1) + 2],
        z <- [floor(z0) - 2, floor(z1) + 2],
        do: region.({x, 0, z})
  end)
  |> Enum.uniq()

owners =
  for key <- keys,
      into: %{},
      do:
        {key,
         {spawn(fn ->
            receive do
              :stop -> :ok
            end
          end), make_ref()}}

try do
  for {c, index} <- Enum.with_index(cases) do
    context =
      case c["context"]["kind"] do
        "empty" ->
          CollisionContext.empty()

        "entity" ->
          f = c["context"]
          ctx = CollisionContext.entity(f["bottom"], f["descending"], f["placement"])

          if f["entity_present"],
            do:
              CollisionContext.with_entity(
                ctx,
                f["fall_distance"],
                f["falling_block"],
                f["walkable"]
              ),
            else: ctx
      end

    context =
      CollisionContext.with_piston_movement(context, Map.fetch!(directions, c["exclusion"]))

    entities =
      Map.new(c["entities"], fn f ->
        entity =
          case f["kind"] do
            "absent" ->
              BlockEntityContext.absent()

            "shulker" ->
              BlockEntityContext.shulker(f["old"], f["current"])

            "piston" ->
              PistonSnapshot.new(
                f["moved"],
                Map.fetch!(directions, f["direction"]),
                f["extending"],
                f["source"],
                f["progress"]
              )
              |> BlockEntityContext.piston()
          end

        {pos.(f["position"]), entity}
      end)

    states = Map.new(c["states"], &{pos.(&1["position"]), &1["state"]})
    box = c["box"] |> List.to_tuple() |> Box.new()
    {:ok, plan} = BlockScan.plan(box)

    observations =
      plan
      |> Enum.map(fn {p, _} -> {p, Map.get(states, p, c["default_state"])} end)
      |> Enum.group_by(fn {p, _} -> region.(p) end)
      |> Enum.flat_map(fn {key, blocks} ->
        owner = Map.fetch!(owners, key)

        Enum.map(
          Enum.chunk_every(blocks, 128),
          &%{owner: owner, region: key, revision: 17, blocks: Map.new(&1)}
        )
      end)

    # Block entities outside the queried scan are not part of its observations.
    supplied_entities = Map.take(entities, Enum.map(plan, &elem(&1, 0)))

    expected =
      Enum.map(
        c["colliders"],
        &%{
          position: pos.(&1["position"]),
          state: &1["state"],
          shape: Shape.from_world_facts!(&1["geometry"])
        }
      )

    expected_fences = Map.new(observations, &{&1.region, Map.take(&1, [:owner, :revision])})

    case BlockCollisions.collect(box, observations, context, supplied_entities) do
      {:ok, %{colliders: ^expected, fences: ^expected_fences}} ->
        :ok

      actual ->
        raise "Native block collection differs at #{index}: #{inspect(c)} actual #{inspect(actual)}"
    end
  end
after
  for {_, {pid, _}} <- owners, do: send(pid, :stop)
end

IO.puts("PASS: #{length(cases)} native ordered collider cases and retained observation fences.")
