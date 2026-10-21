alias Valimc.Physics.{
  BlockScan,
  BorderSnapshot,
  CollisionContext,
  PlayerPose,
  PoseFit
}

import Bitwise
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
keys = [:sleeping, :swimming, :fall_flying, :spin_attack, :shift, :flying, :spectator, :passenger]

owners =
  for x <- -1..0,
      z <- -1..0,
      into: %{},
      do:
        {{x, z},
         {spawn(fn ->
            receive do
              :stop -> :ok
            end
          end), make_ref()}}

region = fn {x, _, z} -> Valimc.World.region_key(Valimc.World.chunk_key(x, z)) end

try do
  for {c, index} <- Enum.with_index(cases) do
    position = List.to_tuple(c["position"])

    intent =
      for {key, bit} <- Enum.with_index(keys),
          into: %{},
          do: {key, (c["intent"] &&& 1 <<< bit) != 0}

    {:ok, geometry} = PlayerPose.geometry(:standing, position)
    {:ok, plan} = BlockScan.plan(geometry.box)

    states =
      Map.new(
        c["blocks"],
        &{&1["position"] |> Enum.map(fn n -> trunc(n) end) |> List.to_tuple(), &1["state"]}
      )

    blocks =
      plan
      |> Enum.group_by(fn {p, _} -> region.(p) end)
      |> Enum.map(fn {key, positions} ->
        %{
          owner: owners[key],
          region: key,
          revision: 5,
          blocks: Map.new(positions, fn {p, _} -> {p, Map.get(states, p, 0)} end)
        }
      end)

    entities =
      Enum.map(c["entities"], fn e ->
        %{
          id: e["id"],
          box: List.to_tuple(e["box"]),
          collidable: e["collidable"],
          spectator: e["spectator"],
          same_vehicle: e["same_vehicle"]
        }
      end)

    {:ok, border} = BorderSnapshot.new(0, 0, c["diameter"])

    observations = %{
      blocks: Valimc.World.View.of(Map.new(Enum.flat_map(blocks, &Map.to_list(&1.blocks)))),
      entities: entities,
      border: border,
      subject: 1
    }

    {:ok, result} =
      PoseFit.select(
        String.to_existing_atom(c["current"]),
        struct!(PlayerPose, intent),
        position,
        CollisionContext.empty(),
        observations
      )

    expected_fits =
      Map.new(c["fits"], fn {name, fits} -> {String.to_existing_atom(name), fits} end)

    if Atom.to_string(result.pose) != c["selected"] or result.fits != expected_fits or
         Enum.map(result.queries, &Atom.to_string/1) != c["queries"],
       do:
         raise(
           "Native composed pose mismatch at #{index}: #{inspect(c)} actual #{inspect(result)}"
         )
  end
after
  for {_, {pid, _}} <- owners, do: send(pid, :stop)
end

IO.puts(
  "PASS: #{length(cases)} native occupancy and ordered pose fits read through a block view."
)
