defmodule Valimc.RegionTickTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Region, TickClock}

  test "owner incarnations and one-use timers reject foreign and replayed ticks" do
    first = TickClock.new(make_ref(), -100)
    other = TickClock.new(make_ref(), -100)
    assert TickClock.advance(first, other.token, -50) == :stale
    assert TickClock.advance(first, {first.epoch, make_ref()}, -50) == :stale
    assert {:ok, next, 0, 50} = TickClock.advance(first, first.token, -50)
    assert next.tick == 1 and next.deadline == 0
    assert next.epoch == first.epoch and next.token != first.token
    assert TickClock.advance(next, first.token, 0) == :stale
  end

  test "real region ignores raw/foreign ticks and reschedules an early current token" do
    key = {-650, -650}
    {:ok, {pid, epoch}} = Valimc.TestWorld.owner(key)
    on_exit(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid) end)

    # Hold the due time far ahead so ordinary scheduler timing cannot race assertions.
    state = hold_deadline(pid)

    token = state.tick_clock.token
    send(pid, :tick)
    send(pid, {:tick, {make_ref(), make_ref()}})
    assert {:ok, _} = Region.observe_blocks({pid, epoch}, [])
    assert Valimc.TestConn.state(pid).tick_clock == state.tick_clock
    send(pid, {:tick, token})
    assert {:ok, _} = Region.observe_blocks({pid, epoch}, [])
    after_early = Valimc.TestConn.state(pid)
    assert after_early.tick_clock.tick == state.tick_clock.tick
    assert after_early.tick_clock.deadline == state.tick_clock.deadline
    assert after_early.tick_clock.token != token
    refute Process.read_timer(state.tick_timer)
    assert is_integer(Process.read_timer(after_early.tick_timer))
    send(pid, {:tick, token})
    assert {:ok, _} = Region.observe_blocks({pid, epoch}, [])
    assert Valimc.TestConn.state(pid).tick_clock == after_early.tick_clock
  end

  # Hold the due time far ahead. The timer armed at load may already have fired, so
  # cancel it and take a fresh token: a tick still queued then carries a stale one
  # and is ignored, however slowly this test runs (VMC-073).
  defp hold_deadline(pid) do
    :sys.replace_state(pid, fn state ->
      Process.cancel_timer(state.tick_timer)
      clock = state.tick_clock

      %{
        state
        | tick_clock: %{
            clock
            | deadline: System.monotonic_time(:millisecond) + 60_000,
              token: {elem(clock.token, 0), make_ref()}
          }
      }
    end)
  end
end
