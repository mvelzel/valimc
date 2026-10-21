defmodule Valimc.World.Stopwatches do
  @moduledoc """
  Server-wide `/stopwatch` timers (VMC-053j): id to elapsed wall-clock time in
  monotonic milliseconds, as vanilla's saved stopwatches. The owner saves the
  elapsed times to the world's `stopwatches.json` on every change and at
  shutdown; after a restart they continue from the saved time, so downtime does
  not count.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(id), do: GenServer.call(__MODULE__, {:create, id})
  def restart(id), do: GenServer.call(__MODULE__, {:restart, id})
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id})
  @doc "Elapsed milliseconds, or nil."
  def elapsed(id), do: GenServer.call(__MODULE__, {:elapsed, id})
  def ids, do: GenServer.call(__MODULE__, :ids)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    now = now()

    watches =
      with base when is_binary(base) <- Valimc.config(:world_path),
           {:ok, text} <- File.read(path(base)),
           {:ok, saved} when is_map(saved) <- JSON.decode(text) do
        for {id, ms} <- saved, is_binary(id) and is_integer(ms), into: %{}, do: {id, {now, ms}}
      else
        _ -> %{}
      end

    {:ok, watches}
  end

  @impl true
  def handle_call({:create, id}, _from, watches) do
    if Map.has_key?(watches, id),
      do: {:reply, :exists, watches},
      else: save({:reply, :ok, Map.put(watches, id, {now(), 0})})
  end

  def handle_call({:restart, id}, _from, watches) do
    if Map.has_key?(watches, id),
      do: save({:reply, :ok, Map.put(watches, id, {now(), 0})}),
      else: {:reply, :missing, watches}
  end

  def handle_call({:remove, id}, _from, watches) do
    if Map.has_key?(watches, id),
      do: save({:reply, :ok, Map.delete(watches, id)}),
      else: {:reply, :missing, watches}
  end

  def handle_call({:elapsed, id}, _from, watches) do
    case watches[id] do
      nil -> {:reply, nil, watches}
      {created, accumulated} -> {:reply, accumulated + now() - created, watches}
    end
  end

  def handle_call(:ids, _from, watches), do: {:reply, Map.keys(watches), watches}

  @impl true
  def terminate(_reason, watches), do: write(watches)

  defp save({:reply, reply, watches}) do
    write(watches)
    {:reply, reply, watches}
  end

  defp write(watches) do
    with base when is_binary(base) <- Valimc.config(:world_path) do
      now = now()

      elapsed =
        Map.new(watches, fn {id, {created, accumulated}} -> {id, accumulated + now - created} end)

      File.mkdir_p!(base)
      temporary = path(base) <> ".tmp"
      File.write!(temporary, JSON.encode!(elapsed))
      File.rename!(temporary, path(base))
    end

    :ok
  end

  defp path(base), do: Path.join(base, "stopwatches.json")
  defp now, do: System.monotonic_time(:millisecond)
end
