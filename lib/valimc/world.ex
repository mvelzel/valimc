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
        case :ets.lookup(table, :items) do
          [{:items, %{^id => view}}] ->
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

  def visible_items(regions, chunks) do
    limit = Valimc.World.EntityReplication.max_visible()

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

  @doc "Chunk-local XP presentation only; it cannot authorize pickup or a transfer."
  def orb_snapshot(chunk) do
    case Directory.lookup(region_key(chunk)) do
      {_, _, %{epoch: epoch, items: table}} ->
        case :ets.lookup(table, {:orbs, chunk}) do
          [{{:orbs, ^chunk}, ^epoch, views}] -> views
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    ArgumentError -> %{}
  end

  def visible_orbs(regions, chunks) do
    limit = Valimc.World.EntityReplication.max_visible()
    regions = regions |> Enum.sort() |> Enum.take(64) |> MapSet.new()

    chunks
    |> Enum.sort()
    |> Enum.take(4096)
    |> Enum.reduce_while(%{}, fn chunk, acc ->
      cond do
        map_size(acc) == limit ->
          {:halt, acc}

        not MapSet.member?(regions, region_key(chunk)) ->
          {:cont, acc}

        true ->
          visible =
            orb_snapshot(chunk)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.take(limit - map_size(acc))
            |> Map.new()

          {:cont, Map.merge(acc, visible)}
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
