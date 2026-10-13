defmodule Valimc.World.Store do
  use GenServer

  @moduledoc "A per-region file writer; disk I/O never runs in a player or ticking region process."
  def start_link(key), do: GenServer.start_link(__MODULE__, key)
  def load(pid), do: GenServer.call(pid, :load)

  def snapshot(pid, edits, owner, revision),
    do: GenServer.cast(pid, {:snapshot, edits, owner, revision})

  def flush(pid, edits), do: GenServer.call(pid, {:flush, edits}, 15_000)
  @impl true
  def init({rx, rz}) do
    path =
      case Valimc.config(:world_path) do
        nil -> nil
        base -> Path.join(base, "r.#{rx}.#{rz}.etf")
      end

    {:ok, path}
  end

  @impl true
  def handle_call(:load, _from, path) do
    edits =
      case path && File.read(path) do
        {:ok, data} ->
          {:valimc_region, 1, edits} = :erlang.binary_to_term(data, [:safe])
          true = is_map(edits)
          edits

        {:error, :enoent} ->
          %{}

        nil ->
          %{}

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read region", path: path
      end

    {:reply, edits, path}
  end

  def handle_call({:flush, edits}, _from, path), do: {:reply, write(path, edits), path}
  @impl true
  def handle_cast({:snapshot, edits, owner, revision}, path) do
    result = write(path, edits)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Region save failed: #{inspect(reason)}")
    end

    send(owner, {:saved, revision, result})
    {:noreply, path}
  end

  defp write(nil, _), do: :ok

  defp write(path, edits) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(
             path <> ".tmp",
             :erlang.term_to_binary({:valimc_region, 1, edits}, [:compressed]),
             [:binary, :sync]
           ),
         :ok <- File.rename(path <> ".tmp", path) do
      Valimc.Metrics.add(:region_saves)
      :ok
    end
  end
end
