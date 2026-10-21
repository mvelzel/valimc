defmodule Valimc.PlayerKineticsTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, PlayerAbilities, PlayerInput, PlayerKinetics, PlayerMotion}
  alias Valimc.Physics.PlayerPose

  defp player do
    %{
      x: 4.5,
      y: 64.0,
      z: 4.5,
      yaw: 0.0,
      entity_id: 1,
      pose: :standing,
      input: PlayerInput.loaded(%PlayerInput{}),
      abilities: PlayerAbilities.for_mode(:creative),
      game_mode: GameMode.new(:creative),
      motion: %PlayerMotion{}
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
    id = Valimc.Protocol.EffectTypes.id("jump_boost")

    p =
      Map.put(player(), :living, %Valimc.Living{effects: %{id => [{300, 1, false, true, true}]}})

    p = %{p | motion: %{p.motion | on_ground: true}}
    {:ok, body} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})

    {:ok, result} =
      PlayerKinetics.packet(p, %{p | y: 64.5}, {0.0, 0.5, 0.0}, 0, body.box, frame())

    assert result.velocity == {0.0, 0.6200000047683716, 0.0}
    shorter = %{p | living: %Valimc.Living{effects: %{id => [{299, 1, false, true, true}]}}}
    assert PlayerKinetics.signature(p) == PlayerKinetics.signature(shorter)
    high = %{p | living: %Valimc.Living{effects: %{id => [{300, 255, false, true, true}]}}}
    refute PlayerKinetics.signature(p) == PlayerKinetics.signature(high)
    {:ok, ordinary} = PlayerKinetics.query_box(body.box, p, true)
    {:ok, expanded} = PlayerKinetics.query_box(body.box, high, true)
    assert elem(expanded, 4) > 91.0 and elem(expanded, 4) > elem(ordinary, 4) + 25
    assert {:ok, velocity} = PlayerKinetics.jump({0.0, 2.0, 0.0}, 1, false, 0, 0)
    assert velocity == {0.0, 2.0, 0.0}
  end

  test "packet paths are observed after travel, including crossed blocks outside the final body" do
    p = %{player() | x: 2.5}
    f = frame(%{{3, 64, 4} => 2362})
    {:ok, body} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})
    target = %{p | x: 5.5}
    {:ok, packet} = PlayerKinetics.packet(p, target, {3.0, 0.0, 0.0}, 1, body.box, f)
    assert packet.paths.count == 1 and packet.stuck_multiplier == {0.0, 0.0, 0.0}
    candidate = %{target | motion: PlayerKinetics.apply_result(p.motion, packet)}
    {:ok, tick} = PlayerKinetics.tick(candidate, :standing, f)
    assert tick.reset_fall and elem(tick.stuck_multiplier, 0) == 0.25
    assert tick.paths.count == 0 and candidate.motion.paths.count == 1
    refute PlayerKinetics.signature(target) == PlayerKinetics.signature(candidate)

    {:ok, query} = PlayerKinetics.query_box(body.box, candidate)
    assert elem(query, 0) <= 2.2 and elem(query, 3) >= 5.8
    incomplete = %{f | supplied: Map.delete(f.supplied, {3, 64, 4})}

    assert {:error, :incomplete_fire_frame} =
             PlayerKinetics.tick(candidate, :standing, incomplete)
  end

  test "edge backoff follows slowing consumption and uses one fenced support frame" do
    p = player()
    p = %{p | input: %{p.input | shared_flags: 2}, motion: %{p.motion | on_ground: true}}
    {:ok, body} = PlayerPose.geometry(:crouching, {p.x, p.y, p.z})
    removed = for x <- 5..9, z <- 0..9, into: %{}, do: {{x, 63, z}, 0}
    f = frame(removed)

    {:ok, guarded} =
      PlayerKinetics.prepare_collision(p, {1.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, body.box, f, true)

    assert elem(guarded.requested, 0) < 0.8 and elem(guarded.requested, 0) > 0.7
    assert guarded.velocity == {1.0, 0.0, 0.0}
    stuck = %{p | motion: %{p.motion | stuck_multiplier: {0.25, 0.05000000074505806, 0.25}}}

    {:ok, slowed} =
      PlayerKinetics.prepare_collision(stuck, {1.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, body.box, f, true)

    assert slowed.requested == {0.25, 0.0, 0.0} and slowed.velocity == {0.0, 0.0, 0.0}
    missing = %{f | supplied: Map.delete(f.supplied, {4, 63, 4})}

    assert {:error, {:missing_block, _}} =
             PlayerKinetics.prepare_collision(
               p,
               {0.1, 0.0, 0.0},
               {0.1, 0.0, 0.0},
               body.box,
               missing,
               true
             )

    {:ok, upward} =
      PlayerKinetics.prepare_collision(
        p,
        {1.0, 0.01, 0.0},
        {1.0, 0.01, 0.0},
        body.box,
        missing,
        true
      )

    assert upward.requested == {1.0, 0.01, 0.0}
  end

  test "floor fixed point evolves only kinetic fields, never accepted displacement/fall" do
    p = player()
    p = %{p | motion: %{p.motion | fall_distance: 2.75, known_movement: {0.1, 0.0, 0.0}}}
    f = frame()

    p =
      Enum.reduce(1..3, p, fn _, p ->
        {:ok, result} = PlayerKinetics.tick(p, :standing, f)
        %{p | motion: PlayerKinetics.apply_result(p.motion, result)}
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
    {:ok, result} = PlayerKinetics.tick(p, :standing, f)
    assert_in_delta elem(result.velocity, 0), 0.15000000596046448 * 0.91, 1.0e-8
    assert_in_delta elem(result.velocity, 1), -0.225400010, 1.0e-8
    assert result.reset_fall
    assert PlayerKinetics.apply_result(p.motion, result).fall_distance == 0.0
    assert p.x == 4.5 and p.y == 65.2 and p.motion.fall_distance == 5.0

    {:ok, body} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})
    {:ok, packet} = PlayerKinetics.packet(p, p, {0.0, 0.0, 0.0}, 0, body.box, f)
    assert PlayerKinetics.apply_result(p.motion, packet).fall_distance == 5.0
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
