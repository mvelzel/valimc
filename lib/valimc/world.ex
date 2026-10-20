defmodule Valimc.World do
  @moduledoc "Region ownership and spatial topics. There is no global world mutation process."
  alias Valimc.World.Directory
  def chunk_key(x, z), do: {Integer.floor_div(floor(x), 16), Integer.floor_div(floor(z), 16)}

  def region_key({cx, cz}) do
    size = Valimc.config(:region_size)
    {Integer.floor_div(cx, size), Integer.floor_div(cz, size)}
  end

  def region(key), do: region(key, 100)
  defp region(_key, 0), do: {:error, :region_restarting}

  defp region(key, attempts) do
    case Directory.lookup(key) do
      {pid, _, _} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          admit_region(key, attempts)
        end

      nil ->
        admit_region(key, attempts)
    end
  end

  defp admit_region(key, attempts) do
    case Directory.admit(key) do
      {:error, :region_restarting} ->
        Process.sleep(1)
        region(key, attempts - 1)

      result ->
        result
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

  @doc "Base removal reads and replaces the current block inside its owner, retaining contained fluid."
  def remove_block({x, _, z} = position) do
    {:ok, pid} = region(region_key(chunk_key(x, z)))
    GenServer.call(pid, {:remove_block, position})
  end

  def item_owner(key), do: owner(key)

  @doc "Find an existing incarnation without loading or starting a region."
  def existing_owner(key) do
    case Directory.lookup(key) do
      {pid, _, %{epoch: epoch}} ->
        if Process.alive?(pid), do: {:ok, {pid, epoch}}, else: {:error, :region_unavailable}

      _ ->
        {:error, :region_unavailable}
    end
  end

  def owner(key) do
    with {:ok, pid} <- region(key) do
      case Directory.lookup(key) do
        {^pid, _, %{epoch: epoch}} -> {:ok, {pid, epoch}}
        {^pid, _, :loading} -> GenServer.call(pid, :owner)
        _ -> {:error, :region_restarting}
      end
    else
      {:error, _} = error -> error
    end
  catch
    :exit, {:noproc, {GenServer, :call, _}} -> {:error, :region_restarting}
    :exit, {reason, {GenServer, :call, _}} -> {:error, reason}
  end

  # Publication reads never allocate regions, enqueue messages or confer authority.
  @doc "Invalidate a previously owner-verified frame when any published revision/incarnation changes."
  def item_frame_current?(fences) when is_map(fences) and map_size(fences) in 1..16 do
    Enum.all?(fences, fn {key, %{owner: {pid, epoch}, revision: revision}} ->
      case Directory.lookup(key) do
        {^pid, _, %{epoch: ^epoch, items: table}} ->
          :ets.lookup(table, :block_fence) == [{:block_fence, epoch, revision}]

        _ ->
          false
      end
    end)
  rescue
    ArgumentError -> false
  end

  def item_frame_current?(_), do: false

  @doc "Invalidate a previously source-owner-authorized item snapshot; observations grant no authority."
  def item_observation_current?(%{
        key: key,
        owner: {pid, epoch},
        id: id,
        uuid: uuid,
        versions: versions,
        expires_at: expires
      }) do
    true = is_integer(expires) and System.monotonic_time(:millisecond) < expires

    case Directory.lookup(key) do
      {^pid, _, %{epoch: ^epoch, items: table}} ->
        case Valimc.World.EntityPublication.source(table, :items) do
          %{^id => view} ->
            Process.alive?(pid) and view.uuid == uuid and view.merge_open and
              view.physical_revision == versions

          _ ->
            false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def item_observation_current?(_), do: false

  def item_snapshot(key) do
    case Directory.lookup(key) do
      {_, _, %{items: table}} ->
        Valimc.World.EntityPublication.source(table, :items)

      _ ->
        %{}
    end
  rescue
    # The region/table may have died after registry lookup.
    ArgumentError -> %{}
  end

  @doc "Public lid presentation for a loaded chunk; never contains storage contents."
  def chest_lid_snapshot(chunk) do
    case Directory.lookup(region_key(chunk)) do
      {pid, _, %{epoch: epoch, items: table}} ->
        case :ets.lookup(table, {:container_lids, chunk}) do
          [{{:container_lids, ^chunk}, ^epoch, positions, frame}] ->
            if Process.alive?(pid), do: {:ok, {pid, epoch}, positions, frame}, else: :empty

          _ ->
            :empty
        end

      _ ->
        :empty
    end
  rescue
    ArgumentError -> :empty
  end

  @doc """
  The entity views (every kind) an observer may see: at most 64 regions and
  `EntityReplication.max_visible/0` views, in chunk order. `cache` maps a chunk to
  its last `{stamp, views}`; a chunk's views are copied only when its stamp
  changed. Returns `{views, cache}`.
  """
  def visible_entities(regions, chunks, cache \\ %{}) do
    limit = Valimc.World.EntityReplication.max_visible()
    regions = regions |> Enum.sort() |> Enum.take(64) |> MapSet.new()

    tables =
      Map.new(regions, fn key ->
        case Directory.lookup(key) do
          {_, _, %{items: table}} -> {key, table}
          _ -> {key, nil}
        end
      end)

    chunks
    |> Enum.sort()
    |> Enum.take(4096)
    |> Enum.reduce_while({%{}, %{}}, fn chunk, {acc, next_cache} ->
      table = tables[region_key(chunk)]

      cond do
        map_size(acc) == limit ->
          {:halt, {acc, next_cache}}

        table == nil ->
          {:cont, {acc, next_cache}}

        true ->
          {views, next_cache} = chunk_views(table, chunk, cache, next_cache)
          visible = views |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(limit - map_size(acc))
          {:cont, {Map.merge(acc, Map.new(visible)), next_cache}}
      end
    end)
  end

  defp chunk_views(table, chunk, cache, next_cache) do
    stamp = :ets.lookup_element(table, {:entities, chunk}, 2)

    case cache do
      %{^chunk => {^stamp, views}} ->
        {views, Map.put(next_cache, chunk, {stamp, views})}

      _ ->
        case :ets.lookup(table, {:entities, chunk}) do
          [{_, stamp, views}] -> {views, Map.put(next_cache, chunk, {stamp, views})}
          [] -> {%{}, next_cache}
        end
    end
  rescue
    # No row (no entities) or the region table died after the directory lookup.
    ArgumentError -> {%{}, next_cache}
  end

  def visible_items(regions, chunks), do: visible_kind(regions, chunks, :item)

  @doc "Chunk-local XP presentation only; it cannot authorize pickup or a transfer."
  def orb_snapshot(chunk) do
    {views, _} = visible_entities([region_key(chunk)], [chunk])
    for {id, %{kind: :orb} = view} <- views, into: %{}, do: {id, view}
  end

  def visible_orbs(regions, chunks), do: visible_kind(regions, chunks, :orb)

  defp visible_kind(regions, chunks, kind) do
    {views, _} = visible_entities(regions, chunks)
    for {id, %{kind: ^kind} = view} <- views, into: %{}, do: {id, view}
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
