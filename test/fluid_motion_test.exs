defmodule Valimc.Physics.FluidMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FluidMotion

  test "bounded input and escape probes fail rather than creating unbounded geometry work" do
    assert {:error, :invalid_fluid_motion} == FluidMotion.prepare({65, 0, 0}, %FluidMotion{})

    assert {:error, :invalid_fluid_motion} ==
             FluidMotion.prepare({0, 0, 0}, %FluidMotion{kind: :air})

    assert {:error, :invalid_fluid_motion} ==
             FluidMotion.prepare({0, 0, 0}, %FluidMotion{water_efficiency: 1.1})

    assert {:error, :invalid_fluid_motion} ==
             FluidMotion.prepare({0, 0, 0}, %FluidMotion{gravity: 2.0})

    assert {:error, :invalid_fluid_motion} ==
             FluidMotion.prepare({0, 0, 0}, %FluidMotion{new_y: 65})

    assert {:error, :fluid_escape_limit} ==
             FluidMotion.prepare({0, 64, 0}, %FluidMotion{horizontal_collision: true, old_y: 64})
  end
end
