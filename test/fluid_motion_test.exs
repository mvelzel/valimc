defmodule Valimc.Physics.FluidMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FluidMotion

  test "water and shallow/deep lava retain distinct drag and gravity" do
    {:ok, water} = FluidMotion.prepare({1.0, 1.0, -1.0}, %FluidMotion{falling: false})
    assert water.escape_query == nil
    assert water.velocity == {0.800000011920929, 0.795000011920929, -0.800000011920929}

    {:ok, lava} = FluidMotion.prepare({1.0, 1.0, -1.0}, %FluidMotion{kind: :lava, falling: false})
    assert lava.velocity == {0.5, 0.48, -0.5}

    {:ok, shallow} =
      FluidMotion.prepare({1.0, 1.0, -1.0}, %FluidMotion{
        kind: :lava,
        shallow: true,
        falling: false
      })

    assert shallow.velocity == {0.5, 0.7750000119209289, -0.5}
  end

  test "surface escape needs both horizontal contact and a separately resolved free path" do
    {:ok, result} =
      FluidMotion.prepare({0.0, -0.1, 0.2}, %FluidMotion{
        horizontal_collision: true,
        old_y: 64.0,
        new_y: 63.9
      })

    assert FluidMotion.finish(result, false) == result.velocity
    assert FluidMotion.finish(result, true) == {0.0, 0.30000001192092896, 0.1600000023841858}
    assert elem(result.escape_query, 1) > 0.6

    {:ok, no_wall} = FluidMotion.prepare({0.0, -0.1, 0.2}, %FluidMotion{})
    assert FluidMotion.finish(no_wall, true) == no_wall.velocity
  end

  test "climbing and sprinting affect water while lava retains its separate gravity" do
    {:ok, climb} =
      FluidMotion.prepare({0.0, -1.0, 0.0}, %FluidMotion{
        horizontal_collision: true,
        climbable: true,
        sprint: true
      })

    assert elem(climb.velocity, 1) == 0.1600000023841858
    {:ok, lava} = FluidMotion.prepare({0.0, 0.0, 0.0}, %FluidMotion{kind: :lava, sprint: true})
    assert elem(lava.velocity, 1) == -0.02
  end

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
