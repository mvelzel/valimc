defmodule Valimc.AirMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.AirMotion

  test "zero velocity starts falling; repeated updates retain gravity and drag" do
    assert {:ok, {+0.0, -0.0784000015258789, +0.0} = first} =
             AirMotion.step({0.0, 0.0, 0.0}, %AirMotion{})

    assert {:ok, {+0.0, second, +0.0}} = AirMotion.step(first, %AirMotion{})
    assert second < elem(first, 1)

    {:ok, {_, terminal, _}} =
      Enum.reduce(1..2000, {:ok, {0.0, 0.0, 0.0}}, fn _, {:ok, v} ->
        AirMotion.step(v, %AirMotion{})
      end)

    assert_in_delta terminal, -3.920003814700893, 1.0e-10
  end

  test "ground friction affects horizontal drag; levitation and friction bypass retain order" do
    {:ok, {air_x, _, _}} = AirMotion.step({1, 0, -1}, %AirMotion{})
    {:ok, {ground_x, _, _}} = AirMotion.step({1, 0, -1}, %AirMotion{on_ground: true})
    assert ground_x < air_x

    assert {:ok, {1.0, 0.020000000000000004, -1.0}} =
             AirMotion.step({1, 0, -1}, %AirMotion{levitation: 1, discard_friction: true})

    assert {:ok, {+0.0, -0.0, -0.0}} =
             AirMotion.step({1, -1, -1}, %AirMotion{air_drag_modifier: 2048})
  end

  test "invalid observations reject rather than applying a default environment" do
    for facts <- [
          %{on_ground: false},
          %AirMotion{gravity: 2},
          %AirMotion{friction: -0.1},
          %AirMotion{air_drag_modifier: 2049},
          %AirMotion{levitation: -1},
          %AirMotion{discard_friction: nil}
        ] do
      assert {:error, :invalid_air_motion} = AirMotion.step({0, 0, 0}, facts)
    end

    assert {:error, :invalid_air_motion} = AirMotion.step({60_000_001, 0, 0}, %AirMotion{})
  end
end
