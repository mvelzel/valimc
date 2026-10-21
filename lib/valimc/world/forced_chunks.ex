defmodule Valimc.World.ForcedChunks do
  @moduledoc """
  Force-loaded chunks (`/forceload`, VMC-053j): the overworld's forced chunk
  set, saved in the world's `forced_chunks.json` and loaded again at startup.
  ValiMC does not unload region owners yet (VMC-013), so a forced chunk's region
  is started and simply stays loaded.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds or removes chunks in one save; returns the chunks that changed."
  def change(operation, chunks) when operation in [:add, :remove],
    do: GenServer.call(__MODULE__, {operation, chunks}, 30_000)

  def remove_all, do: GenServer.call(__MODULE__, :remove_all)
  def all, do: GenServer.call(__MODULE__, :all)

  @impl true
  def init(_opts) do
    chunks =
      with base when is_binary(base) <- Valimc.config(:world_path),
           {:ok, text} <- File.read(path(base)),
           {:ok, saved} when is_list(saved) <- JSON.decode(text) do
        for [x, z] <- saved, is_integer(x) and is_integer(z), into: MapSet.new(), do: {x, z}
      else
        _ -> MapSet.new()
      end

    {:ok, chunks, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, chunks) do
    for chunk <- chunks, do: load(chunk)
    {:noreply, chunks}
  end

  @impl true
  def handle_call({:add, requested}, _from, chunks) do
    changed = Enum.reject(requested, &MapSet.member?(chunks, &1))
    Enum.each(changed, &load/1)
    {:reply, changed, save(chunks, Enum.into(changed, chunks))}
  end

  def handle_call({:remove, requested}, _from, chunks) do
    changed = Enum.filter(requested, &MapSet.member?(chunks, &1))
    {:reply, changed, save(chunks, MapSet.difference(chunks, MapSet.new(changed)))}
  end

  def handle_call(:remove_all, _from, chunks), do: {:reply, :ok, save(chunks, MapSet.new())}
  def handle_call(:all, _from, chunks), do: {:reply, MapSet.to_list(chunks), chunks}

  defp load(chunk), do: Valimc.World.region(Valimc.World.region_key(chunk))

  defp save(chunks, chunks), do: chunks

  defp save(_previous, chunks) do
    with base when is_binary(base) <- Valimc.config(:world_path) do
      File.mkdir_p!(base)
      temporary = path(base) <> ".tmp"
      File.write!(temporary, JSON.encode!(for {x, z} <- Enum.sort(chunks), do: [x, z]))
      File.rename!(temporary, path(base))
    end

    chunks
  end

  defp path(base), do: Path.join(base, "forced_chunks.json")
end
