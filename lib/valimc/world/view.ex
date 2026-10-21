defmodule Valimc.World.View do
  @moduledoc """
  One lazy read view over region owners' published chunk snapshots (VMC-077e):
  how collision, pose, fluid, climbing, portal and spawn code read blocks.

  `load/2` copies the rows of the chunks a box covers out of their owners'
  tables (one ETS lookup per chunk; sections share their binaries), and a read
  of a chunk not loaded looks its row up directly, so no reader has to plan an
  envelope. Each row is one owner commit of durable blocks; a view is not one
  revision of the world and fences nothing, since physics observations are not
  transactions (commits stay fenced on section revisions). A chunk not generated
  yet, or of a region not running, cannot be read: `fetch/2` is `:error` there,
  so movement into unloaded chunks fails closed. Rows carry the MOTION_BLOCKING
  heightmap, lowest sky sources and biomes Rust computes beside the sections
  (`column/3`, `biome/2`). `await/4` waits for chunks to load and generate,
  holding a timed ticket. `of/1` is a view of supplied states
  for oracles and tests.
  """
  import Bitwise, only: [band: 2, bsl: 2, bsr: 2]
  alias Valimc.World
  alias Valimc.World.{Chunk, Directory, Region}

  defstruct chunks: %{}, owners: %{}, supplied: nil

  def new, do: %__MODULE__{}

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
        {row, owner} = lookup(chunk)

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

  def fetch(%__MODULE__{} = view, {x, _, z} = position) do
    case entry(view, {chunk(x), chunk(z)}) do
      :unavailable -> :error
      {sections, _, _} -> {:ok, at(sections, position)}
    end
  end

  @doc """
  A column's MOTION_BLOCKING height (one above its top motion-blocking state)
  and lowest sky source (`ChunkSkyLightSources`), the build bottom when it has
  none: `{:ok, %{motion_blocking: y, sky_source: y}}` or `:error`.
  """
  def column(%__MODULE__{supplied: nil} = view, x, z) do
    case entry(view, {chunk(x), chunk(z)}) do
      {_, heights, _} when is_binary(heights) ->
        <<motion::16, sky::16>> = binary_part(heights, (band(z, 15) * 16 + band(x, 15)) * 4, 4)
        {:ok, %{motion_blocking: motion - 64, sky_source: sky - 64}}

      _ ->
        :error
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
      Valimc.World.Spec.client_info(Valimc.World.Spec.current(), Valimc.Dimension.current())

    {:ok, {qx, qy, qz}} = Valimc.Native.biome_zoom(zoom_seed, x, y, z)

    case entry(view, {bsr(qx, 2), bsr(qz, 2)}) do
      :unavailable ->
        :error

      {_, _, nil} ->
        {:ok, Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")}

      {_, _, biomes} ->
        local = (qy |> max(-16) |> min(79)) + 16
        quart = bsr(local, 2) * 64 + (band(local, 3) * 4 + band(qz, 3)) * 4 + band(qx, 3)
        {:ok, :binary.decode_unsigned(binary_part(biomes, quart * 2, 2))}
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

  @doc """
  A chunk's row: its 24 published sections, nil for an untouched chunk of a flat
  world (which reads the base profile), or `:unavailable`.
  """
  def row(view, chunk) do
    case entry(view, chunk) do
      {sections, _, _} -> sections
      :unavailable -> :unavailable
    end
  end

  defp entry(%__MODULE__{chunks: chunks}, chunk) do
    case chunks do
      %{^chunk => entry} -> entry
      _ -> elem(lookup(chunk), 0)
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
      case await_region(key, members, type, deadline) do
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
         :ok <- Region.ticket(owner, type, hd(chunks), chunks) do
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

  @doc """
  Positions and states in a chunk row whose state is in `states` (a list),
  scanning only sections whose palette holds one.
  """
  def find(sections, _chunk, _states) when not is_tuple(sections), do: []

  def find(sections, {cx, cz}, states) do
    for {section, s} <- Enum.with_index(Tuple.to_list(sections)),
        {index, state} <- matches(section, states),
        do: {position(cx, cz, s, index), state}
  end

  defp lookup(chunk) do
    case Directory.lookup(World.region_key(chunk)) do
      {pid, _, %{epoch: epoch, items: table}} ->
        case :ets.lookup(table, {:chunk, chunk}) do
          [{_, _, :absent, _, _}] -> {:unavailable, nil}
          [{_, _, sections, heights, biomes}] -> {{sections, heights, biomes}, {pid, epoch}}
          [] -> {{nil, nil, nil}, {pid, epoch}}
        end

      _ ->
        {:unavailable, nil}
    end
  rescue
    # The owner's table went with it after the lookup.
    ArgumentError -> {:unavailable, nil}
  end

  defp chunk(coordinate), do: bsr(coordinate, 4)

  defp at(nil, {_, y, _}), do: Chunk.base(y)
  defp at(_sections, {_, y, _}) when y < -64 or y > 319, do: Chunk.base(y)

  defp at(sections, {x, y, z}) do
    local = y + 64
    index = bsl(band(local, 15), 8) + bsl(band(z, 15), 4) + band(x, 15)

    case elem(sections, bsr(local, 4)) do
      state when is_integer(state) -> state
      {:dense, cells} -> :binary.decode_unsigned(binary_part(cells, index * 2, 2))
      {palette, cells} -> elem(palette, :binary.at(cells, index))
    end
  end

  defp matches(state, states) when is_integer(state),
    do: if(state in states, do: for(i <- 0..4095, do: {i, state}), else: [])

  defp matches({:dense, cells}, states) do
    for <<value::16 <- cells>>, reduce: {0, []} do
      {i, acc} -> {i + 1, if(value in states, do: [{i, value} | acc], else: acc)}
    end
    |> elem(1)
  end

  defp matches({palette, cells}, states) do
    for {state, slot} <- Enum.with_index(Tuple.to_list(palette)),
        state in states,
        {offset, 1} <- :binary.matches(cells, <<slot>>),
        do: {offset, state}
  end

  defp position(cx, cz, s, index) do
    x = band(index, 15)
    z = band(bsr(index, 4), 15)
    y = bsr(index, 8)
    {cx * 16 + x, s * 16 + y - 64, cz * 16 + z}
  end
end
