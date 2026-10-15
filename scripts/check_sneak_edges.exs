alias Valimc.Physics.{BlockScan, Box, CollisionQuery, PlayerPose, SneakEdges}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  supports = Enum.map(c["supports"], &List.to_tuple/1)
  Process.put(:edge_queries, [])

  free? = fn box ->
    Process.put(:edge_queries, [box | Process.get(:edge_queries)])
    {:ok, not Enum.any?(supports, &Box.intersects?(box, &1))}
  end

  facts = %SneakEdges{
    flying: c["flying"],
    shift: c["shift"],
    on_ground: c["ground"],
    fall_distance: c["fall"],
    max_step: c["step"],
    mover: String.to_existing_atom(c["mover"])
  }

  {:ok, actual} =
    SneakEdges.step(List.to_tuple(c["box"]), List.to_tuple(c["requested"]), facts, free?)

  queries = Process.delete(:edge_queries) |> Enum.reverse()

  unless actual.requested == List.to_tuple(c["result"]) and actual.queries == length(queries) and
           queries == Enum.map(c["queries"], &List.to_tuple/1),
         do: raise("Native edge mismatch: #{inspect({c, actual, queries}, limit: :infinity)}")

  if queries != [] do
    [a, y, b, d, _, f] = c["box"]
    [dx, dy, dz] = c["requested"]

    player = %{
      x: (a + d) * 0.5,
      y: y,
      z: (b + f) * 0.5,
      game_mode: Valimc.GameMode.new(:creative),
      abilities: Valimc.PlayerAbilities.for_mode(:creative),
      input: %Valimc.PlayerInput{shared_flags: 2},
      motion: %Valimc.PlayerMotion{on_ground: c["ground"], fall_distance: c["fall"]}
    }

    target = %{player | x: player.x + dx, y: y + dy, z: player.z + dz}
    {:ok, packet_box} = Valimc.PlayerMotionQuery.query_box(player, target)
    {:ok, standing} = PlayerPose.geometry(:standing, {player.x, y, player.z})
    tick_player = %{player | motion: %{player.motion | velocity: {dx, dy, dz}}}
    {:ok, tick_box} = Valimc.PlayerKinetics.query_box(standing.box, tick_player)

    for box <- [packet_box, tick_box] do
      case BlockScan.plan(box, CollisionQuery.frame_cell_limit()) do
        {:ok, plan} ->
          acquired = MapSet.new(plan, &elem(&1, 0))

          for query <- queries do
            {:ok, needed} = BlockScan.plan(query)

            unless Enum.all?(needed, &MapSet.member?(acquired, elem(&1, 0))),
              do: raise("Native edge support outside admitted frame #{inspect({c, box, query})}")
          end

        {:error, :block_scan_limit} ->
          :ok
      end
    end
  end
end

IO.puts(
  "PASS: #{length(cases)} native player edge displacements/query traces and admitted packet/tick frame coverage."
)
