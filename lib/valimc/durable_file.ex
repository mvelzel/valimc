defmodule Valimc.DurableFile do
  @moduledoc """
  Crash-safe replacement of a small file (VMC-077a): the data goes to a
  temporary file that is synced, renamed over the target, and then the
  directory is synced, so a crash leaves either the old file or the new one,
  never a truncated or interleaved one. For settings, world metadata and the
  admin lists, written only by their one owner.
  """

  @doc "Replace `path` with `data`; creates the directory."
  def write(path, data) do
    dir = Path.dirname(path)
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, file} <- :file.open(temporary, [:write, :raw, :binary]),
         :ok <- write_sync_close(file, data),
         :ok <- File.rename(temporary, path),
         {:ok, :ok} <- Valimc.Native.fsync_dir(dir) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp write_sync_close(file, data) do
    with :ok <- :file.write(file, data), do: :file.sync(file)
  after
    :file.close(file)
  end
end
