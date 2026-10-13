defmodule Valimc.World do
  @moduledoc "Region ownership and spatial topics. There is no global world mutation process."
  alias Valimc.World.Region
  def chunk_key(x, z), do: {Integer.floor_div(floor(x), 16), Integer.floor_div(floor(z), 16)}

  def region_key({cx, cz}) do
    size = Valimc.config(:region_size)
    {Integer.floor_div(cx, size), Integer.floor_div(cz, size)}
  end

  def region(key), do: region(key, 100)
  defp region(_key, 0), do: {:error, :region_restarting}

  defp region(key, attempts) do
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Process.sleep(1)
          region(key, attempts - 1)
        end

      [] ->
        case DynamicSupervisor.start_child(Valimc.RegionSupervisor, {Region, key}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            if Process.alive?(pid) do
              {:ok, pid}
            else
              Process.sleep(1)
              region(key, attempts - 1)
            end

          error ->
            error
        end
    end
  end

  def chunk(key) do
    {:ok, pid} = region(region_key(key))
    GenServer.call(pid, {:chunk, key}, 15_000)
  end

  def get_block({x, _, z} = position) do
    {:ok, pid} = region(region_key(chunk_key(x, z)))
    GenServer.call(pid, {:get_block, position})
  end

  def set_block({x, _, z} = position, block) do
    {:ok, pid} = region(region_key(chunk_key(x, z)))
    GenServer.call(pid, {:set_block, position, block})
  end

  def publish(key, event) do
    Registry.dispatch(Valimc.VisibilityRegistry, key, fn entries ->
      for {pid, _} <- entries, do: Valimc.Connection.deliver(pid, event)
    end)
  end

  def subscribe(keys, previous) do
    for key <- MapSet.difference(previous, keys),
        do: Registry.unregister(Valimc.VisibilityRegistry, key)

    for key <- MapSet.difference(keys, previous),
        do: Registry.register(Valimc.VisibilityRegistry, key, nil)

    keys
  end
end
