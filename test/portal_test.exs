defmodule Valimc.PortalTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Player.Portals
  alias Valimc.Portal.{Blocks, Fire, Forcer, Shape}

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

  test "arrival poses turn the traveller's motion with its rotation (ROTATE_DELTA)" do
    alias Valimc.Portal.Motion
    source = %{position: {1.0, 64.0, 2.0}, delta: {1.0, -0.5, 0.0}, yaw: 0.0, pitch: 10.0}

    # A nether portal of the other axis turns the yaw a quarter, and the motion with it.
    change = %{position: {8.5, 70.0, 3.5}, delta: {0.0, 0.0, 0.0}, yaw: 90.0, pitch: 0.0}
    turned = Motion.absolute(source, change, Motion.portal())
    assert turned.position == {8.5, 70.0, 3.5}
    assert turned.yaw == 90.0 and turned.pitch == 10.0
    assert turned.delta == {0.0, -0.5, 1.0}

    # Into the End: west, whatever the yaw; a gateway keeps the motion as it is.
    into = Motion.absolute(%{source | yaw: 90.0}, %{change | yaw: 90.0}, Motion.into_end())
    assert into.yaw == 90.0 and into.delta == source.delta
    same = Motion.absolute(source, %{change | yaw: 0.0}, Motion.portal())
    assert same.delta == source.delta and same.yaw == 0.0
  end

  test "a shape's opening runs as vanilla's betweenClosed" do
    air = Valimc.Registry.Blocks.default_state("air")
    # A 2 × 3 frame along Z at x 5.
    frame =
      for z <- -1..2,
          y <- -1..3,
          z in [-1, 2] or y in [-1, 3],
          into: %{},
          do: {{5, 64 + y, z}, Blocks.obsidian()}

    read = &Map.get(frame, &1, air)
    assert {:ok, shape} = Shape.find_empty(read, {5, 64, 0}, :x, -64)
    assert {shape.axis, shape.width, shape.height} == {:z, 2, 3}
    assert Shape.positions(shape) == for(z <- 0..1, y <- 64..66, do: {5, y, z})
    assert Fire.ignite(read, {5, 64, 0}, :overworld, -64) == {:portal, shape}
    assert Fire.ignite(read, {5, 64, 0}, :the_end, -64) |> elem(0) == :fire
  end

  test "the spiral visits the centre, then legs turning east to south" do
    assert Forcer.spiral({0, 0, 0}, 1, {1, 0, 0}, {0, 0, 1}) |> Enum.to_list() ==
             [
               {0, 0, 0},
               {1, 0, 0},
               {1, 0, 1},
               {0, 0, 1},
               {-1, 0, 1},
               {-1, 0, 0},
               {-1, 0, -1},
               {0, 0, -1},
               {1, 0, -1}
             ]
  end

  test "snapshots keep whether the player saw the credits (v23)" do
    uuid = <<77::128>>
    base = %{pose: %{x: 1.5, y: 64.0, z: 2.5, yaw: 0.0, pitch: 0.0}, inventory: %Inventory{}}

    assert {:ok, <<"VMCPOSE", 2, _::binary>>} =
             PlayerSnapshot.encode(uuid, Map.put(base, :seen_credits, false))

    snapshot = Map.merge(base, %{seen_credits: true, dimension: :the_end})
    assert {:ok, <<"VMCPOSE", 23, _::binary>> = bytes} = PlayerSnapshot.encode(uuid, snapshot)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid)
    assert restored.seen_credits and restored.dimension == :the_end
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid, restored)
  end
end
