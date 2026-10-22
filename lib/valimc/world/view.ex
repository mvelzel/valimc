defmodule Valimc.World.View do
  @moduledoc """
  One lazy read view over region owners' published chunk snapshots (VMC-077e):
  how collision, pose, fluid, climbing, portal and spawn code read blocks.

  `load/2` takes the snapshot handles of the chunks a box covers from their
  owners' tables (one ETS lookup per chunk), and a read of a chunk not loaded
  looks its handle up directly, so no reader has to plan an envelope. A handle
  is the chunk as one owner commit published it, read in place by Rust
  (VMC-077p): no copy, no lock, and the owner may publish newer ones
  meanwhile. A view is not one revision of the world and fences nothing, since
  physics observations are not transactions (commits stay fenced on section
  revisions). A chunk not generated yet, or of a region not running, cannot be
  read: `fetch/2` is `:error` there, so movement into unloaded chunks fails
  closed. `column/3` and `biome/2` compute the MOTION_BLOCKING height, lowest
  sky source and biome from the snapshot; `blocks/2` reads many positions in
  one call. `await/4` waits for chunks to load and generate, holding a timed
  ticket. `of/1` is a view of supplied states for oracles and tests. A view
  reads one dimension, named when it is made (VMC-077j: routing never reads
  the process's context).
  """
  import Bitwise, only: [bsr: 2]
  alias Valimc.{Native, World}
  alias Valimc.World.{Chunk, Directory, Region}

  defstruct dimension: :overworld, chunks: %{}, owners: %{}, supplied: nil

  @doc "An empty view of `dimension` (the calling process's by default)."
  def new(dimension \\ Valimc.Dimension.current()), do: %__MODULE__{dimension: dimension}

  @doc "A view of `states` (`position => state`) only: other positions cannot be read."
  def of(states) when is_map(states), do: %__MODULE__{supplied: states}

  @doc "Load the chunks a box covers, widened by a block (shapes reach into neighbours)."
  def load(%__MODULE__{supplied: nil} = view, {x0, _, z0, x1, _, z1}) do
    load_chunks(
      view,
      for(
        cx <- chunk(floor(x0) - 1)..chunk(floor(x1) + 1),
        cz <- chunk(floor(z0) - 1)..chunk(floor(z1) + 1),
        do: {cx, cz}
      )
    )
  end

  def load(view, _box), do: view

  def load_chunks(%__MODULE__{supplied: nil} = view, chunks) do
    Enum.reduce(chunks, view, fn chunk, view ->
      if Map.has_key?(view.chunks, chunk) do
        view
      else
        {row, owner} = lookup(view.dimension, chunk)

        owners =
          if owner, do: Map.put(view.owners, World.region_key(chunk), owner), else: view.owners

        %{view | chunks: Map.put(view.chunks, chunk, row), owners: owners}
      end
    end)
  end

  def load_chunks(view, _chunks), do: view

  @doc "The state at an integer position: `{:ok, state}`, or `:error` where it cannot be read."
  def fetch(%__MODULE__{supplied: supplied}, position) when supplied != nil,
    do: Map.fetch(supplied, position)

  def fetch(%__MODULE__{} = view, {x, y, z}) do
    case entry(view, {chunk(x), chunk(z)}) do
      :unavailable -> :error
      _ when y < -64 or y > 319 -> {:ok, Chunk.base(y)}
      snapshot -> {:ok, Native.snapshot_get(snapshot, x, y, z)}
    end
  end

  @doc """
  The states at `positions`, in order, nil where one cannot be read: one
  native call over the chunks they fall in.
  """
  def blocks(%__MODULE__{supplied: supplied}, positions) when supplied != nil,
    do: Enum.map(positions, &Map.get(supplied, &1))

  def blocks(%__MODULE__{} = view, positions) do
    chunks = positions |> Enum.map(fn {x, _, z} -> {chunk(x), chunk(z)} end) |> Enum.uniq()
    view = load_chunks(view, chunks)
    snapshots = for c <- chunks, (s = view.chunks[c]) != :unavailable, do: s

    packed =
      for {x, y, z} <- positions, into: <<>>, do: <<x::32-signed, y::32-signed, z::32-signed>>

    for <<state::16 <- Native.snapshot_blocks(snapshots, packed, Chunk.base(Chunk.min_y() - 1))>>,
      do: if(state == 0xFFFF, do: nil, else: state)
  end

  @doc """
  A column's MOTION_BLOCKING height (one above its top motion-blocking state)
  and lowest sky source (`ChunkSkyLightSources`), the build bottom when it has
  none: `{:ok, %{motion_blocking: y, sky_source: y}}` or `:error`.
  """
  def column(%__MODULE__{supplied: nil} = view, x, z) do
    case entry(view, {chunk(x), chunk(z)}) do
      :unavailable ->
        :error

      snapshot ->
        {:ok, {motion, sky}} = Native.snapshot_column(snapshot, x, z)
        {:ok, %{motion_blocking: motion, sky_source: sky}}
    end
  end

  def column(_view, _x, _z), do: :error

  @doc """
  The biome registry id at a block as `Level.getBiome` reads it: the world's
  fuzzed zoom, then the stored biome of that quart (plains for a column
  without biomes): `{:ok, id}` or `:error` where the quart cannot be read.
  """
  def biome(%__MODULE__{supplied: nil} = view, {x, y, z}) do
    {zoom_seed, _} =
      Valimc.World.Spec.client_info(Valimc.World.Spec.current(), view.dimension)

    {:ok, {qx, qy, qz}} = Native.biome_zoom(zoom_seed, x, y, z)

    case entry(view, {bsr(qx, 2), bsr(qz, 2)}) do
      :unavailable ->
        :error

      snapshot ->
        case Native.snapshot_biome(snapshot, qx, qy, qz) do
          nil ->
            {:ok,
             Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")}

          id ->
            {:ok, id}
        end
    end
  end

  def biome(_view, _position), do: :error

  @doc "The state at a position, or nil where it cannot be read."
  def block(view, position) do
    case fetch(view, position) do
      {:ok, state} -> state
      :error -> nil
    end
  end

  @doc "A chunk's published snapshot handle (VMC-077p), or `:unavailable`."
  def row(view, chunk), do: entry(view, chunk)

  @doc """
  Positions and states in `chunk` whose state is in `states` (a list),
  scanning only sections whose palette holds one; none where it cannot be read.
  """
  def find(view, chunk, states) do
    case entry(view, chunk) do
      :unavailable ->
        []

      snapshot ->
        for <<x::32-signed, y::32-signed, z::32-signed,
              state::16 <- Native.snapshot_find(snapshot, states)>>,
            do: {{x, y, z}, state}
    end
  end

  @doc """
  The index of `chunk`'s highest stored section (bottom 0) below `below`
  holding a state other than air, nil if none does, or `:unavailable`.
  """
  def highest_filled(view, chunk, below) do
    case entry(view, chunk) do
      :unavailable ->
        :unavailable

      snapshot ->
        {:ok, section} = Native.snapshot_highest_filled(snapshot, below)
        section
    end
  end

  defp entry(%__MODULE__{chunks: chunks, dimension: dimension}, chunk) do
    case chunks do
      %{^chunk => entry} -> entry
      _ -> elem(lookup(dimension, chunk), 0)
    end
  end

  @doc "The owners (`{pid, epoch}`) of the chunks loaded so far."
  def owners(%__MODULE__{owners: owners}), do: owners |> Map.values() |> Enum.uniq()

  @doc """
  `view` with `chunks` loaded once their regions run and they are generated
  (VMC-075): for chunks not readable yet the caller holds a `type` ticket
  (`Valimc.World.Tickets`, a timed type) on their regions and awaits generation
  through the owner's defer queue. `{:ok, view}`, or `{:error, reason}` once `deadline` (monotonic ms) passed.
  """
  def await(view \\ new(), chunks, type, deadline) do
    view = load_chunks(view, chunks)

    chunks
    |> Enum.filter(&(view.chunks[&1] == :unavailable))
    |> Enum.group_by(&World.region_key/1)
    |> Enum.reduce_while({:ok, view}, fn {key, members}, {:ok, view} ->
      case await_region(World.section(view.dimension, key, :section), members, type, deadline) do
        :ok ->
          {:cont, {:ok, load_chunks(%{view | chunks: Map.drop(view.chunks, members)}, members)}}

        error ->
          {:halt, error}
      end
    end)
  end

  @doc "Whether `chunk` is loaded in the view (readable or not)."
  def loaded?(%__MODULE__{chunks: chunks}, chunk), do: Map.has_key?(chunks, chunk)

  defp await_region(key, chunks, type, deadline) do
    with {:ok, owner} <- World.owner(key),
         :ok <- Region.ticket(owner, elem(World.split_section(key), 1), type, hd(chunks), chunks) do
      Region.await_chunks(owner, chunks, deadline - System.monotonic_time(:millisecond))
    else
      # An owner unloading or backing off is admitted again shortly.
      {:error, {:retry, _}} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_region(key, chunks, type, deadline)
        else
          error
        end

      error ->
        error
    end
  end

  defp lookup(dimension, chunk) do
    case Directory.lookup(World.section(dimension, chunk)) do
      {pid, _, %{epoch: epoch, publication: table}} ->
        case :ets.lookup(table, {:chunk, chunk}) do
          [{_, snapshot}] when is_reference(snapshot) -> {snapshot, {pid, epoch}}
          _ -> {:unavailable, nil}
        end

      _ ->
        {:unavailable, nil}
    end
  rescue
    # The owner's table went with it after the lookup.
    ArgumentError -> {:unavailable, nil}
  end

  defp chunk(coordinate), do: bsr(coordinate, 4)
end
