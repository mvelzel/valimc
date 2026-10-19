defmodule Valimc.Physics.OrbMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.OrbMotion

  test "launch flips all velocity axes toward the supplied direction and respects normalize's float edge" do
    assert {:ok, launch} = OrbMotion.launch({0.0, 64.0, 0.0}, {1, 0, 0}, {0.0, 0.5, 0.5})
    assert launch.position == {0.25, 64.0, 0.0}
    assert launch.velocity == {0.2, -0.2, -0.0}

    edge = 9.999999747378752e-6
    assert {:ok, at_edge} = OrbMotion.launch({0.0, 64.0, 0.0}, {edge, 0, 0}, {0.5, 0.5, 0.5})
    assert at_edge.position == {0.25, 64.0, 0.0}

    assert {:ok, below} =
             OrbMotion.launch({0.0, 64.0, 0.0}, {edge - 1.0e-15, 0, 0}, {0.5, 0.5, 0.5})

    assert below.position == {0.0, 64.0, 0.0}
    assert {:ok, tiny} = OrbMotion.launch({0.0, 64.0, 0.0}, {1.0e-200, 0, 0}, {0.0, 0.5, 0.5})
    assert tiny.velocity == {-0.2, 0.2, 0.0}
  end

  test "gravity is suppressed inside blocks; eye-water caps ascent even without gravity" do
    assert {:ok, {0.3, -0.03, -0.2}} = OrbMotion.prepare({0.3, 0, -0.2}, %OrbMotion{})

    for facts <- [%OrbMotion{embedded: true}, %OrbMotion{no_gravity: true}] do
      assert {:ok, {0.3, 0.2, -0.2}} = OrbMotion.prepare({0.3, 0.2, -0.2}, facts)
    end

    for facts <- [
          %OrbMotion{eye_water: true},
          %OrbMotion{eye_water: true, embedded: true, no_gravity: true}
        ] do
      assert {:ok, {0.29700000286102296, 0.05999999865889549, -0.19800000190734865}} =
               OrbMotion.prepare({0.3, 0.2, -0.2}, facts)
    end
  end

  test "lava replaces earlier acceleration; an already selected target accelerates afterward" do
    lava = %OrbMotion{eye_water: true, lava_draws: {0, 16_777_215, 16_777_215, 0}}

    assert {:ok, {-0.19999998807907104, 0.20000000298023224, 0.19999998807907104}} =
             OrbMotion.prepare({12, 12, 12}, lava)

    assert {:ok, base} = OrbMotion.prepare({0, 0, 0}, %OrbMotion{no_gravity: true})

    assert {:ok, ^base} =
             OrbMotion.prepare({0, 0, 0}, %OrbMotion{no_gravity: true, target: {0, 0, 0}})

    assert {:ok, {0.025, +0.0, +0.0}} =
             OrbMotion.prepare({0, 0, 0}, %OrbMotion{no_gravity: true, target: {4.0, 0, 0}})

    assert {:ok, {+0.0, +0.0, +0.0}} =
             OrbMotion.prepare({0, 0, 0}, %OrbMotion{no_gravity: true, target: {8.0, 0, 0}})
  end

  test "friction scales every post-move axis; bounce replaces Y using pre-move speed, with strict gravity edge" do
    facts = %OrbMotion{on_ground: true, below: true, friction: 0.6}

    assert {:ok, {0.5880000591278076, 0.4, 0.5880000591278076}} =
             OrbMotion.finish({1, 10, 1}, -1.0, facts)

    assert {:ok, {0.5880000591278076, 0.5880000591278076, 0.5880000591278076}} =
             OrbMotion.finish({1, 1, 1}, -0.03, facts)

    assert {:ok, {0.5880000591278076, 0.004, 0.5880000591278076}} =
             OrbMotion.finish({1, 1, 1}, -0.01, %{facts | no_gravity: true})
  end

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
