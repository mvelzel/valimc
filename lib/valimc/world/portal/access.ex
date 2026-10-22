defmodule Valimc.World.Portal.Access do
  @moduledoc """
  The world as portals see it (VMC-026b2), in the caller's dimension: block
  and heightmap reads from region owners' published snapshots, the portal
  blocks of stored chunks (vanilla's portal POIs), and block commits fenced
  per region owner. Reads are observations; only the commits change blocks.
  There is no cross-owner atomicity, as vanilla's chunks save independently.
  """
  alias Valimc.World
  alias Valimc.World.{Directory, Region, View}
  alias Valimc.Data.BlockFacts

  @deadline 30_000

  # A transient refusal, or a change that lost a race (read again), is asked
  # again until the deadline; any other refusal is final.
  defguardp again?(reason)
            when (is_tuple(reason) and elem(reason, 0) == :retry) or reason == :stale_revision

  @doc """
  A block reader of the caller's dimension (`fn position -> state end`) over a
  `Valimc.World.View` kept for the calling process's lifetime: a chunk is read
  once, its region admitted and its generation awaited if needed, holding a
  `:portal` ticket.
  """
  def reader do
    cache = make_ref()
    deadline = now() + @deadline

    fn {x, _y, z} = position ->
      View.block(view(cache, Valimc.Data.Grid.chunk_key(x, z), deadline), position)
    end
  end

  @doc """
  A heightmap of the caller's dimension (`fn x, z -> y end`), MOTION_BLOCKING
  unless named: one above the top state it counts, else the bottom.
  """
  def heights(type \\ :motion_blocking) do
    cache = make_ref()
    deadline = now() + @deadline
    {min_y, height} = Valimc.World.Dimension.bounds()

    fn x, z ->
      view = view(cache, Valimc.Data.Grid.chunk_key(x, z), deadline)
      top(view, x, z, min_y + height - 1, min_y, type)
    end
  end

  defp top(_view, _x, _z, y, min_y, _type) when y < min_y, do: min_y

  defp top(view, x, z, y, min_y, type) do
    state = View.block(view, {x, y, z})

    if state != nil and BlockFacts.heightmap?(state, type),
      do: y + 1,
      else: top(view, x, z, y - 1, min_y, type)
  end

  defp view(cache, chunk, deadline) do
    view = Process.get(cache, View.new())

    if View.loaded?(view, chunk) do
      view
    else
      case View.await(view, [chunk], :portal, deadline) do
        {:ok, view} ->
          Process.put(cache, view)
          view

        {:error, reason} ->
          exit({:portal_read_failed, reason})
      end
    end
  end

  @doc """
  The highest Y of `chunk`'s highest section holding a block other than air
  (`getHighestSectionPosition() + 15`), or nil for a chunk of air only.
  """
  def chunk_top(chunk) do
    {:ok, view} = View.await([chunk], :portal, now() + @deadline)
    {min_y, height} = Valimc.World.Dimension.bounds()
    first = div(min_y + 64, 16)
    top = View.highest_filled(view, chunk, first + div(height, 16))

    if top != nil and top >= first, do: top * 16 - 64 + 15
  end

  @doc "Whether `chunk` holds air only (`getHighestFilledSectionIndex() == -1`)."
  def chunk_empty?(chunk), do: chunk_top(chunk) == nil

  @doc "The live preserved block entity at `position` (`%{type, nbt}`) or nil."
  def block_entity({x, _, z} = position) do
    key = Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))

    retry(fn ->
      with {:ok, owner} <- World.owner(section(key)), do: Region.block_entity(owner, position)
    end)
  end

  @doc "Record preserved block entities (`position => {type, nbt}`), durably, per region."
  def put_block_entities(entries) do
    entries
    |> Enum.group_by(fn {{x, _, z}, _} ->
      Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))
    end)
    |> Enum.reduce_while(:ok, fn {key, entries}, :ok ->
      result =
        retry(fn ->
          with {:ok, owner} <- World.owner(section(key)),
               {:ok, :applied} <- Region.put_block_entities(owner, Map.new(entries)),
               do: {:ok, :ok}
        end)

      case result do
        {:ok, :ok} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The routing key of section `key` of the dimension this work runs in.
  defp section(key), do: Valimc.Data.Grid.section(Valimc.World.Dimension.current(), key, :section)

  defp retry(fun, deadline \\ nil) do
    deadline = deadline || now() + @deadline

    case fun.() do
      {:error, reason} when again?(reason) ->
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
    chunks
    |> Enum.group_by(&Valimc.Data.Grid.region_key/1)
    |> Enum.filter(fn {key, _} -> stored?(key) end)
    |> Enum.flat_map(fn {key, chunks} ->
      case World.owner(section(key)) do
        {:ok, _} ->
          view = View.load_chunks(View.new(), chunks)
          Enum.flat_map(chunks, &View.find(view, &1, states))

        {:error, reason} ->
          exit({:portal_read_failed, reason})
      end
    end)
  end

  defp stored?(key) do
    case Directory.lookup(section(key)) do
      {_pid, _, _} ->
        true

      nil ->
        case Valimc.config(:world_path, key) do
          nil ->
            false

          world ->
            Valimc.World.RegionStorage.stored?(world, Valimc.World.Dimension.current(), key)
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
    |> Enum.group_by(fn {{x, _, z}, _} ->
      Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))
    end)
    |> Enum.reduce_while(:ok, fn {key, edits}, :ok ->
      case commit_region(key, Map.new(edits), deadline) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp commit_region(key, edits, deadline) do
    result =
      with {:ok, owner} <- World.owner(section(key)),
           {:ok, observed} <- Region.observe_blocks(owner, Map.keys(edits)),
           {:ok, _revision} <- Region.set_blocks(owner, observed.fence, edits),
           do: :ok

    case result do
      {:error, reason} when again?(reason) ->
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
