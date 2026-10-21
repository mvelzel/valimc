defmodule Valimc.World.Spawn do
  @moduledoc """
  The world spawn (VMC-021d, VMC-077a), vanilla's `RespawnData`: dimension,
  block position, yaw and pitch, held by `Valimc.World.Settings` (vanilla
  worlds' search result, an import's `level.dat` spawn, or (0, 64, 0) in the
  overworld). New players, respawns without a respawn point, the End's exit
  and `/spawn` go to that dimension and stand at the centre of that block.
  """
  alias Valimc.World.Settings

  def dimension, do: Settings.get(:spawn).dimension
  def position, do: Settings.get(:spawn).position
  def yaw, do: Settings.get(:spawn).yaw
  def pitch, do: Settings.get(:spawn).pitch

  @doc """
  `/setworldspawn`: the new spawn, saved before it is published; every player
  gets the new position. `:unchanged` when it already was the spawn.
  """
  def set(dimension, {_, _, _} = position, yaw, pitch) do
    spawn = %{dimension: dimension, position: position, yaw: yaw * 1.0, pitch: pitch * 1.0}

    case Settings.put(spawn: spawn) do
      :ok ->
        Valimc.Players.broadcast(:spawn_position)
        :ok

      other ->
        other
    end
  end

  @doc "The player pose at the spawn: the block's centre, facing its yaw and pitch."
  def pose do
    %{dimension: _, position: {x, y, z}, yaw: yaw, pitch: pitch} = Settings.get(:spawn)
    %{x: x + 0.5, y: y * 1.0, z: z + 0.5, yaw: yaw, pitch: pitch}
  end
end
