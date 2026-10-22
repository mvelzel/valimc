defmodule Valimc.World.ForcedChunks do
  @moduledoc """
  Force-loaded chunks (`/forceload`, VMC-053j): each dimension's forced chunk
  set (VMC-026b), saved in that dimension's folder as `forced_chunks.json` and
  loaded again at startup. Callers act on their own dimension. This process
  holds a `:forced` ticket (VMC-077e) on each region with forced chunks, so they
  stay loaded, generated (VMC-075) and ticking; a region whose last forced chunk
  is removed is told to withdraw it. A region that restarted is told again
  every few seconds.
  """
  alias Valimc.Data.Grid
  use GenServer
  alias Valimc.World.Dimension

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds or removes chunks in one save; returns the chunks that changed."
  def change(operation, chunks, dimension)
      when operation in [:add, :remove],
      do: GenServer.call(__MODULE__, {operation, dimension, chunks}, 30_000)

  def remove_all(dimension),
    do: GenServer.call(__MODULE__, {:remove_all, dimension})

  def all(dimension), do: GenServer.call(__MODULE__, {:all, dimension})

  @impl true
  def init(_opts) do
    base = Valimc.config(:world_path)
    {:ok, Map.new(Dimension.ids(), &{&1, read(base, &1)}), {:continue, :load}}
  end

  defp read(base, dimension) do
    with base when is_binary(base) <- base,
         {:ok, text} <- File.read(path(base, dimension)),
         {:ok, saved} when is_list(saved) <- JSON.decode(text) do
      for [x, z] <- saved, is_integer(x) and is_integer(z), into: MapSet.new(), do: {x, z}
    else
      _ -> MapSet.new()
    end
  end

  @impl true
  def handle_continue(:load, sets) do
    send(self(), :refresh)
    {:noreply, sets}
  end

  @impl true
  def handle_call({:add, dimension, requested}, _from, sets) do
    chunks = sets[dimension]
    changed = Enum.reject(requested, &MapSet.member?(chunks, &1))
    {:reply, changed, save(sets, dimension, Enum.into(changed, chunks))}
  end

  def handle_call({:remove, dimension, requested}, _from, sets) do
    chunks = sets[dimension]
    changed = Enum.filter(requested, &MapSet.member?(chunks, &1))
    {:reply, changed, save(sets, dimension, MapSet.difference(chunks, MapSet.new(changed)))}
  end

  def handle_call({:remove_all, dimension}, _from, sets),
    do: {:reply, :ok, save(sets, dimension, MapSet.new())}

  def handle_call({:all, dimension}, _from, sets),
    do: {:reply, MapSet.to_list(sets[dimension]), sets}

  @impl true
  def handle_info(:refresh, sets) do
    for {dimension, chunks} <- sets, do: ticket(dimension, chunks, chunks)
    Process.send_after(self(), :refresh, 5000)
    {:noreply, sets}
  end

  # The `:forced` ticket of every region with chunks in `chunks` (the old or
  # new set) over its chunks in `forced`; empty withdraws it.
  defp ticket(dimension, chunks, forced) do
    for key <- chunks |> Enum.map(&Grid.region_key/1) |> Enum.uniq(),
        {:ok, pid} <- [Valimc.World.region(Grid.section(dimension, key, :section))] do
      held = Enum.filter(forced, &(Grid.region_key(&1) == key))
      Valimc.World.Region.ticket(pid, key, :forced, held)
    end
  end

  defp save(sets, dimension, chunks) when :erlang.map_get(dimension, sets) == chunks, do: sets

  defp save(sets, dimension, chunks) do
    with base when is_binary(base) <- Valimc.config(:world_path) do
      path = path(base, dimension)
      File.mkdir_p!(Path.dirname(path))
      temporary = path <> ".tmp"
      File.write!(temporary, JSON.encode!(for {x, z} <- Enum.sort(chunks), do: [x, z]))
      File.rename!(temporary, path)
    end

    ticket(dimension, MapSet.union(sets[dimension], chunks), chunks)
    Map.put(sets, dimension, chunks)
  end

  defp path(base, dimension),
    do: Path.join(Dimension.storage(base, dimension), "forced_chunks.json")
end
