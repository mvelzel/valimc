defmodule Valimc.PlayerKineticsTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.{GameMode, Abilities, Input, Kinetics, Motion}
  alias Valimc.Native
  alias Valimc.Player.{MotionQuery, PoseQuery}
  alias Valimc.Physics.Kernel
  alias Valimc.Data.PlayerPose

  defp player do
    %{
      x: 4.5,
      y: 64.0,
      z: 4.5,
      yaw: 0.0,
      entity_id: 1,
      pose: :standing,
      input: Input.loaded(%Input{}),
      abilities: Abilities.for_mode(:creative),
      game_mode: GameMode.new(:creative),
      motion: %Motion{}
    }
  end

  defp frame(changes \\ %{}) do
    blocks =
      for x <- 0..9,
          y <- 60..70,
          z <- 0..9,
          into: %{},
          do: {{x, y, z}, if(y < 64, do: 1, else: 0)}

    Valimc.World.View.of(Map.merge(blocks, changes))
  end

  test "Jump Boost changes packet power, bounds the jump query and fences only amplifier changes" do
    id = Valimc.Data.EffectTypes.id("jump_boost")

    p =
      Map.put(player(), :living, %Valimc.Living{effects: %{id => [{300, 1, false, true, true}]}})

    p = %{p | motion: %{p.motion | on_ground: true}}
    {:ok, body} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})
    {:ok, result} = MotionQuery.run(p, %{p | y: 64.5}, 0, frame())
    assert result.kinetics.packet.velocity == {0.0, 0.6200000047683716, 0.0}
    shorter = %{p | living: %Valimc.Living{effects: %{id => [{299, 1, false, true, true}]}}}
    assert Kinetics.signature(p) == Kinetics.signature(shorter)
    high = %{p | living: %Valimc.Living{effects: %{id => [{300, 255, false, true, true}]}}}
    refute Kinetics.signature(p) == Kinetics.signature(high)

    query = fn player ->
      Native.physics_player_parity(:kinetic_query, {Kernel.player(player), body.box, true})
    end

    {:ok, ordinary} = query.(p)
    {:ok, expanded} = query.(high)
    assert elem(expanded, 4) > 91.0 and elem(expanded, 4) > elem(ordinary, 4) + 25

    assert Native.physics_player_parity(:jump, {{0.0, 2.0, 0.0}, 1.0, false, 0.0, 0}) ==
             {:ok, {0.0, 2.0, 0.0}}
  end

  test "packet paths are observed after travel, including crossed blocks outside the final body" do
    p = %{player() | x: 2.5}
    f = frame(%{{3, 64, 4} => 2362})
    target = %{p | x: 5.5}
    {:ok, result} = MotionQuery.run(p, target, 1, f)
    packet = result.kinetics.packet
    assert length(packet.paths) == 1 and packet.stuck_multiplier == {0.0, 0.0, 0.0}
    tick = result.kinetics.tick
    assert tick.reset_fall and elem(tick.stuck_multiplier, 0) == 0.25
    assert tick.paths == [] and length(result.motion.paths) == 1
    candidate = %{target | motion: result.motion}
    refute Kinetics.signature(target) == Kinetics.signature(candidate)
    {:ok, query} = Kernel.player_query(candidate, nil)
    assert elem(query, 0) <= 2.2 and elem(query, 3) >= 5.8
    incomplete = %{f | supplied: Map.delete(f.supplied, {3, 64, 4})}
    assert {:error, {:missing_block, _}} = MotionQuery.run(p, target, 1, incomplete)
  end

  test "sneaking backs off an edge after slowing is consumed, and reads the ground it needs" do
    p = player()
    p = %{p | input: %{p.input | shared_flags: 2}, motion: %{p.motion | on_ground: true}}
    removed = for x <- 5..9, z <- 0..9, into: %{}, do: {{x, 63, z}, 0}
    f = frame(removed)
    {:ok, guarded} = MotionQuery.run(p, %{p | x: p.x + 1.0}, 1, f)
    assert elem(guarded.moved, 0) > 5.2 and elem(guarded.moved, 0) < 5.3
    stuck = %{p | motion: %{p.motion | stuck_multiplier: {0.25, 0.05000000074505806, 0.25}}}
    {:ok, slowed} = MotionQuery.run(stuck, %{p | x: p.x + 1.0}, 1, f)
    assert slowed.moved == {4.75, 64.0, 4.5}
    missing = %{f | supplied: Map.delete(f.supplied, {4, 63, 4})}

    assert {:error, {:missing_block, _}} =
             MotionQuery.run(p, %{p | x: p.x + 0.1}, 1, missing)
  end

  test "a resting tick on the floor evolves only kinetic fields, never displacement or fall" do
    p = player()
    p = %{p | motion: %{p.motion | fall_distance: 2.75, known_movement: {0.1, 0.0, 0.0}}}
    f = frame()

    p =
      Enum.reduce(1..3, p, fn _, p ->
        {:ok, result} = PoseQuery.run(p, f)
        %{p | motion: result.ticked}
      end)

    assert p.y == 64.0
    assert p.motion.physical_ground and p.motion.settled
    assert elem(p.motion.velocity, 1) < -0.078
    assert p.motion.fall_distance == 2.75
    assert p.motion.known_movement == {0.1, 0.0, 0.0}
  end

  test "dry climbing caps before collision and resets fall only on the logical tick" do
    p = player()
    p = %{p | y: 65.2, motion: %{p.motion | velocity: {0.7, -2.0, 0.0}, fall_distance: 5.0}}
    f = frame(%{{4, 65, 4} => 7308})
    {:ok, rest} = PoseQuery.run(p, f)
    assert_in_delta elem(rest.kinetics.velocity, 0), 0.15000000596046448 * 0.91, 1.0e-8
    assert_in_delta elem(rest.kinetics.velocity, 1), -0.225400010, 1.0e-8
    assert rest.kinetics.reset_fall and rest.ticked.fall_distance == 0.0
    {:ok, still} = MotionQuery.run(p, p, 0, f)
    assert still.motion.fall_distance == 5.0
  end

  test "known movement survives its tick boundary, then an idle client tick clears it" do
    motion = Motion.accept(%Motion{}, {0.2, -0.5, 0.0}, 2, false)
    motion = Motion.finish_tick(motion)
    assert motion.known_movement == {0.2, -0.5, 0.0}
    refute motion.received
    idle = Motion.finish_tick(motion)
    assert idle.known_movement == {0.0, 0.0, 0.0}
    assert idle.fall_distance == motion.fall_distance
    assert idle.horizontal_collision
  end
end
