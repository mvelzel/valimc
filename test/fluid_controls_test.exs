defmodule Valimc.Physics.FluidControlsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FluidControls

  test "deep liquid floats while shallow grounded water requests the ordinary jump" do
    {:ok, deep} =
      FluidControls.step({0.0, 0.0, 0.0}, %FluidControls{water: 1.0, jump: true, on_ground: true})

    assert deep == %{velocity: {0.0, 0.03999999910593033, 0.0}, ground_jump: false}

    {:ok, shallow} =
      FluidControls.step({0.0, 0.0, 0.0}, %FluidControls{water: 0.4, jump: true, on_ground: true})

    assert shallow.ground_jump and shallow.velocity == {0.0, 0.0, 0.0}
    {:ok, airborne} = FluidControls.step({0.0, 0.0, 0.0}, %FluidControls{water: 0.1, jump: true})
    refute airborne.ground_jump
    assert elem(airborne.velocity, 1) > 0
  end

  test "sink precedes normalization and jump; creative flight suppresses fluid input" do
    {:ok, both} =
      FluidControls.step({0.0, 0.04, 0.0}, %FluidControls{water: 1.0, shift: true, jump: true})

    assert both.velocity == {0.0, 0.03999999910593033, 0.0}

    {:ok, flying} =
      FluidControls.step({0.0, 0.04, 0.0}, %FluidControls{
        water: 1.0,
        shift: true,
        jump: true,
        flying: true
      })

    assert flying == %{velocity: {0.0, 0.04, 0.0}, ground_jump: false}
  end

  test "invalid depths and overflowing impulses cannot reach geometry owners" do
    assert {:error, :invalid_fluid_controls} ==
             FluidControls.step({0, 0, 0}, %FluidControls{water: -1})

    assert {:error, :invalid_fluid_controls} == FluidControls.step({65, 0, 0}, %FluidControls{})

    assert {:error, :fluid_input_limit} ==
             FluidControls.step({0, 64, 0}, %FluidControls{water: 1, jump: true})
  end
end
