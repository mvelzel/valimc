defmodule Valimc.Worldgen.Frontier.Memory do
  @moduledoc """
  Proto cells in memory, bounded (VMC-077q, VMC-077x1).

  The cells in memory are indexed by when a job last used them. Past `cap`, a
  pass takes the least recently used first: a cell work soon needs (held by a
  job, a goal's, or within 1 of a needed decoration) moves to the
  recent end, terrain no decoration wrote into is dropped and made again when
  needed (terrain reads only the starts' beards, which placement never
  changes, so it comes out the same), and any other cell spills: a job writes
  its encoding to a scratch file that is never durable state (`spill_job/2`),
  and a job that needs it decodes it there and hands it back. A decoration
  cannot be made again exactly without replaying, in number order, every
  earlier decoration within 2 of it, transitively; a spilled cell is the chunk
  itself. A pass costs what it looks at.
  """
  alias Valimc.Native
  alias Valimc.Worldgen.Frontier
  alias Valimc.Worldgen.Frontier.{Dependencies, Goals}

  import Dependencies, only: [around: 2]

  @doc "`chunk`'s cell `cell` is in memory now (made, or read back)."
  def put(f, chunk, cell, status) do
    clock = f.clock + 1
    entry = Map.get(f.chunks, chunk, %{})
    f = release(f, chunk)
    entry = Map.merge(entry, %{status: status, cell: cell, used: clock})

    %{
      f
      | chunks: Map.put(f.chunks, chunk, entry),
        lru: :gb_sets.add({clock, chunk}, f.lru),
        in_memory: f.in_memory + 1,
        clock: clock
    }
  end

  @doc "A job uses `chunks`: they are the most recently used."
  def touch(f, chunks) do
    clock = f.clock + 1

    Enum.reduce(chunks, %{f | clock: clock}, fn chunk, f ->
      case f.chunks do
        %{^chunk => %{cell: cell, used: used} = entry} when is_reference(cell) ->
          lru = :gb_sets.add({clock, chunk}, :gb_sets.delete({used, chunk}, f.lru))
          %{f | chunks: Map.put(f.chunks, chunk, %{entry | used: clock}), lru: lru}

        _ ->
          f
      end
    end)
  end

  @doc "`chunk`'s cell leaves memory (the entry stays)."
  def release(f, chunk) do
    case f.chunks do
      %{^chunk => %{cell: cell, used: used}} when is_reference(cell) ->
        %{f | lru: :gb_sets.delete({used, chunk}, f.lru), in_memory: f.in_memory - 1}

      _ ->
        f
    end
  end

  @doc """
  Past `cap` cells in memory, make room down to seven eighths of it: `{f,
  spills}`, at most `limit` cells (`{chunk, cell}`) to spill, looking at no
  more than as many.
  """
  def evictions(f, limit \\ 64)

  def evictions(%Frontier{cap: cap, in_memory: n} = f, limit)
      when is_integer(cap) and n > cap do
    keep = cap - div(cap, 8)
    sweep(:gb_sets.iterator(f.lru), f, keep, limit, limit, [])
  end

  def evictions(f, _limit), do: {f, []}

  defp sweep(cells, f, keep, limit, budget, spills) do
    with true <- f.in_memory - length(spills) > keep and length(spills) < limit and budget > 0,
         {{_, chunk}, cells} <- :gb_sets.next(cells) do
      cond do
        protected?(f, chunk) ->
          sweep(cells, touch(f, [chunk]), keep, limit, budget - 1, spills)

        droppable?(f, chunk) ->
          f = %{release(f, chunk) | chunks: Map.delete(f.chunks, chunk), dropped: f.dropped + 1}
          sweep(cells, Dependencies.made(f, chunk, false), keep, limit, budget - 1, spills)

        true ->
          spills = [{chunk, f.chunks[chunk].cell} | spills]
          sweep(cells, f, keep, limit, budget - 1, spills)
      end
    else
      _ -> {f, Enum.reverse(spills)}
    end
  end

  defp protected?(f, chunk) do
    Map.has_key?(f.busy, chunk) or Goals.goal?(f, chunk) or
      Enum.any?(around(chunk, 1), &Dependencies.needed?(f, &1))
  end

  # Terrain no decoration wrote into: no chunk within 1 of it decorated.
  defp droppable?(f, chunk) do
    Dependencies.status(f, chunk) == :terrain and
      not Enum.any?(around(chunk, 1), &Dependencies.decorated?(f, &1))
  end

  @doc """
  A job that writes `spills` (`{chunk, cell}`, from `evictions/2`) to the
  scratch file, holding their chunks meanwhile, so the encoding runs outside
  the scheduler: `{job, f}`, the job as `Frontier.next/3` returns them. One
  runs at a time: it appends.
  """
  def spill_job(%Frontier{} = f, spills) do
    ref = make_ref()
    chunks = Enum.map(spills, &elem(&1, 0))
    job = %{ref: ref, kind: :spill, chunk: nil, holds: chunks, bulk: false}
    path = f.scratch
    busy = Enum.reduce(chunks, f.busy, &Map.put(&2, &1, ref))
    f = %{f | busy: busy, jobs: Map.put(f.jobs, ref, job)}
    {Map.put(job, :run, fn -> write_spills(path, spills) end), f}
  end

  defp write_spills(path, spills) do
    {:ok, file} = :file.open(path, [:read, :write, :raw, :binary])

    try do
      {:ok, start} = :file.position(file, :eof)

      {locations, _} =
        Enum.map_reduce(spills, start, fn {chunk, cell}, offset ->
          {:ok, bytes} = Native.gen_encode(cell)
          :ok = :file.write(file, bytes)
          {{chunk, offset, byte_size(bytes)}, offset + byte_size(bytes)}
        end)

      {:ok, locations}
    after
      :file.close(file)
    end
  end

  @doc """
  These cells (`{chunk, offset, size}`) are written to the scratch file: they
  leave memory, to be read back from there.
  """
  def spilled(%Frontier{} = f, locations) do
    Enum.reduce(locations, f, fn {chunk, offset, size}, f ->
      case f.chunks do
        %{^chunk => %{cell: cell} = entry} when is_reference(cell) ->
          f = release(f, chunk)
          entry = %{entry | cell: {:spilled, offset, size}}
          %{f | chunks: Map.put(f.chunks, chunk, entry), spills: f.spills + 1}

        _ ->
          f
      end
    end)
  end

  @doc "A spilled cell's encoding, read from the scratch file at `path`."
  def read_spilled(path, offset, size) do
    with {:ok, file} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(file, offset, size) do
          {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
          other -> {:error, {:short_read, other}}
        end
      after
        :file.close(file)
      end
    end
  end

  @doc "The proto cells in memory (the memory gauge)."
  def cells(%Frontier{} = f),
    do: for({_, %{cell: cell}} <- f.chunks, is_reference(cell), do: cell)
end
