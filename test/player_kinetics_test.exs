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

  test "missing geometry fails and fluid contact cannot manufacture an air step" do
    p = player()
    f = frame()

    assert {:error, _} =
             PlayerKinetics.tick(p, :standing, %{f | states: Map.delete(f.states, {4, 63, 4})})

    p = %{p | motion: %{p.motion | velocity: {0.2, 0.4, 0.0}}}
    {:ok, result} = PlayerKinetics.tick(p, :standing, frame(%{{4, 64, 4} => 89}))
    refute result.supported
    assert result.velocity == p.motion.velocity
  end

  test "player dead zone is horizontal magnitude rather than independent axes" do
    assert PlayerKinetics.normalize({0.0029, 0.0029, 0.0029}) == {0.0029, 0.0, 0.0029}
    assert PlayerKinetics.normalize({0.002, 0.003, 0.002}) == {0.0, 0.003, 0.0}
    assert {:error, :invalid_velocity} = PlayerKinetics.jump({65.0, 0.0, 0.0}, 1.0, false, 0.0)
  end
end
