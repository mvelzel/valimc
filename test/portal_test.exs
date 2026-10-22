defmodule Valimc.PortalTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.Portals

  defp player(mode, cooldown \\ 0),
    do: %{
      game_mode: Valimc.GameMode.new(mode),
      abilities: Valimc.PlayerAbilities.for_mode(mode),
      portal_cooldown: cooldown
    }

  # Ticks inside (true) or outside (false) the portal; returns the tick it is due on.
  defp run(player, process \\ nil, ticks) do
    ticks
    |> Enum.with_index(1)
    |> Enum.reduce_while({player, process}, fn {inside, n}, {player, process} ->
      touch = if inside, do: {:nether_portal, {0, 64, 0}}
      {player, process, due} = Portals.step(player, process, touch)
      if due, do: {:halt, {:due, n, process}}, else: {:cont, {player, process}}
    end)
  end

  test "a survival player travels on its 81st tick in a portal; a creative one at once" do
    assert {:due, 81, %{time: 81}} = run(player(:survival), List.duplicate(true, 100))
    assert {:due, 1, _} = run(player(:creative), [true])
    # Spectators touch no portal.
    assert {_, nil} = run(player(:spectator), List.duplicate(true, 100))
  end

  test "ticks outside take 4 off the time, and the process ends at 0" do
    {player, inside} = run(player(:survival), List.duplicate(true, 40))
    assert inside.time == 40
    {_, process} = run(player, inside, List.duplicate(false, 5))
    assert process.time == 20
    {_, process} = run(player, inside, List.duplicate(false, 10))
    assert process == nil
    # Back in before it ended: the time continues.
    {_, process} = run(player, inside, List.duplicate(false, 3) ++ [true])
    assert process.time == 29
  end

  test "on cooldown a touch renews it, so a player standing in the portal stays" do
    {player, process} = run(player(:creative, 10), List.duplicate(true, 50))
    assert process == nil and player.portal_cooldown == 9
    {player, _} = run(player, process, List.duplicate(false, 9))
    assert player.portal_cooldown == 0
    assert {:due, 1, _} = run(player, [true])
  end

  test "a failed destination ends the cooldown, so a player still in the portal tries again" do
    state = %{player: player(:creative, 10), portal: %{process: nil, last: {0.5, 64.0, 0.5}}}
    state = Portals.failed(state)
    assert state.player.portal_cooldown == 0 and state.portal.retry == 20
    assert {:due, 1, _} = run(state.player, [true])
  end

  test "a portal warms its destination's regions: the scaled square, or the End's platform" do
    alias Valimc.Portal.Warm
    assert {:the_nether, {82, -28, 118, 8} = square} = Warm.area(:nether_portal, {800, 64, -80})
    assert Warm.regions(square) == [{0, -1}, {0, 0}]
    assert Warm.regions({-18, -18, 18, 18}) == [{-1, -1}, {-1, 0}, {0, -1}, {0, 0}]
    assert {:the_end, {98, -2, 102, 2} = platform} = Warm.area(:end_portal, {0, 64, 0})
    assert Warm.regions(platform) == [{0, -1}, {0, 0}]
  end
end
