defmodule Valimc.PlayerEnvironmentTest do
  use ExUnit.Case, async: true
  alias Valimc.Living.Freezing
  alias Valimc.World.View

  test "body samples use deflated contact, complete cells and bounded work" do
    frame = View.of(%{{0, 64, 0} => 30519, {0, 65, 0} => 0, {0, 66, 0} => 0})

    assert {:ok, true} = Freezing.sample(frame, {0.2, 64.0, 0.2, 0.8, 65.8, 0.8})
    assert {:ok, false} = Freezing.sample(frame, {0.2, 65.0, 0.2, 0.8, 66.8, 0.8})

    assert {:error, :incomplete_environment_frame} =
             Freezing.sample(frame, {0.2, 64.0, 0.2, 1.2, 65.8, 0.8})

    assert {:error, :environment_body_limit} =
             Freezing.sample(frame, {0, 0, 0, 1_000_000, 1_000_000, 1_000_000})

    assert {:error, :environment_body_limit} = Freezing.sample(frame, {0, 0, 0, 0, 0, 0})
  end

  test "retired clock messages cannot create a simulation tick" do
    clock = Valimc.World.TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    state = %{phase: :play, simulation_clock: clock}
    assert {:noreply, ^state} = Valimc.Connection.handle_info({:player_tick, make_ref()}, state)
  end
end
