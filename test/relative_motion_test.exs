defmodule Valimc.Physics.RelativeMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Physics.RelativeMotion, PlayerInput}

  test "opposed input cancels and diagonals normalize before rotation" do
    assert PlayerInput.move_intent(%PlayerInput{buttons: 15}, 17.0) == {:ok, {0.0, 0.0, 0.0}}
    {:ok, {x, y, z}} = PlayerInput.move_intent(%PlayerInput{buttons: 5}, 0.0)
    assert x == z and y == 0.0
    assert_in_delta x * x + z * z, 1.0, 1.0e-15
    {:ok, {x, _, z}} = PlayerInput.move_intent(%PlayerInput{buttons: 1}, 90.0)
    assert_in_delta x, -1.0, 1.0e-10
    assert_in_delta z, 0.0, 1.0e-10
  end

  test "tiny input dead zone precedes acceleration and rates keep native contexts" do
    assert RelativeMotion.vector({0.0001, 0.0, 0.0}, 1.0, 0.0) == {:ok, {0.0, 0.0, 0.0}}
    {:ok, {x, _, _}} = RelativeMotion.vector({0.0004, 0.0, 0.0}, 1.0, 0.0)
    assert x == 0.0004
    {:ok, ice} = RelativeMotion.speed(:air, %RelativeMotion{on_ground: true, friction: 0.98})
    assert ice < 0.024
    {:ok, flight} = RelativeMotion.speed(:air, %RelativeMotion{flying: true, sprint: true})
    assert flight > 0.099 and flight < 0.101
    assert {:ok, 0.019999999552965164} = RelativeMotion.speed(:water, %RelativeMotion{})

    assert {:ok, 0.09999999403953552} =
             RelativeMotion.speed(:water, %RelativeMotion{on_ground: true, water_efficiency: 1.0})
  end

  test "bounded malformed facts and vectors fail before arithmetic" do
    for facts <- [%RelativeMotion{friction: -0.1}, %RelativeMotion{water_efficiency: 2.0}],
        do: assert({:error, :invalid_relative_motion} = RelativeMotion.speed(:air, facts))

    assert {:error, _} = RelativeMotion.accelerate({65, 0, 0}, {1, 0, 0}, 0.1, 0.0)
    assert {:error, _} = RelativeMotion.vector({1, 0, 0}, 0.1, 1_000_001)
    assert {:error, _} = PlayerInput.move_intent(%PlayerInput{buttons: 128}, 0.0)
  end
end
