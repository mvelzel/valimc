defmodule Valimc.World.BlockSnapshot do
  @moduledoc """
  Lock-free block reads from a region owner's published chunk snapshots.

  The owner writes `{{:chunk, cx, cz}, revision, sections}` rows for every changed
  chunk before it bumps `{:block_fence, epoch, revision}`. A reader takes the fence
  first and rejects any row newer than it, so an accepted observation equals the
  owner's state at that revision. Untouched chunks have no row and read the flat
  base profile; a chunk not generated yet (VMC-075) has an `:absent` row and
  cannot be read. Observations never grant authority; commits stay fenced.
  """
  alias Valimc.World.{Blocks, Chunk}

  @doc "Publish the given chunks of `blocks` at `revision` (call before `publish_fence/3`)."
  def publish_chunks(table, %Blocks{} = blocks, chunks, revision) do
    rows =
      for chunk <- chunks do
        case Blocks.snapshot(blocks, chunk) do
          nil -> {{:chunk, chunk}, revision, nil}
          sections -> {{:chunk, chunk}, revision, List.to_tuple(sections)}
        end
      end

    :ets.insert(table, rows)
    :ok
  end

  @doc "Mark `chunks` as not generated yet: reads of them fail until they are published."
  def publish_absent(table, chunks) do
    :ets.insert(table, for(chunk <- chunks, do: {{:chunk, chunk}, 0, :absent}))
    :ok
  end

  @doc "Whether `chunk` is not generated yet (or its owner's table is gone)."
  def absent?(table, chunk) do
    match?([{_, _, :absent}], :ets.lookup(table, {:chunk, chunk}))
  rescue
    ArgumentError -> true
  end

  def publish_fence(table, epoch, revision),
    do: :ets.insert(table, {:block_fence, epoch, revision})

  @doc """
  Read `positions` (all in the region of `table`) at one consistent revision.
  Returns `{:ok, revision, %{position => block}}` or `{:error, reason}`.
  """
  def read(table, epoch, positions) do
    case :ets.lookup(table, :block_fence) do
      [{:block_fence, ^epoch, revision}] -> read_at(table, revision, positions)
      [{:block_fence, _, _}] -> {:error, :stale_owner}
      [] -> {:error, :region_unavailable}
    end
  rescue
    ArgumentError -> {:error, :region_unavailable}
  end

  defp read_at(table, revision, positions) do
    positions
    |> Enum.group_by(fn {x, _, z} -> Valimc.World.chunk_key(x, z) end)
    |> Enum.reduce_while({:ok, revision, %{}}, fn {chunk, members}, {:ok, _, acc} ->
      case :ets.lookup(table, {:chunk, chunk}) do
        [{_, row_revision, _}] when row_revision > revision ->
          {:halt, {:error, :stale_revision}}

        [{_, _, :absent}] ->
          {:halt, {:error, :chunk_generating}}

        [{_, _, sections}] ->
          {:cont, {:ok, revision, Enum.reduce(members, acc, &Map.put(&2, &1, at(sections, &1)))}}

        [] ->
          {:cont, {:ok, revision, Enum.reduce(members, acc, &Map.put(&2, &1, flat(&1)))}}
      end
    end)
  end

  @doc """
  One chunk's published sections at the owner's current fence (VMC-026b2):
  `{:ok, sections}` (nil for an untouched chunk, which reads the base
  profile) for `state_at/2`, or `{:error, reason}` (`:chunk_generating` for a
  chunk not generated yet, VMC-075).
  """
  def chunk(table, epoch, chunk) do
    case :ets.lookup(table, :block_fence) do
      [{:block_fence, ^epoch, revision}] ->
        case :ets.lookup(table, {:chunk, chunk}) do
          [{_, row_revision, _}] when row_revision > revision -> {:error, :stale_revision}
          [{_, _, :absent}] -> {:error, :chunk_generating}
          [{_, _, sections}] -> {:ok, sections}
          [] -> {:ok, nil}
        end

      [{:block_fence, _, _}] ->
        {:error, :stale_owner}

      [] ->
        {:error, :region_unavailable}
    end
  rescue
    ArgumentError -> {:error, :region_unavailable}
  end

  @doc "The state at a position of a chunk's sections (`chunk/3`)."
  def state_at(sections, position), do: at(sections, position)

  @doc """
  Positions and states in a chunk's sections whose state is in `states` (a
  list), scanning only sections whose palette holds one.
  """
  def find(nil, _chunk, _states), do: []

  def find(sections, {cx, cz}, states) do
    for {section, s} <- Enum.with_index(Tuple.to_list(sections)),
        {index, state} <- matches(section, states),
        do: {position(cx, cz, s, index), state}
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
    x = Bitwise.band(index, 15)
    z = Bitwise.band(Bitwise.bsr(index, 4), 15)
    y = Bitwise.bsr(index, 8)
    {cx * 16 + x, s * 16 + y - 64, cz * 16 + z}
  end

  @doc "Whether the owner's fence still equals `revision` (re-check after a computation)."
  def current?(table, epoch, revision) do
    :ets.lookup(table, :block_fence) == [{:block_fence, epoch, revision}]
  rescue
    ArgumentError -> false
  end

  defp flat({_, y, _}), do: Chunk.base(y)

  defp at(nil, position), do: flat(position)

  defp at(_sections, {_, y, _} = position) when y < -64 or y > 319, do: flat(position)

  defp at(sections, {x, y, z}) do
    local = y + 64

    index =
      Bitwise.bsl(Bitwise.band(local, 15), 8) + Bitwise.bsl(Bitwise.band(z, 15), 4) +
        Bitwise.band(x, 15)

    case elem(sections, Bitwise.bsr(local, 4)) do
      state when is_integer(state) -> state
      {:dense, cells} -> :binary.decode_unsigned(binary_part(cells, index * 2, 2))
      {palette, cells} -> elem(palette, :binary.at(cells, index))
    end
  end
end
