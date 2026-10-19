defmodule Valimc.RegionTickTest do
  use ExUnit.Case, async: false
  alias Valimc.World
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

  test "early timers rotate identity without advancing; late timers do not queue catch-up ticks" do
    clock = TickClock.new(make_ref(), 100)
    assert {:early, early, 1} = TickClock.advance(clock, clock.token, 149)
    assert early.tick == 0 and early.deadline == 150 and early.token != clock.token
    assert TickClock.advance(early, clock.token, 150) == :stale
    assert {:ok, late, 250, 1} = TickClock.advance(early, early.token, 400)
    assert late.tick == 1 and late.deadline == 401
    assert {:ok, recovered, 0, 50} = TickClock.advance(late, late.token, 401)
    assert recovered.tick == 2 and recovered.deadline == 451
  end

  test "real region ignores raw/foreign ticks and reschedules an early current token" do
    key = {-650, -650}
    {:ok, {pid, epoch}} = World.owner(key)
    on_exit(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid) end)

    # Hold the due time far ahead so ordinary scheduler timing cannot race assertions.
    state =
      :sys.replace_state(pid, fn state ->
        %{
          state
          | tick_clock: %{
              state.tick_clock
              | deadline: System.monotonic_time(:millisecond) + 60_000
            }
        }
      end)

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

  test "a replacement owner rejects its predecessor's timer while another owner advances" do
    key = {-651, -651}
    {:ok, {old, _}} = World.owner(key)
    old_token = :sys.get_state(old).tick_clock.token
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, old)
    {:ok, {replacement, epoch}} = World.owner(key)
    {:ok, {independent, other_epoch}} = World.owner({-652, -652})

    on_exit(fn ->
      for pid <- [replacement, independent],
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    state = hold_deadline(replacement)
    other = hold_deadline(independent)
    assert state.tick_clock.epoch == epoch
    assert other.tick_clock.epoch == other_epoch
    refute elem(old_token, 0) == epoch
    send(replacement, {:tick, old_token})
    assert {:ok, _} = Region.observe_blocks({replacement, epoch}, [])
    assert :sys.get_state(replacement).tick_clock == state.tick_clock

    due = System.monotonic_time(:millisecond)
    :sys.replace_state(independent, &put_in(&1.tick_clock.deadline, due))
    send(independent, {:tick, other.tick_clock.token})
    assert {:ok, _} = Region.observe_blocks({independent, other_epoch}, [])
    assert :sys.get_state(independent).tick_clock.tick == other.tick_clock.tick + 1
    assert :sys.get_state(replacement).tick_clock == state.tick_clock
  end

  defp hold_deadline(pid) do
    :sys.replace_state(pid, fn state ->
      put_in(state.tick_clock.deadline, System.monotonic_time(:millisecond) + 60_000)
    end)
  end
end
