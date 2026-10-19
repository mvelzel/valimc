defmodule Valimc.Physics.OrbMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.OrbMotion

  test "age increment produces a terminal decision at 6000 and never accepts an expired body" do
    assert OrbMotion.tick_age(5998) == {:ok, %{age: 5999, expired: false}}
    assert OrbMotion.tick_age(5999) == {:ok, %{age: 6000, expired: true}}
    assert OrbMotion.tick_age(-32_768) == {:ok, %{age: -32_767, expired: false}}
    assert OrbMotion.tick_age(6000) == {:error, :invalid_orb_motion}
    assert OrbMotion.tick_age(-32_769) == {:error, :invalid_orb_motion}
  end

  test "unbounded or incomplete facts refuse before producing a motion proposal" do
    for facts <- [
          %{},
          %OrbMotion{eye_water: nil},
          %OrbMotion{embedded: nil},
          %OrbMotion{no_gravity: nil},
          %OrbMotion{below: nil},
          %OrbMotion{on_ground: nil},
          %OrbMotion{friction: -1},
          %OrbMotion{friction: 1.01},
          %OrbMotion{target: {17, 0, 0}},
          %OrbMotion{lava_draws: {0, 0, 0, 16_777_216}},
          %OrbMotion{lava_draws: {0.0, 0, 0, 0}}
        ] do
      assert OrbMotion.prepare({0, 0, 0}, facts) == {:error, :invalid_orb_motion}
      assert OrbMotion.finish({0, 0, 0}, 0, facts) == {:error, :invalid_orb_motion}
    end

    assert OrbMotion.prepare({0, -64, 0}, %OrbMotion{}) == {:error, :orb_motion_limit}
    assert OrbMotion.prepare({65, 0, 0}, %OrbMotion{}) == {:error, :invalid_orb_motion}
    assert OrbMotion.finish({0, 0, 0}, 65, %OrbMotion{}) == {:error, :invalid_orb_motion}

    assert OrbMotion.launch({0, 64, 0}, {0, 0, 0}, {1.0, 0.0, 0.0}) ==
             {:error, :invalid_orb_motion}

    assert OrbMotion.launch({29_999_984, 64, 0}, {1, 0, 0}, {0.5, 0.5, 0.5}) ==
             {:error, :orb_motion_limit}
  end
end
