defmodule Valimc.Session.PendingChunks do
  @moduledoc """
  The chunks of a player's view not sent yet (VMC-070, VMC-081k), grouped by
  section.

  Vanilla sends, of the chunks loaded and not yet sent, the nearest to the
  player's chunk first (`PlayerChunkSender`). Here a section remembers which of
  its pending chunks it saw generated and at which count of its publication
  (`World.stream_source/1`): while that count is unchanged only the chunks
  added since are looked at, so a section with nothing ready costs its route
  and its count, not a lookup per chunk. Sections are visited nearest first
  (by their nearest chunk) and the walk stops once no further section can hold
  a chunk nearer than the batch's farthest. Ties in distance go by `{x, z}`.
  """
  alias Valimc.Data.Grid
  alias Valimc.World

  # `sections`: `{sx, sz} => {chunks, cue, ready, unchecked}`: the pending
  # chunks (a MapSet), `{table, count}` that `ready` (the generated ones) was
  # read at or nil, and chunks added since. `order`: `{center, [{bound,
  # key}]}`, sections by the squared distance of their nearest chunk.
  defstruct sections: %{}, count: 0, order: nil

  def new, do: %__MODULE__{}

  @doc "How many chunks are pending."
  def size(%__MODULE__{count: count}), do: count

  def member?(%__MODULE__{sections: sections}, chunk) do
    case Map.fetch(sections, Grid.region_key(chunk)) do
      {:ok, {chunks, _, _, _}} -> MapSet.member?(chunks, chunk)
      :error -> false
    end
  end

  @doc "Add `chunks` (not pending yet)."
  def put(%__MODULE__{} = pending, chunks) do
    Enum.reduce(chunks, pending, fn chunk, acc ->
      key = Grid.region_key(chunk)

      case acc.sections do
        %{^key => {set, cue, ready, unchecked}} ->
          if MapSet.member?(set, chunk) do
            acc
          else
            entry = {MapSet.put(set, chunk), cue, ready, [chunk | unchecked]}
            %{acc | sections: %{acc.sections | key => entry}, count: acc.count + 1}
          end

        _ ->
          entry = {MapSet.new([chunk]), nil, MapSet.new(), []}

          %{
            acc
            | sections: Map.put(acc.sections, key, entry),
              count: acc.count + 1,
              order: nil
          }
      end
    end)
  end

  @doc "Remove `chunks` (sent, or out of the view); others are ignored."
  def delete(%__MODULE__{} = pending, chunks) do
    Enum.reduce(chunks, pending, fn chunk, acc ->
      key = Grid.region_key(chunk)

      case acc.sections do
        %{^key => {set, cue, ready, unchecked}} ->
          cond do
            not MapSet.member?(set, chunk) ->
              acc

            MapSet.size(set) == 1 ->
              %{acc | sections: Map.delete(acc.sections, key), count: acc.count - 1}

            true ->
              entry = {MapSet.delete(set, chunk), cue, MapSet.delete(ready, chunk), unchecked}
              %{acc | sections: %{acc.sections | key => entry}, count: acc.count - 1}
          end

        _ ->
          acc
      end
    end)
  end

  @doc """
  The nearest `limit` pending chunks to `center` that are generated, nearest
  first, each as `{chunk, World.chunk_source/3}`, and the pending chunks with
  what was read. `source` reads a section's publication by its coordinates
  (`World.stream_source/1`): nil leaves the section's chunks out.
  """
  def sendable(%__MODULE__{count: 0} = pending, _center, _limit, _source), do: {[], pending}

  def sendable(%__MODULE__{} = pending, center, limit, source) when limit > 0 do
    %{order: {_, order}} = pending = ordered(pending, center)
    {best, sections} = walk(order, pending.sections, source, center, limit, {[], 0, nil})

    {for({_, chunk, pid, table} <- best, do: {chunk, World.chunk_source(table, chunk, pid)}),
     %{pending | sections: sections}}
  end

  defp ordered(%__MODULE__{order: {center, _}} = pending, center), do: pending

  defp ordered(%__MODULE__{} = pending, {cx, cz} = center) do
    size = Grid.region_size()

    order =
      pending.sections
      |> Enum.map(fn {{sx, sz} = key, _} ->
        dx = (cx |> max(sx * size) |> min(sx * size + size - 1)) - cx
        dz = (cz |> max(sz * size) |> min(sz * size + size - 1)) - cz
        {dx * dx + dz * dz, key}
      end)
      |> Enum.sort()

    %{pending | order: {center, order}}
  end

  # `best`: at most `limit` candidates `{{distance, x, z}, chunk, pid, table}`,
  # ascending; `worst` the distance of the last once there are `limit`.
  defp walk([], sections, _source, _center, _limit, {best, _, _}), do: {best, sections}

  defp walk([{bound, _} | _], sections, _source, _center, limit, {best, limit, worst})
       when bound > worst,
       do: {best, sections}

  defp walk([{_, key} | rest], sections, source, center, limit, {best, _, _} = acc) do
    case sections do
      %{^key => entry} ->
        case visit(entry, source.(key)) do
          {nil, _} ->
            walk(rest, sections, source, center, limit, acc)

          {{pid, table, ready}, entry} ->
            sections = %{sections | key => entry}
            {cx, cz} = center

            found =
              ready
              |> Enum.map(fn {x, z} = chunk ->
                {{(x - cx) * (x - cx) + (z - cz) * (z - cz), x, z}, chunk, pid, table}
              end)
              |> Enum.sort()

            best = take(best, found, limit)
            n = length(best)
            worst = if n == limit, do: best |> List.last() |> elem(0) |> elem(0)
            walk(rest, sections, source, center, limit, {best, n, worst})
        end

      _ ->
        walk(rest, sections, source, center, limit, acc)
    end
  end

  # The section's generated pending chunks: all of them read again when its
  # publication's count (or table) changed, else only those added since and
  # still pending.
  defp visit({chunks, cue, ready, unchecked} = entry, source) do
    case source do
      nil ->
        {nil, entry}

      {pid, table, count} ->
        ready =
          cond do
            cue != {table, count} ->
              MapSet.new(World.generated(table, MapSet.to_list(chunks)))

            unchecked == [] ->
              ready

            true ->
              unchecked = Enum.filter(unchecked, &MapSet.member?(chunks, &1))
              MapSet.union(ready, MapSet.new(World.generated(table, unchecked)))
          end

        {{pid, table, ready}, {chunks, {table, count}, ready, []}}
    end
  end

  # The first `limit` of two ascending lists, merged.
  defp take(_a, _b, 0), do: []
  defp take([], b, limit), do: Enum.take(b, limit)
  defp take(a, [], limit), do: Enum.take(a, limit)

  defp take([x | a], [y | b], limit) do
    if elem(x, 0) <= elem(y, 0),
      do: [x | take(a, [y | b], limit - 1)],
      else: [y | take([x | a], b, limit - 1)]
  end
end
