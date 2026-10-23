defmodule Valimc.Player.Life do
  @moduledoc "Player-local death/respawn state preparation; persistence and effects belong to the owner."
  alias Valimc.Player.{GameMode, Input, Motion}
  alias Valimc.Living

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
        input: %Input{load_ticks: player.input.load_ticks},
        motion: %Motion{settled: true},
        living: Living.die(player.living),
        pose: :dying
    }

    # The death location names its dimension (VMC-026b).
    Map.put_new(player, :death_dimension, Map.get(player, :dimension, :overworld))
  end

  @doc """
  The respawned player at `spawn`: its respawn point's
  (`Valimc.Player.RespawnPoint`) or the world spawn's
  (`Valimc.World.PlayerSpawn.find/1`), in that spawn's dimension.
  """
  def respawn(player, spawn) do
    %{
      player
      | x: spawn.x,
        y: spawn.y,
        z: spawn.z,
        yaw: spawn.yaw,
        pitch: spawn.pitch,
        living: Living.respawn(player.living),
        abilities: GameMode.abilities(player.game_mode, false),
        input: %Input{},
        motion: %Motion{},
        pose: :standing
    }
    |> Map.put(:food, %Valimc.Player.Food{})
    |> Map.update(:progression, %Valimc.Player.Progression{}, fn progression ->
      %{progression | experience: %Valimc.Player.Experience{}}
    end)
    |> Map.put(:use_flags, 0)
    |> Map.put(:equipment, %{})
    |> Map.put(:dimension, spawn.dimension)
  end

  def die(player) do
    player
    # Dying restarts the time since rest (`ServerPlayer.die`, VMC-040a).
    |> Map.put(:time_since_rest, 0)
    |> Map.put(:death_dimension, Map.get(player, :dimension, :overworld))
    |> Map.put(:last_death, {floor(player.x), floor(player.y), floor(player.z)})
    |> dead()
  end
end
