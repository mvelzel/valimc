defmodule Valimc.Portal.Access do
  @moduledoc """
  The world as portals see it (VMC-026b2), in the caller's dimension: block
  and heightmap reads from region owners' published snapshots, the portal
  blocks of stored chunks (vanilla's portal POIs), and block commits fenced
  per region owner. Reads are observations; only the commits change blocks.
  There is no cross-owner atomicity, as vanilla's chunks save independently.
  """
  alias Valimc.World
  alias Valimc.World.{BlockSnapshot, Directory, Region, Store}
  alias Valimc.Physics.HeightmapBlocks

  @deadline 30_000

  @doc """
  A block reader of the caller's dimension (`fn position -> state end`). It
  starts the owners it reads (generating their regions if needed) and caches
  chunk sections for the calling process's lifetime.
  """
  def reader do
    cache = make_ref()
    deadline = now() + @deadline

    fn {x, _y, z} = position ->
      BlockSnapshot.state_at(sections(cache, World.chunk_key(x, z), deadline), position)
    end
  end

  @doc """
  The MOTION_BLOCKING heightmap of the caller's dimension (`fn x, z -> y end`):
  one above the top state that blocks motion or holds a fluid, else the bottom.
  """
  def heights do
    cache = make_ref()
    deadline = now() + @deadline
    {min_y, height} = Valimc.Dimension.bounds()

    fn x, z ->
      sections = sections(cache, World.chunk_key(x, z), deadline)
      top(sections, x, z, min_y + height - 1, min_y)
    end
  end

  defp top(_sections, _x, _z, y, min_y) when y < min_y, do: min_y

  defp top(sections, x, z, y, min_y) do
    if HeightmapBlocks.opaque?(BlockSnapshot.state_at(sections, {x, y, z}), :motion_blocking) ==
         {:ok, true},
       do: y + 1,
       else: top(sections, x, z, y - 1, min_y)
  end

  defp sections(cache, chunk, deadline) do
    case Process.get({cache, chunk}, :missing) do
      :missing ->
        sections = fetch(chunk, deadline)
        Process.put({cache, chunk}, sections)
        sections

      sections ->
        sections
    end
  end

  defp fetch(chunk, deadline) do
    if now() > deadline, do: exit(:portal_read_deadline)
    key = World.region_key(chunk)

    with {:ok, {pid, epoch}} <- World.owner(key),
         {^pid, _, %{epoch: ^epoch, items: table}} <- Directory.lookup(key),
         {:ok, sections} <- BlockSnapshot.chunk(table, epoch, chunk) do
      sections
    else
      _ ->
        Process.sleep(5)
        fetch(chunk, deadline)
    end
  end

  @doc """
  Portal blocks (`{position, state}`) in `chunks` of the caller's dimension
  that are stored: of loaded regions and of regions on disk (which this
  loads). Chunks never generated hold none, as vanilla's POIs only exist for
  saved chunks.
  """
  def portal_blocks(chunks, states) do
    deadline = now() + @deadline

    chunks
    |> Enum.group_by(&World.region_key/1)
    |> Enum.filter(fn {key, _} -> stored?(key) end)
    |> Enum.flat_map(fn {_key, chunks} ->
      Enum.flat_map(chunks, &BlockSnapshot.find(fetch(&1, deadline), &1, states))
    end)
  end

  defp stored?(key) do
    case Directory.lookup(key) do
      {_pid, _, _} ->
        true

      nil ->
        case Valimc.config(:world_path, key) do
          nil ->
            false

          world ->
            base = Valimc.Dimension.storage(world, Valimc.Dimension.current())
            File.dir?(Store.log_dir(base, key)) or File.exists?(Store.block_path(base, key))
        end
    end
  end

  @doc """
  Set `edits` (`{position, state}` in order; a later one wins) region by
  region, each fenced on the observed positions; a region that changed
  meanwhile is retried.
  """
  def commit(edits) do
    deadline = now() + @deadline

    edits
    |> Enum.group_by(fn {{x, _, z}, _} -> World.region_key(World.chunk_key(x, z)) end)
    |> Enum.reduce_while(:ok, fn {key, edits}, :ok ->
      case commit_region(key, Map.new(edits), deadline) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A busy owner (one still generating or writing) is asked again until the
  # deadline; a refused change is final.
  @busy [
    :stale_revision,
    :block_query_timeout,
    :block_commit_uncertain,
    :mining_storage_busy,
    :region_unavailable,
    :region_restarting,
    :stale_owner
  ]

  defp commit_region(key, edits, deadline) do
    result =
      with {:ok, owner} <- World.owner(key),
           {:ok, observed} <- Region.observe_blocks(owner, Map.keys(edits)),
           {:ok, _revision} <- Region.set_blocks(owner, observed.fence, edits),
           do: :ok

    case result do
      {:error, reason} when reason in @busy ->
        if now() > deadline do
          {:error, reason}
        else
          Process.sleep(20)
          commit_region(key, edits, deadline)
        end

      other ->
        other
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
