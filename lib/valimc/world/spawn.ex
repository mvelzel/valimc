defmodule Valimc.World.Spawn do
  @moduledoc """
  The world spawn (VMC-021d): block position and yaw, from the world's
  `world.json` (written by an import from the vanilla `level.dat`), or (0, 64, 0)
  for a generated flat world. New players, respawns and `/spawn` stand at the
  centre of that block.
  """
  @key {__MODULE__, :spawn}
  @default %{position: {0, 64, 0}, yaw: 0.0}

  @doc "Read the spawn of the configured world once, at application start."
  def load! do
    spawn =
      with base when is_binary(base) <- Valimc.config(:world_path),
           {:ok, text} <- File.read(path(base)),
           {:ok, %{"spawn" => [x, y, z], "yaw" => yaw}}
           when is_integer(x) and is_integer(y) and is_integer(z) and is_number(yaw) <-
             JSON.decode(text) do
        %{position: {x, y, z}, yaw: yaw * 1.0}
      else
        _ -> @default
      end

    :persistent_term.put(@key, spawn)
  end

  @doc "The world metadata file of a world directory."
  def path(base), do: Path.join(base, "world.json")

  @doc "Write a world's spawn (imports)."
  def write(base, {x, y, z}, yaw) do
    File.write(path(base), JSON.encode!(%{"spawn" => [x, y, z], "yaw" => yaw * 1.0}))
  end

  def position, do: :persistent_term.get(@key, @default).position
  def yaw, do: :persistent_term.get(@key, @default).yaw

  @doc "The player pose at the spawn: the block's centre, facing its yaw."
  def pose do
    {x, y, z} = position()
    %{x: x + 0.5, y: y * 1.0, z: z + 0.5, yaw: yaw(), pitch: 0.0}
  end
end
