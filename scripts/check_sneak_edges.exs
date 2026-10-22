alias Valimc.Native
alias Valimc.Physics.{BlockScan, Kernel}
alias Valimc.Data.PlayerPose
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- cases do
  supports = Enum.map(c["supports"], vec)

  facts = %{
    flying: c["flying"],
    shift: c["shift"],
    on_ground: c["ground"],
    fall_distance: c["fall"] * 1.0,
    max_step: c["step"] * 1.0,
    player: c["mover"] in ["self", "player"]
  }

  {:ok, {requested, queries}} =
    Native.physics_player_parity(
      :sneak_edges,
      {vec.(c["box"]), vec.(c["requested"]), facts, supports}
    )

  unless requested == List.to_tuple(c["result"]) and
           queries == Enum.map(c["queries"], &List.to_tuple/1),
         do: raise("Native edge mismatch: #{inspect({c, requested, queries}, limit: :infinity)}")

  if queries != [] do
    [a, y, b, d, _, f] = c["box"]
    [dx, dy, dz] = c["requested"]

    player = %{
      x: (a + d) * 0.5,
      y: y,
      z: (b + f) * 0.5,
      game_mode: Valimc.Player.GameMode.new(:creative),
      abilities: Valimc.Player.Abilities.for_mode(:creative),
      input: %Valimc.Player.Input{shared_flags: 2},
      motion: %Valimc.Player.Motion{on_ground: c["ground"], fall_distance: c["fall"]}
    }

    target = %{player | x: player.x + dx, y: y + dy, z: player.z + dz}
    {:ok, packet_box} = Valimc.Player.Kinetics.player_query(player, target)
    {:ok, standing} = PlayerPose.geometry(:standing, {player.x, y, player.z})
    tick_player = %{player | motion: %{player.motion | velocity: {dx, dy, dz}}}

    {:ok, tick_box} =
      Native.physics_player_parity(
        :kinetic_query,
        {Valimc.Player.Kinetics.player(tick_player), standing.box, false}
      )

    for box <- [packet_box, tick_box] do
      case BlockScan.plan(box, 1024) do
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
