defmodule Valimc.World.BlockSnapshot do
  @moduledoc """
  Lock-free block reads from a region owner's published chunk snapshots.

  The owner writes `{{:chunk, cx, cz}, revision, sections}` rows for every changed
  chunk before it bumps `{:block_fence, epoch, revision}`. A reader takes the fence
  first and rejects any row newer than it, so an accepted observation equals the
  owner's state at that revision. Untouched chunks have no row and read the flat
  base profile. Observations never grant authority; commits stay fenced.
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

        [{_, _, sections}] ->
          {:cont, {:ok, revision, Enum.reduce(members, acc, &Map.put(&2, &1, at(sections, &1)))}}

        [] ->
          {:cont, {:ok, revision, Enum.reduce(members, acc, &Map.put(&2, &1, flat(&1)))}}
      end
    end)
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
