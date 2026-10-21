defmodule Valimc.World.Schema do
  @moduledoc """
  Vanilla world-file kinds and their data version (VMC-020).

  Every NBT file in a 26.3 world records the `DataVersion` its schema follows:
  `level.dat` inside its `Data` compound, every other file (player, `data/*.dat`,
  region, entity and POI chunks) at the root. ValiMC reads the pinned version;
  chunks from 26.2 on are upgraded to it first (`Valimc.World.DataFix`,
  VMC-028d), and newer versions are unknown.
  """

  @type kind :: :level | :player | :data | :chunk | :entities | :poi | :unknown

  @doc "The data version ValiMC reads and writes."
  def data_version, do: Valimc.Version.data_version()

  @doc "The kind of a file, from its path relative to the world directory."
  @spec kind(Path.t()) :: kind()
  def kind(path) do
    parts = Path.split(path)
    name = List.last(parts)
    folder = parts |> Enum.drop(-1) |> List.last()

    cond do
      parts == ["level.dat"] -> :level
      Path.extname(name) == ".mca" and folder == "region" -> :chunk
      Path.extname(name) == ".mca" and folder == "entities" -> :entities
      Path.extname(name) == ".mca" and folder == "poi" -> :poi
      Path.extname(name) == ".dat" and Enum.take(parts, 2) == ["players", "data"] -> :player
      Path.extname(name) == ".dat" and "data" in Enum.drop(parts, -1) -> :data
      true -> :unknown
    end
  end

  @doc "The data version a file's root records, or nil."
  def version(:level, {:compound, %{"Data" => {:compound, data}}}), do: int(data["DataVersion"])
  def version(:level, _), do: nil
  def version(_kind, {:compound, root}), do: int(root["DataVersion"])

  @doc """
  Accept a root of `kind` only at the pinned data version:
  `{:ok, version}`, or an error naming a missing, older or newer version.
  """
  def check(:unknown, _), do: {:error, :unknown_world_file}

  def check(kind, root) do
    current = data_version()

    case version(kind, root) do
      nil -> {:error, :missing_data_version}
      ^current -> {:ok, current}
      older when older < current -> {:error, {:older_data_version, older}}
      newer -> {:error, {:newer_data_version, newer}}
    end
  end

  defp int({:int, value}), do: value
  defp int(_), do: nil
end
