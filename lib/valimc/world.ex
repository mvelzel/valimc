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

  def item_owner(key), do: owner(key)

  @doc "Find an existing incarnation without loading or starting a region."
  def existing_owner(key) do
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{pid, %{epoch: epoch}}] ->
        if Process.alive?(pid), do: {:ok, {pid, epoch}}, else: {:error, :region_unavailable}

      _ ->
        {:error, :region_unavailable}
    end
  end

  def owner(key) do
    with {:ok, pid} <- region(key),
         [{^pid, %{epoch: epoch}}] <- Registry.lookup(Valimc.RegionRegistry, key) do
      {:ok, {pid, epoch}}
    else
      [] -> {:error, :region_restarting}
      {:error, _} = error -> error
      _ -> {:error, :region_restarting}
    end
  end

  # Publication reads never allocate regions, enqueue messages or confer authority.
  def item_snapshot(key) do
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{_, %{items: table}}] ->
        case :ets.lookup(table, :items) do
          [{:items, views}] -> views
          [] -> %{}
        end

      _ ->
        %{}
    end
  rescue
    # The region/table may have died after registry lookup.
    ArgumentError -> %{}
  end

  def visible_items(regions, chunks) do
    limit = Valimc.World.ItemReplication.max_visible()

    regions
    |> Enum.sort()
    |> Enum.take(64)
    |> Enum.reduce_while(%{}, fn key, acc ->
      if map_size(acc) == limit do
        {:halt, acc}
      else
        views =
          item_snapshot(key)
          |> Enum.filter(fn {_, view} -> MapSet.member?(chunks, view.chunk) end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.take(limit - map_size(acc))

        {:cont, Map.merge(acc, Map.new(views))}
      end
    end)
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
