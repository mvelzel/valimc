defmodule Valimc.PlayerLifeTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerHealth, PlayerLife, PlayerSnapshot}

  defp player do
    %{
      x: -3.25,
      y: 64.5,
      z: 17.75,
      yaw: 90.0,
      pitch: -25.0,
      game_mode: Valimc.GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      input: %Valimc.PlayerInput{buttons: 33, shared_flags: 2, load_ticks: 0},
      motion: %Valimc.PlayerMotion{fall_distance: 15.0, velocity: {0.1, -2.0, 0.2}},
      environment: %Valimc.PlayerEnvironment{frozen_ticks: 77, damage_phase: 39, damage_due: true},
      health: %PlayerHealth{value: 0.0, hurt_ticks: 10, cooldown: 20},
      pose: :crouching,
      last_death: {1, 2, 3}
    }
  end

  test "each death records current floored coordinates; respawn resets owner controls and retains location" do
    dead = PlayerLife.die(player())
    assert dead.last_death == {-4, 64, 17} and dead.pose == :dying
    assert dead.input.buttons == 0 and dead.input.shared_flags == 0
    assert dead.motion.velocity == {0.0, 0.0, 0.0} and dead.motion.fall_distance == 0
    assert dead.environment.damage_phase == 0 and not dead.environment.damage_due
    alive = PlayerLife.respawn(dead)
    assert alive.fire_ticks == 0
    assert alive.health == %PlayerHealth{} and alive.pose == :standing
    assert alive.food == %Valimc.PlayerFood{}
    assert alive.last_death == dead.last_death and alive.environment.frozen_ticks == 0
    assert alive.environment.damage_phase == 0 and not alive.environment.damage_due
    assert alive.input.load_ticks == 60 and {alive.x, alive.y, alive.z} == {0.5, 64.0, 0.5}

    assert PlayerLife.die(%{alive | health: %{alive.health | value: 0.0}}).last_death ==
             {0, 64, 0}

    health = %PlayerHealth{value: 0.0, death_ticks: 19}
    assert PlayerHealth.tick(health).death_ticks == 20
    assert health |> PlayerHealth.tick() |> PlayerHealth.tick() |> Map.get(:death_ticks) == 20

    assert PlayerLife.die(Map.put(player(), :fire_ticks, 300)).fire_ticks == 0
    assert PlayerLife.dead(Map.put(player(), :fire_ticks, -20)).fire_ticks == -20
  end

  test "last death is checksummed with health and journal; sealed invalid coordinates are rejected" do
    snapshot = PlayerSnapshot.capture(PlayerLife.die(player()), %Inventory{})
    uuid = <<7::128>>
    assert {:ok, <<"VMCPOSE", 10, _::binary>> = bytes} = PlayerSnapshot.encode(uuid, snapshot)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, uuid)
    assert decoded.last_death == {-4, 64, 17} and decoded.health.value == 0
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid, decoded)
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _location::binary-size(13), rest::binary>> = payload

    for location <- [
          <<2>>,
          <<1, 30_000_000::signed-32, 64::signed-32, 0::signed-32>>,
          <<1, 0::signed-32, 1_000_001::signed-32, 0::signed-32>>
        ] do
      payload = header <> location <> rest

      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(payload <> :crypto.hash(:sha256, payload), uuid)
    end

    for location <- [:bad, {0.5, 64, 0}, {30_000_000, 64, 0}] do
      assert {:error, :invalid_last_death} =
               PlayerSnapshot.encode(uuid, %{snapshot | last_death: location})
    end
  end
end
