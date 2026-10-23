defmodule Valimc.World.MobPaths do
  @moduledoc """
  A section's deferred path searches (VMC-041b). Its mobs' navigation asks
  for paths while they think (`{:path, uuid, n, request}` effects); the
  owner keeps the newest request per mob and runs them as one job at a time
  (`:paths` on its job table) of at most `@batch` searches. The job takes
  the published snapshots of the chunks the searches' regions cover and
  runs `Valimc.AI.Paths.find/2` over them in Rust, so no owner waits on a
  search.

  A result's fence is the snapshot of each chunk the search read. When the
  job reports, a result is current only while every one of those chunks is
  still published as it was; one made from an older snapshot is `:stale`
  (the mob drops it and recomputes). Results wait in `ready`, by `{uuid,
  n}`, for the mobs' next tick (`Valimc.AI.World`'s `paths`), and go with it.
  """
  alias Valimc.AI.Paths
  alias Valimc.World.{Jobs, View}

  @batch 32

  defstruct queue: %{}, order: [], ready: %{}

  @doc "Queue the path requests of mob steps' effects (the newest per mob)."
  def queue(%__MODULE__{} = paths, steps) do
    for step <- steps, {:path, uuid, n, request} <- step.effects, reduce: paths do
      acc ->
        order = if Map.has_key?(acc.queue, uuid), do: acc.order, else: acc.order ++ [uuid]
        %{acc | queue: Map.put(acc.queue, uuid, {n, request}), order: order}
    end
  end

  @doc "The results for the mobs' next tick, and the state without them."
  def take(%__MODULE__{ready: ready} = paths), do: {ready, %{paths | ready: %{}}}

  @doc """
  Start the next batch when none runs: `{:ok, paths, batch, work}` for the
  owner to run as job `:paths`, or `:idle`.
  """
  def next(%__MODULE__{order: []}, _jobs, _dimension), do: :idle

  def next(%__MODULE__{} = paths, jobs, dimension) do
    if Jobs.running?(jobs, :paths) do
      :idle
    else
      {uuids, rest} = Enum.split(paths.order, @batch)
      batch = for uuid <- uuids, {n, request} = paths.queue[uuid], do: {uuid, n, request}
      paths = %{paths | order: rest, queue: Map.drop(paths.queue, uuids)}
      {:ok, paths, batch, fn -> work(dimension, batch) end}
    end
  end

  # The job: the snapshots of the regions' chunks, the searches over them,
  # each result with the snapshots it read.
  defp work(dimension, batch) do
    view = View.new(dimension)

    chunks =
      batch
      |> Enum.flat_map(fn {_, _, %{region: {{x0, _, z0}, {x1, _, z1}}}} ->
        for cx <- Bitwise.bsr(x0, 4)..Bitwise.bsr(x1, 4),
            cz <- Bitwise.bsr(z0, 4)..Bitwise.bsr(z1, 4),
            do: {cx, cz}
      end)
      |> Enum.uniq()

    handles =
      for chunk <- chunks,
          (handle = View.row(view, chunk)) != :unavailable,
          into: %{},
          do: {chunk, handle}

    cells = {:rows, Map.values(handles), Valimc.Protocol.Data.block("air")}
    results = Paths.find(cells, Enum.map(batch, &elem(&1, 2)))

    Enum.zip_with(batch, results, fn {uuid, n, _}, {path, random, read} ->
      fence = for chunk <- read, do: {chunk, Map.fetch!(handles, chunk)}
      {{uuid, n}, {path, random, read}, fence}
    end)
  end

  @doc """
  The job's results, each kept when its chunks are still published as it
  read them, else `:stale`.
  """
  def done(%__MODULE__{} = paths, results, dimension) do
    view = View.new(dimension)

    ready =
      for {key, result, fence} <- results, into: paths.ready do
        current = Enum.all?(fence, fn {chunk, handle} -> View.row(view, chunk) == handle end)
        {key, if(current, do: result, else: :stale)}
      end

    %{paths | ready: ready}
  end
end
