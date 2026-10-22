defmodule Valimc.World do
  @moduledoc """
  Section ownership and spatial topics. There is no global world mutation
  process: each section belongs to one group process (VMC-077j), found
  through the Directory's routes by its dimension-explicit key
  (`Grid.section/2`); routing never reads the calling process's
  context.
  """
  alias Valimc.Data.Grid
  alias Valimc.World.{BlockSnapshot, Directory}

  def region({_, _, _} = key) do
    Valimc.World.Owners.ensure(
      # A dead owner's row is the Directory's to replace: admit at once.
      fn ->
        case Directory.lookup(key) do
          {pid, _, _} -> if Process.alive?(pid), do: pid
          nil -> nil
        end
      end,
      fn ->
        case Directory.admit(key) do
          {:error, {:retry, :region_restarting}} -> :retry
          result -> result
        end
      end,
      {:retry, :region_restarting}
    )
  end

  # A group that retired as the call reached it (its section moved): ask again.
  def chunk(dimension, key) do
    with {:ok, pid} <- region(Grid.section(dimension, key)),
         do: GenServer.call(pid, {:chunk, key}, 15_000)
  catch
    :exit, {reason, _} when reason in [:normal, :noproc] -> chunk(dimension, key)
  end

  @doc """
  The first `limit` of `keys` (in order) that can be sent, read from published
  tables without asking an owner (VMC-077e): `{key, {:frame, frame}}` when the
  owner published the chunk's packet next to its snapshot, `{key, {:owner, pid}}`
  when it must be requested (`request_chunk/2`). A chunk not generated yet
  (VMC-075) or of a region still loading is left out, as vanilla sends only
  loaded chunks; a region not running is started.
  """
  def sendable(dimension, keys, limit), do: sendable(dimension, keys, limit, %{}, [])

  defp sendable(_dimension, _keys, 0, _routes, acc), do: Enum.reverse(acc)
  defp sendable(_dimension, [], _limit, _routes, acc), do: Enum.reverse(acc)

  defp sendable(dimension, [key | rest], limit, routes, acc) do
    region = Grid.section(dimension, key)

    {route, routes} =
      case routes do
        %{^region => route} -> {route, routes}
        _ -> {route(region), Map.put(routes, region, route(region))}
      end

    with {pid, table} <- route,
         false <- BlockSnapshot.absent?(table, key) do
      sendable(dimension, rest, limit - 1, routes, [{key, published_frame(table, key, pid)} | acc])
    else
      _ -> sendable(dimension, rest, limit, routes, acc)
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
      {pid, _, %{publication: table}} ->
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
  def item_owner({_, _, _} = key), do: owner(key)

  @doc "Find an existing incarnation without loading or starting a region."
  def existing_owner({_, _, _} = key) do
    case Directory.lookup(key) do
      {pid, _, %{epoch: epoch}} ->
        if Process.alive?(pid),
          do: {:ok, {pid, epoch}},
          else: Valimc.Data.Error.retry(:region_unavailable)

      _ ->
        Valimc.Data.Error.retry(:region_unavailable)
    end
  end

  def owner({_, _, _} = key) do
    with {:ok, pid} <- region(key) do
      case Directory.lookup(key) do
        {^pid, _, %{epoch: epoch}} ->
          {:ok, {pid, epoch}}

        {^pid, _, :loading} ->
          {_, plain} = Grid.split_section(key)
          GenServer.call(pid, {:owner, plain}, 5000 * Valimc.config(:owner_call_scale, pid))

        # Handed to another group meanwhile (VMC-077j): the section is the same.
        {other, _, %{epoch: epoch}} ->
          if Process.alive?(other),
            do: {:ok, {other, epoch}},
            else: Valimc.Data.Error.retry(:region_restarting)

        _ ->
          Valimc.Data.Error.retry(:region_restarting)
      end
    else
      {:error, _} = error -> error
    end
  catch
    # The owner died or overran while finishing its load.
    :exit, {_reason, {GenServer, :call, _}} -> Valimc.Data.Error.retry(:region_restarting)
  end

  # Publication reads never allocate regions, enqueue messages or confer authority.
  def item_snapshot({_, _, _} = key) do
    case Directory.lookup(key) do
      {_, _, %{publication: table}} ->
        Valimc.Entity.Publication.source(table, :items)

      _ ->
        %{}
    end
  rescue
    # The region/table may have died after registry lookup.
    ArgumentError -> %{}
  end

  @doc "Public lid presentation for a loaded chunk; never contains storage contents."
  def chest_lid_snapshot(dimension, chunk) do
    case Directory.lookup(Grid.section(dimension, chunk)) do
      {pid, _, %{epoch: epoch, publication: table}} ->
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
  The entity views (every kind) an observer may see: at most 64 sections (by
  key, of one dimension) and `EntityReplication.max_visible/0` views, in chunk
  order. `cache` maps a chunk to its last `{stamp, views}`; a chunk's views are
  copied only when its stamp changed. Returns `{views, cache}`.
  """
  def visible_entities(regions, chunks, cache \\ %{}) do
    limit = Valimc.Entity.Observer.max_visible()
    regions = regions |> Enum.sort() |> Enum.take(64) |> MapSet.new()

    tables =
      Map.new(regions, fn key ->
        {_, plain} = Grid.split_section(key)

        case Directory.lookup(key) do
          {_, _, %{publication: table}} -> {plain, table}
          _ -> {plain, nil}
        end
      end)

    chunks
    |> Enum.sort()
    |> Enum.take(4096)
    |> Enum.reduce_while({%{}, %{}}, fn chunk, {acc, next_cache} ->
      table = tables[Grid.region_key(chunk)]

      cond do
        map_size(acc) == limit ->
          {:halt, {acc, next_cache}}

        table == nil ->
          {:cont, {acc, next_cache}}

        true ->
          {views, next_cache} = chunk_views(table, chunk, cache, next_cache)
          visible = views |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(limit - map_size(acc))
          {:cont, {Map.merge(acc, Map.new(visible), &newer/3), next_cache}}
      end
    end)
  end

  # An entity keeps its id across a handoff, and its source keeps publishing it
  # until the handoff clears: the newer owner (more hops) wins.
  defp newer(_id, old, view),
    do: if(view.ownership_generation > old.ownership_generation, do: view, else: old)

  @doc """
  The entity frames of section `key` after tick `last`
  (`Valimc.Entity.Publication.frames/2`); none while it is not loaded.
  """
  def entity_frames({_, _, _} = key, last) do
    case Directory.lookup(key) do
      {_, _, %{publication: table}} -> Valimc.Entity.Publication.frames(table, last)
      _ -> {:ok, last || 0, []}
    end
  rescue
    ArgumentError -> {:ok, last || 0, []}
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

  @doc """
  The bodies (mobs and other non-item entities, VMC-043a) the loaded sections
  own, as `[{section key, view}]`: of `dimension`, or of every dimension
  (nil). Read from published views, without asking an owner.
  """
  def bodies(dimension \\ nil) do
    for {{dim, _, _} = key, _pid, _token, _monitor, %{publication: table}} <-
          :ets.tab2list(Valimc.RegionRoutes),
        dimension == nil or dim == dimension,
        {_, %{kind: kind} = view} <- safe_source(table),
        kind in [:mob, :object],
        do: {key, view}
  rescue
    ArgumentError -> []
  end

  defp safe_source(table) do
    Valimc.Entity.Publication.source(table, :items)
  rescue
    ArgumentError -> %{}
  end

  def visible_items(regions, chunks), do: visible_kind(regions, chunks, :item)

  defp visible_kind(regions, chunks, kind) do
    {views, _} = visible_entities(regions, chunks)
    for {id, %{kind: ^kind} = view} <- views, into: %{}, do: {id, view}
  end

  # Topics are section keys (VMC-026b, VMC-077j).
  def publish({dimension, _, _} = key, event) do
    # Events of the Nether and the End name their dimension (VMC-026b), so a
    # player that just left it drops them; the overworld's stay as they were.
    event = if dimension == :overworld, do: event, else: {:in_dimension, dimension, event}

    Registry.dispatch(Valimc.VisibilityRegistry, key, fn entries ->
      for {pid, _} <- entries, do: Valimc.Player.PlayerList.deliver(pid, event)
    end)
  end

  def subscribe(keys, previous) do
    for key <- MapSet.difference(previous, keys),
        do: Registry.unregister(Valimc.VisibilityRegistry, topic!(key))

    for key <- MapSet.difference(keys, previous),
        do: Registry.register(Valimc.VisibilityRegistry, topic!(key), nil)

    keys
  end

  defp topic!({dimension, sx, sz} = key)
       when is_atom(dimension) and is_integer(sx) and is_integer(sz),
       do: key
end
