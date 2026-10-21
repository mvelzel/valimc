defmodule Valimc.World do
  @moduledoc "Region ownership and spatial topics. There is no global world mutation process."
  alias Valimc.World.{BlockSnapshot, Directory}
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
    with {:ok, pid} <- region(region_key(key)), do: GenServer.call(pid, {:chunk, key}, 15_000)
  end

  @doc """
  The first `limit` of `keys` (in order) that can be sent, read from published
  tables without asking an owner (VMC-077e): `{key, {:frame, frame}}` when the
  owner published the chunk's packet next to its snapshot, `{key, {:owner, pid}}`
  when it must be requested (`request_chunk/2`). A chunk not generated yet
  (VMC-075) or of a region still loading is left out, as vanilla sends only
  loaded chunks; a region not running is started.
  """
  def sendable(keys, limit), do: sendable(keys, limit, %{}, [])

  defp sendable(_keys, 0, _routes, acc), do: Enum.reverse(acc)
  defp sendable([], _limit, _routes, acc), do: Enum.reverse(acc)

  defp sendable([key | rest], limit, routes, acc) do
    region = region_key(key)

    {route, routes} =
      case routes do
        %{^region => route} -> {route, routes}
        _ -> {route(region), Map.put(routes, region, route(region))}
      end

    with {pid, table} <- route,
         false <- BlockSnapshot.absent?(table, key) do
      sendable(rest, limit - 1, routes, [{key, published_frame(table, key, pid)} | acc])
    else
      _ -> sendable(rest, limit, routes, acc)
    end
  end

  defp published_frame(table, key, pid) do
    case :ets.lookup(table, {:frame, key}) do
      [{_, frame}] -> {:frame, frame}
      [] -> {:owner, pid}
    end
  rescue
    # The owner's table went with it after the lookup; its request fails too.
    ArgumentError -> {:owner, pid}
  end

  defp route(region) do
    case Directory.lookup(region) do
      {pid, _, %{items: table}} ->
        {pid, table}

      {_, _, _} ->
        nil

      nil ->
        region(region)
        nil
    end
  end

  @doc """
  Ask `owner` for `key`'s chunk packet without waiting (VMC-077e): the reply
  (`{:reply, frame}` or an error) arrives as a message for
  `:gen_server.check_response/3` under the returned request id.
  """
  def request_chunk(owner, key), do: :gen_server.send_request(owner, {:chunk, key})

  @doc "The block at `position` (a state id) or `{:error, reason}`."
  def get_block(position), do: block_call(position, {:get_block, position})

  def set_block(position, block), do: block_call(position, {:set_block, position, block})

  @doc "Base removal reads and replaces the current block inside its owner, retaining contained fluid."
  def remove_block(position), do: block_call(position, {:remove_block, position})

  defp block_call({x, _, z}, message) do
    with {:ok, pid} <- region(region_key(chunk_key(x, z))), do: GenServer.call(pid, message)
  catch
    :exit, _ -> {:error, :region_unavailable}
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
        {^pid, _, %{epoch: epoch}} ->
          {:ok, {pid, epoch}}

        {^pid, _, :loading} ->
          GenServer.call(pid, :owner, 5000 * Valimc.config(:owner_call_scale, pid))

        _ ->
          {:error, :region_restarting}
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

  defp visible_kind(regions, chunks, kind) do
    {views, _} = visible_entities(regions, chunks)
    for {id, %{kind: ^kind} = view} <- views, into: %{}, do: {id, view}
  end

  # Topics are region keys scoped by the caller's dimension (VMC-026b).
  def publish(key, event) do
    # Events of the Nether and the End name their dimension (VMC-026b), so a
    # player that just left it drops them; the overworld's stay as they were.
    event =
      case Valimc.Dimension.current() do
        :overworld -> event
        dimension -> {:in_dimension, dimension, event}
      end

    Registry.dispatch(Valimc.VisibilityRegistry, Valimc.Dimension.scope(key), fn entries ->
      for {pid, _} <- entries, do: Valimc.Connection.deliver(pid, event)
    end)
  end

  def subscribe(keys, previous) do
    for key <- MapSet.difference(previous, keys),
        do: Registry.unregister(Valimc.VisibilityRegistry, Valimc.Dimension.scope(key))

    for key <- MapSet.difference(keys, previous),
        do: Registry.register(Valimc.VisibilityRegistry, Valimc.Dimension.scope(key), nil)

    keys
  end
end
