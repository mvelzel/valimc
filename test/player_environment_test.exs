defmodule Valimc.PlayerEnvironmentTest do
  use ExUnit.Case, async: true

  test "retired clock messages cannot create a simulation tick" do
    clock = Valimc.World.TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    state = %{phase: :play, simulation_clock: clock}
    assert {:noreply, ^state} = Valimc.Connection.handle_info({:player_tick, make_ref()}, state)
  end
end
