defmodule Valimc.World.RegionGeneration do
  @moduledoc """
  Per-chunk generation of a region's chunks (VMC-075), run by its owner.

  A region of a generated world loads without generating: the chunks its log
  has no column for are absent. Views say which chunks they want and how far
  from their player (`want/4`); calls that need an absent chunk want it first
  (`urgent/2`). The owner generates the wanted absent chunks nearest first, in
  bounded batches and never on itself: a terrain world on
  `Valimc.WorldgenWorkers` (`Generator.columns/2`), a decorated world through
  its proto owner (`Proto.request_full_chunks/2`). A batch is persisted as one
  store frame (`Store.commit_generated/5`) and installed once durable: its
  columns relit once, its block entities and ticks added, its snapshots
  published, neighbours' rings and served chunks' light updated, and the calls
  that waited for it run again. A failed batch stays wanted and is retried
  after a backoff.

  Until then an absent chunk is like a chunk of an unloaded neighbour region:
  the owner's block reads see nothing there and edits of it are refused.
  """
  require Logger
  alias Valimc.World
  alias Valimc.World.{BlockEntities, BlockSnapshot, Blocks, Generator, RegionData}
  alias Valimc.World.{ScheduledTicks, Store}
  alias Valimc.Worldgen.{FullChunk, Proto}

  # Terrain: jobs of a few chunks, so the nearest chunks are not stuck behind a
  # long batch. A decorated world's proto owner runs one transaction at a time,
  # whose locks dominate it: 16 chunks a request took a whole view in about
  # 0.7 × the time of 8 (VMC-075), and a second request keeps the owner busy
  # while the first is persisted.
  @terrain_batch 4
  @terrain_jobs 4
  @proto_batch 16
  @proto_requests 2
  @max_deferred 1024

  defstruct mode: nil,
            spec: nil,
            absent: MapSet.new(),
            wants: %{},
            jobs: %{},
            requests: nil,
            saving: %{},
            deferred: %{},
            deferred_count: 0,
            retry: nil,
            failures: 0

  @doc "The generation state of region `key` whose log holds column `images`."
  def new(key, images) do
    base = Valimc.config(:world_path, key)
    dimension = Valimc.Dimension.current()

    if Generator.generates?(base, dimension) do
      absent = for chunk <- Proto.chunks_of(key), not Map.has_key?(images, chunk), do: chunk

      mode = if Generator.decorated?(base, dimension), do: :decorated, else: :terrain

      spec =
        case {mode, absent} do
          {:terrain, [_ | _]} ->
            case Generator.spec(base, dimension) do
              {:ok, spec} -> spec
              {:error, reason} -> exit({:generation_unavailable, reason})
            end

          _ ->
            nil
        end

      %__MODULE__{
        mode: mode,
        spec: spec,
        absent: MapSet.new(absent),
        requests: :gen_server.reqids_new()
      }
    else
      %__MODULE__{requests: :gen_server.reqids_new()}
    end
  end

  @doc "Whether `chunk` is not generated yet."
  def absent?(%__MODULE__{absent: absent}, chunk), do: MapSet.member?(absent, chunk)

  @doc "Whether any of `chunks` is not generated yet."
  def any_absent?(%__MODULE__{absent: absent}, chunks),
    do: map_size(absent.map) > 0 and Enum.any?(chunks, &MapSet.member?(absent, &1))

  @doc """
  `requester` (a connection) wants `chunks` of the region, as far as they are
  from `center`; a later call replaces its wants, an empty list withdraws them.
  """
  def want(state, requester, {cx, cz} = center, chunks)
      when is_integer(cx) and is_integer(cz) and is_list(chunks) do
    gen = state.generation
    wanted = chunks |> Enum.take(64) |> Enum.filter(&absent?(gen, &1)) |> MapSet.new()

    wants =
      if MapSet.size(wanted) == 0,
        do: Map.delete(gen.wants, requester),
        else: Map.put(gen.wants, requester, {center, wanted})

    pump(%{state | generation: %{gen | wants: wants}})
  end

  def want(state, _requester, _center, _chunks), do: state

  @doc "Absent `chunks` some call needs: wanted before anything else."
  def urgent(state, chunks) do
    gen = state.generation

    case Enum.filter(chunks, &absent?(gen, &1)) do
      [] ->
        state

      missing ->
        {_, set} = Map.get(gen.wants, :urgent, {nil, MapSet.new()})
        wants = Map.put(gen.wants, :urgent, {nil, Enum.into(missing, set)})
        pump(%{state | generation: %{gen | wants: wants}})
    end
  end

  @doc """
  Run `message` from `from` again once `chunk` is installed, wanting it now;
  `{:reply, {:error, :chunk_generating}, state}` when too many calls wait.
  """
  def defer(state, chunk, message, from) do
    gen = state.generation

    if gen.deferred_count >= @max_deferred do
      {:reply, {:error, :chunk_generating}, state}
    else
      deferred = Map.update(gen.deferred, chunk, [{message, from}], &[{message, from} | &1])
      gen = %{gen | deferred: deferred, deferred_count: gen.deferred_count + 1}
      {:noreply, urgent(%{state | generation: gen}, [chunk])}
    end
  end

  ## Batches

  @doc """
  The wanted absent chunks no batch holds, nearest to a requester's center
  first (each chunk at its smallest distance), urgent ones before all.
  """
  def queue(%__MODULE__{} = gen) do
    busy =
      Enum.reduce(Map.values(gen.jobs), MapSet.new(), &Enum.into(&1.chunks, &2))
      |> then(fn busy ->
        Enum.reduce(Map.values(gen.saving), busy, &Enum.into(&1.chunks, &2))
      end)

    gen.wants
    |> Enum.flat_map(fn
      {:urgent, {_, set}} ->
        for chunk <- set, do: {chunk, -1}

      {_, {{cx, cz}, set}} ->
        for {x, z} = chunk <- set, do: {chunk, (x - cx) * (x - cx) + (z - cz) * (z - cz)}
    end)
    |> Enum.reject(fn {chunk, _} -> MapSet.member?(busy, chunk) or not absent?(gen, chunk) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {chunk, priorities} -> {Enum.min(priorities), chunk} end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Start batches while the region's bounds allow."
  def pump(%{generation: %{retry: retry}} = state) when retry != nil, do: state
  def pump(%{generation: %{wants: wants}} = state) when map_size(wants) == 0, do: state

  def pump(%{generation: %{mode: :terrain} = gen} = state) do
    if map_size(gen.jobs) >= @terrain_jobs do
      state
    else
      case queue(gen) do
        [] -> state
        queue -> start_terrain(state, Enum.take(queue, @terrain_batch))
      end
    end
  end

  def pump(%{generation: %{mode: :decorated} = gen} = state) do
    if map_size(gen.jobs) >= @proto_requests do
      state
    else
      case queue(gen) do
        [] -> state
        queue -> start_proto(state, Enum.take(queue, @proto_batch))
      end
    end
  end

  def pump(state), do: state

  defp start_terrain(state, chunks) do
    gen = state.generation
    owner = self()
    epoch = state.items.epoch
    ref = make_ref()
    spec = gen.spec

    job =
      Valimc.Dimension.bind(fn ->
        result =
          try do
            {:ok, Generator.columns(spec, chunks)}
          rescue
            error -> {:error, Exception.message(error)}
          catch
            :exit, reason -> {:error, reason}
          end

        send(owner, {:resource, epoch, {:generated, ref, result}})
      end)

    case Task.Supervisor.start_child(Valimc.WorldgenWorkers, job) do
      {:ok, pid} ->
        entry = %{chunks: chunks, monitor: Process.monitor(pid), started: now()}
        pump(%{state | generation: %{gen | jobs: Map.put(gen.jobs, ref, entry)}})

      {:error, _} ->
        # Every worker is busy: try again shortly.
        backoff(state, 10)
    end
  end

  defp start_proto(state, chunks) do
    gen = state.generation

    case Proto.request_full_chunks(state.key, chunks) do
      {:ok, request} ->
        ref = make_ref()
        requests = :gen_server.reqids_add(request, ref, gen.requests)
        entry = %{chunks: chunks, monitor: nil, started: now()}
        gen = %{gen | jobs: Map.put(gen.jobs, ref, entry), requests: requests}
        pump(%{state | generation: gen})

      {:error, reason} ->
        failed(state, reason)
    end
  end

  defp backoff(state, delay) do
    gen = state.generation
    timer = Process.send_after(self(), {:resource, state.items.epoch, :generation_retry}, delay)
    %{state | generation: %{gen | retry: timer}}
  end

  defp failed(state, reason) do
    gen = state.generation
    failures = gen.failures + 1

    if failures in [1, 10, 100],
      do: Logger.warning("Generating in region #{inspect(state.key)}: #{inspect(reason)}")

    backoff(%{state | generation: %{gen | failures: failures}}, min(5000, 50 * failures))
  end

  @doc "The retry timer fired."
  def retry(state), do: pump(%{state | generation: %{state.generation | retry: nil}})

  ## Results

  @doc "A terrain job's result (`{:ok, chunk => image}` or an error)."
  def generated(state, ref, result) do
    gen = state.generation

    case Map.pop(gen.jobs, ref) do
      {nil, _} ->
        state

      {job, jobs} ->
        if job.monitor, do: Process.demonitor(job.monitor, [:flush])
        Valimc.Metrics.add(:worldgen_microseconds, now() - job.started)
        state = %{state | generation: %{gen | jobs: jobs}}

        case result do
          {:ok, columns} when is_map(columns) ->
            parts = %{columns: Map.take(columns, job.chunks), post_processing: %{}}
            persist(state, job.chunks, Map.merge(parts, %{block_entities: %{}, ticks: []}))

          error ->
            failed(state, error)
        end
    end
  end

  @doc """
  A message that may answer a proto request: `{:ok, state}` when it did,
  `:no_reply` otherwise.
  """
  def proto_response(state, message) do
    gen = state.generation

    case :gen_server.check_response(message, gen.requests, true) do
      {response, ref, requests} ->
        state = %{state | generation: %{gen | requests: requests}}
        {:ok, proto_done(state, ref, response)}

      _ ->
        :no_reply
    end
  end

  defp proto_done(state, ref, response) do
    gen = state.generation
    {job, jobs} = Map.pop(gen.jobs, ref)
    Valimc.Metrics.add(:worldgen_microseconds, now() - job.started)
    state = %{state | generation: %{gen | jobs: jobs}}

    with {:reply, {:ok, full}} <- response,
         {:ok, parts} <- FullChunk.parts(full, %{}, []) do
      persist(state, job.chunks, parts)
    else
      {:reply, {:error, :handed_over}} ->
        # The proto owner dropped chunks this region never stored: they cannot
        # be generated again (a lost column), so they stay absent.
        Logger.error("Region #{inspect(state.key)} lost generated chunks #{inspect(job.chunks)}")
        state

      error ->
        failed(state, error)
    end
  end

  @doc "A job's worker went down without reporting: `{:ok, state}` if it was one."
  def down(state, monitor) do
    gen = state.generation

    case Enum.find(gen.jobs, fn {_, job} -> job.monitor == monitor end) do
      {ref, _} ->
        state = %{state | generation: %{gen | jobs: Map.delete(gen.jobs, ref)}}
        {:ok, failed(state, :worker_down)}

      nil ->
        :error
    end
  end

  defp persist(state, chunks, parts) do
    gen = state.generation
    token = make_ref()
    owner = {self(), state.items.epoch}
    Store.commit_generated(state.store, state.store_lease, parts, owner, token)
    saving = Map.put(gen.saving, token, %{chunks: chunks, parts: parts, started: now()})
    pump(%{state | generation: %{gen | saving: saving, failures: 0}})
  end

  @doc "The store acknowledged a batch's frame: install it once durable."
  def saved(state, token, result) do
    gen = state.generation

    case Map.pop(gen.saving, token) do
      {nil, _} ->
        state

      {entry, saving} ->
        state = %{state | generation: %{gen | saving: saving}}

        case result do
          :ok ->
            Valimc.Metrics.add(:column_persist_microseconds, now() - entry.started)
            install(state, entry.parts)

          error ->
            failed(state, error)
        end
    end
  end

  # Install durable generated chunks; they were absent, so no reader saw them.
  defp install(state, parts) do
    gen = state.generation
    columns = Map.filter(parts.columns, fn {chunk, _} -> absent?(gen, chunk) end)
    chunks = Map.keys(columns)

    {:ok, lit} =
      case Blocks.put_columns(state.blocks, columns) do
        {:ok, _} = ok -> ok
        {:error, reason} -> exit({:generated_install_failed, reason})
      end

    entities =
      case BlockEntities.add(state.block_entities, parts.block_entities) do
        {:ok, entities} -> entities
        {:error, reason} -> exit({:generated_install_failed, reason})
      end

    ticks =
      Enum.reduce(parts.ticks, state.scheduled_ticks, fn {position, block, delay, priority},
                                                         acc ->
        case ScheduledTicks.schedule(acc, position, block, state.game_tick + delay, priority) do
          {:ok, next} -> next
          {:error, _} -> acc
        end
      end)

    installed = MapSet.new(chunks)

    wants =
      for {requester, {center, set}} <- gen.wants,
          set = MapSet.difference(set, installed),
          MapSet.size(set) > 0,
          into: %{},
          do: {requester, {center, set}}

    {deferred, waiting} = Map.split(gen.deferred, chunks)
    count = gen.deferred_count - Enum.sum(Enum.map(deferred, fn {_, calls} -> length(calls) end))

    gen = %{
      gen
      | absent: MapSet.difference(gen.absent, installed),
        wants: wants,
        deferred: waiting,
        deferred_count: count
    }

    state = %{
      state
      | generation: gen,
        block_entities: entities,
        scheduled_ticks: ticks,
        ticks_dirty: state.ticks_dirty or parts.ticks != []
    }

    :ok =
      BlockSnapshot.publish_chunks(state.item_publication, state.blocks, chunks, state.revision)

    Valimc.Metrics.add(:worldgen_chunks, length(chunks))

    # Served chunks next to the new ones were lit with them absent.
    state = RegionData.light_changed(state, lit)

    case Enum.filter(lit, &(MapSet.member?(state.served, &1) and &1 not in chunks)) do
      [] ->
        :ok

      served ->
        World.publish(state.key, {:block_batch, Valimc.World.LightHalo.frames(state, served)})
    end

    state = Valimc.World.LightHalo.columns_changed(state, columns)
    if gen.mode == :decorated, do: Proto.handed_over(state.key, chunks)

    state =
      deferred
      |> Enum.flat_map(fn {_, calls} -> Enum.reverse(calls) end)
      |> Enum.reduce(state, fn {message, from}, acc ->
        case RegionData.handle_call(message, from, acc) do
          {:reply, reply, acc} ->
            GenServer.reply(from, reply)
            acc

          {:noreply, acc} ->
            acc
        end
      end)

    pump(state)
  end

  defp now, do: System.monotonic_time(:microsecond)

  @doc "Ticks of batches still being persisted (`Store.commit_ticks/5` entries)."
  def saving_ticks(%__MODULE__{saving: saving}),
    do: Enum.flat_map(saving, fn {_, entry} -> entry.parts.ticks end)
end
