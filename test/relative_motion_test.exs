defmodule Valimc.Physics.RelativeMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Physics.RelativeMotion, PlayerInput}

  test "bounded malformed facts and vectors fail before arithmetic" do
    for facts <- [%RelativeMotion{friction: -0.1}, %RelativeMotion{water_efficiency: 2.0}],
        do: assert({:error, :invalid_relative_motion} = RelativeMotion.speed(:air, facts))

    assert {:error, _} = RelativeMotion.accelerate({65, 0, 0}, {1, 0, 0}, 0.1, 0.0)
    assert {:error, _} = RelativeMotion.vector({1, 0, 0}, 0.1, 1_000_001)
    assert {:error, _} = PlayerInput.move_intent(%PlayerInput{buttons: 128}, 0.0)
  end
end
