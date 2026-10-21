alias Valimc.{PlayerKinetics, Physics.AirMotion}
alias Valimc.Physics.{BlockScan, Box, CollisionContext}
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
bits = fn t -> for n <- Tuple.to_list(t), do: <<n::float-64>> end

Enum.each(data["jumps"], fn c ->
  {:ok, result} =
    PlayerKinetics.jump(
      List.to_tuple(c["initial"]),
      c["factor"],
      c["sprint"],
      c["yaw"],
      c["amplifier"]
    )

  if bits.(result) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Jump mismatch #{inspect(c)} #{inspect(result)}")
end)

Enum.each(data["air"], fn c ->
  {_, y, _} = initial = List.to_tuple(c["initial"])

  {:ok, result} =
    PlayerKinetics.air(
      initial,
      y,
      %AirMotion{on_ground: c["ground"], friction: c["friction"]},
      c["flying"]
    )

  if bits.(result) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Player travel mismatch #{inspect(c)} #{inspect(result)}")
end)

Enum.each(data["normalization"], fn c ->
  actual = PlayerKinetics.normalize(List.to_tuple(c["initial"]))

  if bits.(actual) != bits.(List.to_tuple(c["velocity"])),
    do: raise("Native dead zone mismatch #{inspect(c)}")
end)

Enum.each(data["support"], fn c ->
  box = List.to_tuple(c["box"])
  {x, y, z} = List.to_tuple(c["position"])
  supplied = Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]})
  {:ok, plan} = BlockScan.plan(Box.expand_towards(box, {0.0, -0.51, 0.0}))

  groups =
    Enum.group_by(plan, fn {{px, _, pz}, _} ->
      Valimc.World.region_key(Valimc.World.chunk_key(px, pz))
    end)

  observations =
    Enum.flat_map(groups, fn {key, values} ->
      owner =
        {spawn(fn ->
           receive do
             :stop -> :ok
           end
         end), make_ref()}

      Enum.chunk_every(values, 128)
      |> Enum.map(fn chunk ->
        %{
          owner: owner,
          region: key,
          revision: 1,
          blocks: Map.new(chunk, fn {p, _} -> {p, Map.get(supplied, p, 0)} end)
        }
      end)
    end)

  frame = Valimc.World.View.of(Map.new(Enum.flat_map(observations, &Map.to_list(&1.blocks))))

  {:ok, result} =
    PlayerKinetics.material(
      frame,
      box,
      {x, y, z},
      CollisionContext.entity(y, false) |> CollisionContext.with_entity(0.0, false, false)
    )

  for pid <- observations |> Enum.map(&elem(&1.owner, 0)) |> Enum.uniq(), do: send(pid, :stop)
  support = if result.support, do: Tuple.to_list(result.support.position)

  if support != c["support"] or Tuple.to_list(result.below_position) != c["below"],
    do:
      raise(
        "Native support mismatch #{inspect(c)} #{inspect(result.below_position)} #{inspect(support)}"
      )

  {:ok, landing} =
    Valimc.PlayerLanding.material(
      frame,
      box,
      {x, y, z},
      CollisionContext.entity(y, false) |> CollisionContext.with_entity(0.0, false, false)
    )

  unless Tuple.to_list(landing.position) == c["landing"],
    do: raise("Native landing material position differs #{inspect({c, landing})}")
end)

IO.puts(
  "PASS: #{length(data["jumps"])} native jumps, #{length(data["air"])} player travel branches, #{length(data["normalization"])} dead zones and #{length(data["support"])} supporting-block selections."
)
