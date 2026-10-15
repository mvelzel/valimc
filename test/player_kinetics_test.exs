defmodule Valimc.PlayerKineticsTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, PlayerAbilities, PlayerInput, PlayerKinetics, PlayerMotion}
  alias Valimc.Physics.{BlockCollisions, PlayerPose}

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

    owner = {self(), make_ref()}

    observations =
      blocks
      |> Map.merge(changes)
      |> Enum.chunk_every(128)
      |> Enum.map(&%{owner: owner, region: {0, 0}, revision: 1, blocks: Map.new(&1)})

    {:ok, f} = BlockCollisions.prepare(observations)
    f
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

  test "airborne scratch gravity and a ceiling leave the client anchor intact" do
    p = %{player() | y: 68.0}
    f = frame()
    {:ok, first} = PlayerKinetics.tick(p, :standing, f)
    assert first.velocity == {0.0, -0.0784000015258789, 0.0}
    p = %{p | motion: PlayerKinetics.apply_result(p.motion, first)}
    {:ok, second} = PlayerKinetics.tick(p, :standing, f)
    assert elem(second.velocity, 1) < elem(first.velocity, 1)
    refute second.physical_ground or second.settled
    assert p.y == 68.0

    p = player()
    p = %{p | motion: %{p.motion | velocity: {0.0, 0.42, 0.0}}}
    {:ok, hit} = PlayerKinetics.tick(p, :standing, frame(%{{4, 66, 4} => 1}))
    assert elem(hit.velocity, 1) < 0
    assert p.y == 64.0
  end

  test "an edge uses the actual supporting ice block even when the center is over air" do
    p = %{player() | x: 5.1}
    p = %{p | motion: %{p.motion | velocity: {0.1, -0.0784, 0.0}, physical_ground: true}}

    {:ok, result} =
      PlayerKinetics.tick(p, :standing, frame(%{{4, 63, 4} => 8597, {5, 63, 4} => 0}))

    assert elem(result.velocity, 0) > 0.089 and elem(result.velocity, 0) < 0.090
  end

  test "accepted jump uses the fenced honey jump factor" do
    p = player()
    p = %{p | motion: %{p.motion | on_ground: true}}
    target = %{p | y: 64.21}
    {:ok, geometry} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})

    {:ok, result} =
      PlayerKinetics.packet(
        p,
        target,
        {0.0, target.y - p.y, 0.0},
        0,
        geometry.box,
        frame(%{{4, 63, 4} => 25173})
      )

    assert elem(result.velocity, 1) > 0.2099 and elem(result.velocity, 1) < 0.2101
    assert p.motion.velocity == {0.0, 0.0, 0.0}
  end

  test "slime contact bounces while Shift suppresses it" do
    p = player()
    p = %{p | motion: %{p.motion | velocity: {0.0, -2.0, 0.0}}}
    f = frame(%{{4, 63, 4} => 14379})
    {:ok, bounced} = PlayerKinetics.tick(p, :standing, f)
    assert bounced.bounced and elem(bounced.velocity, 1) > 1.8
    p = %{p | input: %{p.input | shared_flags: 2}}
    {:ok, suppressed} = PlayerKinetics.tick(p, :standing, f)
    refute suppressed.bounced
    assert elem(suppressed.velocity, 1) < 0
  end

  test "missing geometry fails and fluid contact selects water drag instead of air" do
    p = player()
    f = frame()

    assert {:error, _} =
             PlayerKinetics.tick(p, :standing, %{f | states: Map.delete(f.states, {4, 63, 4})})

    p = %{p | motion: %{p.motion | velocity: {0.2, 0.4, 0.0}}}
    {:ok, result} = PlayerKinetics.tick(p, :standing, frame(%{{4, 64, 4} => 89}))
    assert result.supported and result.water
    assert result.velocity == {0.1600000023841858, 0.3150000047683716, 0.0}
  end

  test "player dead zone is horizontal magnitude rather than independent axes" do
    assert PlayerKinetics.normalize({0.0029, 0.0029, 0.0029}) == {0.0029, 0.0, 0.0029}
    assert PlayerKinetics.normalize({0.002, 0.003, 0.002}) == {0.0, 0.003, 0.0}
    assert {:error, :invalid_velocity} = PlayerKinetics.jump({65.0, 0.0, 0.0}, 1.0, false, 0.0)
  end

  test "stationary fluid input evolves velocity/fall while accepted position stays anchored" do
    pool = for x <- 3..5, y <- 64..66, z <- 3..5, into: %{}, do: {{x, y, z}, 89}
    f = frame(pool)
    p = player()
    p = %{p | motion: %{p.motion | fall_distance: 7.0}, input: %{p.input | buttons: 16}}
    {:ok, floating} = PlayerKinetics.tick(p, :standing, f)
    assert elem(floating.velocity, 1) > 0.026 and elem(floating.velocity, 1) < 0.028
    assert PlayerKinetics.apply_result(p.motion, floating).fall_distance == 0.0
    assert p.y == 64.0 and floating.water and not floating.settled

    {:ok, sinking} =
      PlayerKinetics.tick(%{p | y: 64.2, input: %{p.input | buttons: 32}}, :standing, f)

    assert elem(sinking.velocity, 1) < -0.036

    lava = frame(Map.new(pool, fn {pos, _} -> {pos, 105} end))
    {:ok, in_lava} = PlayerKinetics.tick(%{p | input: %{p.input | buttons: 0}}, :standing, lava)
    assert in_lava.lava and not in_lava.water
    assert in_lava.velocity == {0.0, -0.02, 0.0}
    assert PlayerKinetics.apply_result(p.motion, in_lava).fall_distance == 3.5

    flying = %{p | abilities: %{p.abilities | flying: true}, input: %{p.input | buttons: 48}}
    {:ok, flight} = PlayerKinetics.tick(flying, :standing, f)
    assert flight.velocity == {0.0, 0.0, 0.0}
  end

  test "fluid body rise does not become an ordinary ground jump" do
    p = player()
    p = %{p | motion: %{p.motion | on_ground: true}}
    target = %{p | y: 64.04}
    {:ok, body} = PlayerPose.geometry(:standing, {p.x, p.y, p.z})
    pool = for x <- 3..5, y <- 64..66, z <- 3..5, into: %{}, do: {{x, y, z}, 89}
    {:ok, result} = PlayerKinetics.packet(p, target, {0.0, 0.04, 0.0}, 0, body.box, frame(pool))
    assert result.velocity == {0.0, 0.0, 0.0} and result.water

    refute PlayerKinetics.signature(p) ==
             PlayerKinetics.signature(%{p | input: %{p.input | buttons: 16}})
  end

  test "fluid wall escape is fenced by complete collision and liquid observations" do
    p = player()
    p = %{p | y: 64.5, motion: %{p.motion | velocity: {0.6, 0.0, 0.0}}}
    changes = %{{4, 64, 4} => 89, {5, 64, 4} => 1, {5, 65, 4} => 1}
    {:ok, escape} = PlayerKinetics.tick(p, :standing, frame(changes))
    assert elem(escape.velocity, 1) == 0.30000001192092896
    {:ok, blocked} = PlayerKinetics.tick(p, :standing, frame(Map.put(changes, {4, 65, 4}, 96)))
    assert elem(blocked.velocity, 1) < 0.0
    assert p.x == 4.5 and p.y == 64.5
  end

  test "swim pitch uses observed surface/jump conditions without moving the accepted anchor" do
    p = player()
    p = %{p | y: 64.6, motion: %{p.motion | swimming: true}, input: %{p.input | shared_flags: 8}}
    p = Map.put(p, :pitch, -90.0)
    shallow = for x <- 3..5, z <- 3..5, into: %{}, do: {{x, 64, z}, 89}
    {:ok, surface} = PlayerKinetics.tick(p, :swimming, frame(shallow))
    assert surface.velocity == {0.0, 0.0, 0.0}
    deep = Map.put(shallow, {4, 65, 4}, 89)
    {:ok, rising} = PlayerKinetics.tick(p, :swimming, frame(deep))
    assert elem(rising.velocity, 1) > 0.048 and elem(rising.velocity, 1) < 0.049

    {:ok, jumping} =
      PlayerKinetics.tick(%{p | input: %{p.input | buttons: 16}}, :swimming, frame(shallow))

    assert elem(jumping.velocity, 1) > 0.078 and elem(jumping.velocity, 1) < 0.079
    {:ok, diving} = PlayerKinetics.tick(%{p | pitch: 90.0}, :swimming, frame(shallow))
    assert elem(diving.velocity, 1) < -0.068

    {:ok, flying} =
      PlayerKinetics.tick(%{p | abilities: %{p.abilities | flying: true}}, :swimming, frame(deep))

    assert flying.velocity == {0.0, 0.0, 0.0}
    assert p.y == 64.6 and p.motion.velocity == {0.0, 0.0, 0.0}

    refute PlayerKinetics.signature(p) == PlayerKinetics.signature(%{p | pitch: 90.0})
    dry = %{p | motion: %PlayerMotion{}, input: %{p.input | shared_flags: 0}}
    assert PlayerKinetics.signature(dry) == PlayerKinetics.signature(%{dry | pitch: 90.0})
  end
end
