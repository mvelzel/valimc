defmodule Valimc.PlayerPistonConnectionTest do
  # A real hosted session, with a controlled external move between its own ticks.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Data.Blocks
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{GameMode, Pistons}
  alias Valimc.{TestConn, TestPlayer}

  setup do
    ctx = TestPlayer.scope("Piston", {162_000, 643})
    TestPlayer.save(ctx, ctx.pose, Inventory.new())
    ctx
  end

  test "a hosted player retains a velocity-only slime impulse; a spectator ignores it", ctx do
    {_client, pid} = TestPlayer.login(ctx)
    x = floor(ctx.pose.x)
    z = floor(ctx.pose.z)
    pos = {x + 1, 64, z}
    moving = Blocks.state("moving_piston", %{"facing" => "east"})
    :ok = Valimc.TestBlocks.set(pos, moving)
    slime = Blocks.default_state("slime_block")
    pushes = [{pos, {slime, 5, true, false, 0.0, 0.0, 0, 0}, 0.5, moving, false}]

    result =
      TestConn.call(pid, fn state ->
        before = {state.player.x, state.player.y, state.player.z}
        next = Pistons.push(state, pushes)
        after_at = {next.player.x, next.player.y, next.player.z}
        {:reply, {before, after_at, next.player.motion.velocity}, next}
      end)

    assert {at, at, {1.0, _, _}} = result

    unchanged =
      TestConn.call(pid, fn state ->
        state = %{state | player: %{state.player | game_mode: GameMode.new(:spectator)}}
        next = Pistons.push(state, pushes)
        {:reply, next == state, next}
      end)

    assert unchanged
  end
end
