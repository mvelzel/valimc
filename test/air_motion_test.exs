defmodule Valimc.AirMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.AirMotion

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
