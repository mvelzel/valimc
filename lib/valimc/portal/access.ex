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

  # A busy owner (one still generating or writing) is asked again until the
  # deadline; a refused change is final. An observation of a chunk not
  # generated yet asks for it (VMC-075).
  @busy [
    :chunk_generating,
    :stale_revision,
    :block_query_timeout,
    :block_commit_uncertain,
    :mining_storage_busy,
    :region_unavailable,
    :region_restarting,
    :stale_owner
  ]

  @doc """
  A block reader of the caller's dimension (`fn position -> state end`). It
  starts the owners it reads (generating the chunks if needed) and caches
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
  A heightmap of the caller's dimension (`fn x, z -> y end`), MOTION_BLOCKING
  unless named: one above the top state it counts, else the bottom.
  """
  def heights(type \\ :motion_blocking) do
    cache = make_ref()
    deadline = now() + @deadline
    {min_y, height} = Valimc.Dimension.bounds()

    fn x, z ->
      sections = sections(cache, World.chunk_key(x, z), deadline)
      top(sections, x, z, min_y + height - 1, min_y, type)
    end
  end

  defp top(_sections, _x, _z, y, min_y, _type) when y < min_y, do: min_y

  defp top(sections, x, z, y, min_y, type) do
    if HeightmapBlocks.opaque?(BlockSnapshot.state_at(sections, {x, y, z}), type) == {:ok, true},
      do: y + 1,
      else: top(sections, x, z, y - 1, min_y, type)
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

  # A chunk not generated yet is awaited (VMC-075) and read again; with
  # `generate: false` it reads as holding nothing.
  defp fetch(chunk, deadline, generate \\ true) do
    if now() > deadline, do: exit(:portal_read_deadline)
    key = World.region_key(chunk)

    with {:ok, {pid, epoch}} <- World.owner(key),
         {^pid, _, %{epoch: ^epoch, items: table}} <- Directory.lookup(key) do
      case BlockSnapshot.chunk(table, epoch, chunk) do
        {:ok, sections} ->
          sections

        {:error, :chunk_generating} when not generate ->
          nil

        {:error, :chunk_generating} ->
          Region.await_chunks({pid, epoch}, [chunk], deadline - now())
          fetch(chunk, deadline, generate)

        _ ->
          Process.sleep(5)
          fetch(chunk, deadline, generate)
      end
    else
      _ ->
        Process.sleep(5)
        fetch(chunk, deadline, generate)
    end
  end

  @doc """
  The highest Y of `chunk`'s highest section holding a block other than air
  (`getHighestSectionPosition() + 15`), or nil for a chunk of air only.
  """
  def chunk_top(chunk) do
    sections = fetch(chunk, now() + @deadline)
    {min_y, height} = Valimc.Dimension.bounds()
    first = div(min_y + 64, 16)
    count = div(height, 16)

    Enum.find_value((first + count - 1)..first//-1, fn s ->
      if not air_section?(sections && elem(sections, s)), do: s * 16 - 64 + 15
    end)
  end

  @doc "Whether `chunk` holds air only (`getHighestFilledSectionIndex() == -1`)."
  def chunk_empty?(chunk), do: chunk_top(chunk) == nil

  defp air_section?(nil), do: true
  defp air_section?(state) when is_integer(state), do: Valimc.Portal.Gateway.air?(state)

  defp air_section?({:dense, cells}),
    do: Enum.all?(for(<<v::16 <- cells>>, uniq: true, do: v), &Valimc.Portal.Gateway.air?/1)

  defp air_section?({palette, cells}) do
    used = cells |> :binary.bin_to_list() |> Enum.uniq()
    Enum.all?(used, &Valimc.Portal.Gateway.air?(elem(palette, &1)))
  end

  @doc "The live preserved block entity at `position` (`%{type, nbt}`) or nil."
  def block_entity({x, _, z} = position) do
    key = World.region_key(World.chunk_key(x, z))

    retry(fn ->
      with {:ok, owner} <- World.owner(key), do: Region.block_entity(owner, position)
    end)
  end

  @doc "Record preserved block entities (`position => {type, nbt}`), durably, per region."
  def put_block_entities(entries) do
    entries
    |> Enum.group_by(fn {{x, _, z}, _} -> World.region_key(World.chunk_key(x, z)) end)
    |> Enum.reduce_while(:ok, fn {key, entries}, :ok ->
      result =
        retry(fn ->
          with {:ok, owner} <- World.owner(key),
               {:ok, :applied} <- Region.put_block_entities(owner, Map.new(entries)),
               do: {:ok, :ok}
        end)

      case result do
        {:ok, :ok} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retry(fun, deadline \\ nil) do
    deadline = deadline || now() + @deadline

    case fun.() do
      {:error, reason}
      when reason in @busy or reason in [:storage_backpressure, :item_storage_busy] ->
        if now() > deadline do
          {:error, reason}
        else
          Process.sleep(20)
          retry(fun, deadline)
        end

      other ->
        other
    end
  end

  @doc """
  Portal blocks (`{position, state}`) in `chunks` of the caller's dimension
  that are stored: of loaded regions and of regions on disk (which this
  loads). Chunks never generated hold none, as vanilla's POIs only exist for
  saved chunks; that includes a stored region's chunks not generated yet.
  """
  def portal_blocks(chunks, states) do
    deadline = now() + @deadline

    chunks
    |> Enum.group_by(&World.region_key/1)
    |> Enum.filter(fn {key, _} -> stored?(key) end)
    |> Enum.flat_map(fn {_key, chunks} ->
      Enum.flat_map(chunks, &BlockSnapshot.find(fetch(&1, deadline, false), &1, states))
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
            File.dir?(Store.log_dir(base, key)) or Store.pre_log_files(base, key) != []
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
