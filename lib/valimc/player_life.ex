defmodule Valimc.PlayerLife do
  @moduledoc "Player-local death/respawn state preparation; persistence and effects belong to the owner."
  alias Valimc.{GameMode, PlayerEnvironment, PlayerHealth, PlayerInput, PlayerMotion}

  def valid_location?(nil), do: true

  def valid_location?({x, y, z}),
    do:
      is_integer(x) and abs(x) <= 29_999_984 and is_integer(z) and abs(z) <= 29_999_984 and
        is_integer(y) and abs(y) <= 1_000_000

  def valid_location?(_), do: false

  def dead(player) do
    player = %{
      player
      | last_death:
          Map.get(player, :last_death) || {floor(player.x), floor(player.y), floor(player.z)},
        input: %PlayerInput{load_ticks: player.input.load_ticks},
        motion: %PlayerMotion{settled: true},
        environment: PlayerEnvironment.tick(player.environment, false),
        pose: :dying
    }

    if Map.has_key?(player, :fire_ticks),
      do: %{player | fire_ticks: min(0, player.fire_ticks)},
      else: player
  end

  @doc "The respawned player at `spawn` (`Valimc.World.PlayerSpawn.find/1`)."
  def respawn(player, spawn \\ Valimc.World.Spawn.pose()) do
    %{
      player
      | x: spawn.x,
        y: spawn.y,
        z: spawn.z,
        yaw: spawn.yaw,
        pitch: 0.0,
        health: %PlayerHealth{maximum: player.health.maximum, value: player.health.maximum},
        abilities: GameMode.abilities(player.game_mode, false),
        input: %PlayerInput{},
        motion: %PlayerMotion{},
        environment: %PlayerEnvironment{},
        pose: :standing
    }
    |> Map.put(:air_supply, Valimc.PlayerAir.maximum())
    |> Map.put(:fire_ticks, 0)
    |> Map.put(:effects, %{})
    |> Map.put(:absorption, 0.0)
    |> Map.put(:food, %Valimc.PlayerFood{})
    |> Map.put(:use_flags, 0)
    |> Map.put(:equipment, %{})
  end

  def die(player),
    do: dead(%{player | last_death: {floor(player.x), floor(player.y), floor(player.z)}})
end
