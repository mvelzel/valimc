defmodule Valimc.PlayerMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerMotion

  test "accepted downward deltas round individually, landing consumes accumulated distance" do
    motion = PlayerMotion.accept(%PlayerMotion{}, {0.0, -0.0784, 0.0}, 0, false)
    assert motion.fall_distance == 0.07840000092983246
    motion = PlayerMotion.accept(motion, {0.0, -0.0784, 0.0}, 0, false)
    assert motion.fall_distance == 0.15680000185966492

    assert PlayerMotion.fall_step(motion.fall_distance, -0.2, true, false) ==
             {0.0, 0.35680000483989716}

    assert PlayerMotion.accept(motion, {0.0, -0.2, 0.0}, 1, false).fall_distance == 0.0
  end

  test "water suppresses accumulation; an upward move and flight clear previous falls" do
    assert PlayerMotion.fall_step(2.0, -1.0, false, true) == {2.0, nil}
    assert PlayerMotion.fall_step(2.0, -1.0, true, true) == {0.0, 2.0}
    motion = %PlayerMotion{fall_distance: 8.0}
    assert PlayerMotion.accept(motion, {0.0, 0.01, 0.0}, 0, false).fall_distance == 0.0
    assert PlayerMotion.accept(motion, {0.0, -0.1, 0.0}, 0, true).fall_distance == 0.0
    assert PlayerMotion.flight(motion, true).fall_distance == 0.0
    assert PlayerMotion.flight(motion, false) == motion
  end

  test "all wire flag bytes use native low bits and do not infer physical support" do
    import Bitwise

    for flags <- 0..255 do
      motion = PlayerMotion.accept(%PlayerMotion{}, {0.0, 0.0, 0.0}, flags, false)
      assert motion.on_ground == ((flags &&& 1) != 0)
      assert motion.horizontal_collision == ((flags &&& 2) != 0)
    end
  end

  test "known movement survives its tick boundary, then an idle client tick clears it" do
    motion = PlayerMotion.accept(%PlayerMotion{}, {0.2, -0.5, 0.0}, 2, false)
    motion = PlayerMotion.finish_tick(motion)
    assert motion.known_movement == {0.2, -0.5, 0.0}
    refute motion.received
    idle = PlayerMotion.finish_tick(motion)
    assert idle.known_movement == {0.0, 0.0, 0.0}
    assert idle.fall_distance == motion.fall_distance
    assert idle.horizontal_collision
  end
end
