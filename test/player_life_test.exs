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
