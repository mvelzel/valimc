alias Valimc.Native

alias Valimc.Physics.{BlockScan, BorderSnapshot, CollisionContext, EntityCollisions, Kernel}
alias Valimc.Data.PlayerPose

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

region = fn {x, _, z} -> Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z)) end

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

    frame = Valimc.World.View.of(Map.new(Enum.flat_map(blocks, &Map.to_list(&1.blocks))))
    {:ok, bounds} = BorderSnapshot.bounds(border)
    position = position |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()

    # The entity policy picks colliders per fit box; these fixtures' boxes all
    # lie around the standing body, so its candidates serve every pose.
    {:ok, colliders} = EntityCollisions.collect(geometry.box, 1, entities)

    {:ok, {selected, fits, queries}} =
      Native.physics_player_parity(
        :pose_fit,
        {Kernel.native(frame, nil), PlayerPose.id(String.to_existing_atom(c["current"])), intent,
         position, Kernel.context(CollisionContext.empty()),
         {Enum.map(colliders.colliders, & &1.box), bounds, {elem(position, 0), elem(position, 2)}}}
      )

    result = %{
      pose: PlayerPose.from_id(selected),
      fits: Map.new(fits, fn {pose, fit} -> {PlayerPose.from_id(pose), fit} end),
      queries: Enum.map(queries, &PlayerPose.from_id/1)
    }

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
