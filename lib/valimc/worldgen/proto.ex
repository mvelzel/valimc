defmodule Valimc.Worldgen.Proto do
  @moduledoc """
  One region's proto chunks in a decorated vanilla world (VMC-025d2): the
  owner of its chunks before they are final, of their statuses (`:terrain`,
  `:decorated`) and of the finalize transaction that makes the region final.
  Its durable state is a `Valimc.Worldgen.ProtoLog`; terrain runs on
  `Valimc.WorldgenWorkers`, decoration and full chunks on
  `Valimc.DecorationWorkers` (dirty NIFs), never in here. Each owner
  generates the terrain of the earliest-started transaction first, so areas
  complete one after another and decorate while other terrain is generated.

  A chunk is final once every chunk of its 3 × 3 is decorated. A decoration
  reads and writes only its 3 × 3 (VMC-025 measured it), so a final chunk is
  never touched again, and every undecorated chunk's 3 × 3 is non-final.

  Finalizing region `R` (coordinated by `R`'s owner, presumed abort with
  durable prepare):

  1. Terrain: each of the nine owners around `R` generates the terrain it
     lacks among its chunks of the 12 × 12 around `R` (ordered by when `R`
     first tried to finalize) and answers once they exist. Nothing is locked
     yet.
  2. Lock, all nine at once and never waiting: an owner locks its non-final
     chunks for the transaction (`Txn.Permits` kind `:generation`) and
     answers with their images and which are final, or answers busy if any
     is locked. One busy owner and the coordinator gives every lock back and
     tries again after a random delay, or sooner when that owner releases a
     lock. A transaction never holds locks while it waits for another, so
     transactions whose areas do not overlap run at once.
  3. Prepare and decorate together: each foreign owner that locked chunks
     makes its lock durable, while every undecorated chunk of the 10 × 10
     around `R` is decorated, Z outer and X inner, in one native call over the
     locked images (waiting while its worker pool is full).
  4. Commit, once decorated and prepared, one frame: `R`'s changed chunks, its
     64 chunks final, and an outbox entry per foreign participant
     (`Txn.Receipts` sequence from the log incarnation and transaction count,
     digest of the part).
  5. Deliver each part (`Txn.Delivery`); the participant applies it, unlocks
     and records the receipt in one frame, idempotently.

  A lock that is not yet durable dies with its coordinator: the transaction
  cannot have committed without it.

  A participant holding a durable lock whose coordinator died or restarted
  asks it (`status/2`, starting it if needed): a committed part is applied, a
  transaction still running is awaited, anything else was aborted and is
  unlocked. Transaction identities carry the coordinator's log incarnation,
  so an aborted one is never confused with a later one.

  The live region takes its final chunks with `full_chunks/1` and, once it
  has persisted them, `handed_over/1` drops their images here.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Native
  alias Valimc.Txn.{Delivery, Permits, Receipts}
  alias Valimc.Worldgen.ProtoLog
  alias Valimc.World.Generator

  defstruct [
    :key,
    :worldgen,
    :biome_source,
    :log,
    :txn,
    :retry,
    :full_job,
    incarnation: 0,
    txn_count: 0,
    writes: %{},
    chunks: %{},
    final: MapSet.new(),
    dropped: MapSet.new(),
    terrain: %{queue: [], pending: MapSet.new(), jobs: %{}, timer: nil},
    locks: %{},
    permits: %Permits{},
    grants: %{},
    requests: [],
    receipts: %{},
    outbox: %{},
    deliveries: %{},
    resolving: %{},
    monitors: %{},
    attempts: 0,
    busy: 0,
    # When this owner first tried to finalize: its terrain requests' priority.
    since: nil,
    waiters: [],
    calls: 0,
    quiet: {0, 0},
    # Requests to other owners (`:gen_server.send_request/4`).
    out: nil,
    # Coordinators this owner answered busy, woken when it releases a lock.
    wake: MapSet.new()
  ]

  # A transaction's terrain, locks and prepares must arrive within this.
  @lock_timeout 120_000
  @call_timeout 30_000
  @max_requests 32
  @terrain_batch 4
  @resolve_every 30_000
  # An owner with nothing in flight stops after this many quiet resolve rounds
  # (its state is durable; untouched terrain is generated again if needed).
  @idle_rounds 10
  # Recovery that runs out of file descriptors waits this long at most.
  @recovery_wait 30_000
  # An owner whose chunks are all final and handed over stops this soon after,
  # once nothing is in flight (VMC-074); neighbours start it again if needed.
  @retire_after 5_000
  @max_attempts 40

  ## API

  # `scoped` is the region key scoped by its dimension (`Valimc.Dimension`).
  def start_link(scoped),
    do:
      GenServer.start_link(__MODULE__, scoped,
        name: {:via, Registry, {Valimc.ProtoRegistry, scoped}}
      )

  def child_spec(scoped),
    do: %{
      id: {__MODULE__, scoped},
      start: {__MODULE__, :start_link, [scoped]},
      restart: :temporary,
      shutdown: 10_000
    }

  @doc "The proto owner of region `key`, started if needed."
  def owner(key), do: owner(key, 50)

  defp owner(_key, 0), do: {:error, :proto_owner_restarting}

  defp owner(key, attempts) do
    scoped = Valimc.Dimension.scope(key)

    case Registry.lookup(Valimc.ProtoRegistry, scoped) do
      [{pid, _}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: retry_owner(key, attempts)

      [] ->
        case DynamicSupervisor.start_child(Valimc.ProtoSupervisor, {__MODULE__, scoped}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} -> retry_owner(key, attempts)
        end
    end
  end

  defp retry_owner(key, attempts) do
    Process.sleep(2)
    owner(key, attempts - 1)
  end

  @doc """
  The region's 64 chunks made full (`worldgen_proto_full` maps), finalizing
  the region first if needed. `{:error, :handed_over}` once the live region
  holds them.
  """
  def full_chunks(key, timeout \\ 600_000), do: call(key, :full_chunks, timeout)

  @doc "The live region persisted its final chunks: drop their images."
  def handed_over(key) do
    with {:ok, pid} <- owner(key), do: GenServer.cast(pid, :handed_over)
  end

  @doc false
  def apply_part(key, request), do: call(key, {:apply, request}, @call_timeout)
  @doc false
  def status(key, txn, asker), do: call(key, {:status, txn, asker}, @call_timeout)

  defp call(key, message, timeout) do
    with {:ok, pid} <- owner(key), do: GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :proto_timeout}
    :exit, _ -> {:error, :proto_owner_unavailable}
  end

  ## Geometry

  @doc "Region `key`'s chunks, Z outer and X inner."
  def chunks_of({rx, rz}) do
    size = Valimc.config(:region_size)

    for cz <- (rz * size)..(rz * size + size - 1),
        cx <- (rx * size)..(rx * size + size - 1),
        do: {cx, cz}
  end

  @doc "The chunks within `r` of region `key`, Z outer and X inner."
  def around({rx, rz}, r) do
    size = Valimc.config(:region_size)

    for cz <- (rz * size - r)..(rz * size + size - 1 + r),
        cx <- (rx * size - r)..(rx * size + size - 1 + r),
        do: {cx, cz}
  end

  defp region_of(chunk), do: Valimc.World.region_key(chunk)

  ## Owner

  @impl true
  def init(scoped) do
    Process.flag(:trap_exit, true)
    {dimension, key} = Valimc.Dimension.unscope(scoped)
    Valimc.Dimension.put(dimension)
    {:ok, %__MODULE__{key: key, out: :gen_server.reqids_new()}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %__MODULE__{key: {rx, rz} = key} = empty) do
    world = Valimc.config(:world_path, key)
    dimension = Valimc.Dimension.current()
    base = Valimc.Dimension.storage(world, dimension)

    case Generator.spec(world, dimension) do
      {:ok, %{kind: :noise} = spec} ->
        dir = base && Path.join([base, "gen", "r.#{rx}.#{rz}"])

        # Out of file descriptors, recovery waits and tries again (VMC-074).
        case Valimc.FileBudget.retry(fn -> ProtoLog.open(dir) end, @recovery_wait) do
          {:ok, log, durable, incarnation} -> loaded(empty, spec, log, durable, incarnation)
          {:error, reason} -> {:stop, {:shutdown, {:proto_log_recovery_failed, reason}}, empty}
        end

      _ ->
        {:stop, {:shutdown, :not_generated}, empty}
    end
  end

  defp loaded(empty, spec, log, durable, incarnation) do
    {:ok, worldgen} = Generator.worldgen(spec.seed, spec.noise_settings, spec.facts)

    state = %{
      empty
      | worldgen: worldgen,
        biome_source: spec.biome_source,
        log: log,
        incarnation: incarnation,
        chunks: durable.chunks,
        final: MapSet.union(durable.final, durable.dropped),
        dropped: durable.dropped,
        receipts: durable.receipts,
        outbox: durable.outbox
    }

    state =
      Enum.reduce(durable.locks, state, fn {txn, grant}, acc ->
        hold(acc, txn, grant.coordinator, grant.chunks, true)
      end)

    state = Enum.reduce(Map.keys(state.outbox), state, &deliver_all(&2, &1))
    send(self(), :resolve)
    if handed_over?(state), do: Process.send_after(self(), :retire, @retire_after)
    {:noreply, state}
  end

  defp handed_over?(state),
    do: Enum.all?(chunks_of(state.key), &MapSet.member?(state.dropped, &1))

  # Full chunks for the live region.
  @impl true
  def handle_call(:full_chunks, from, state) do
    state = %{state | calls: state.calls + 1}
    own = chunks_of(state.key)

    cond do
      Enum.any?(own, &MapSet.member?(state.dropped, &1)) ->
        {:reply, {:error, :handed_over}, state}

      true ->
        state = %{state | waiters: [from | state.waiters]}

        if Enum.all?(own, &MapSet.member?(state.final, &1)),
          do: {:noreply, start_full(state)},
          else: {:noreply, maybe_finalize(state)}
    end
  end

  # Participant: answer once a transaction's chunks have terrain.
  def handle_call({:terrain, %{txn: txn, chunks: chunks, since: since}}, from, state) do
    state = %{state | calls: state.calls + 1}
    entry = %{txn: txn, chunks: chunks, since: since, reply: {:call, from}}

    if Enum.all?(chunks, &(region_of(&1) == state.key)),
      do: {:noreply, wait_terrain(state, entry)},
      else: {:reply, {:error, :invalid_generation_lock}, state}
  end

  # Participant: lock chunks for a foreign transaction now, or answer busy.
  def handle_call({:lock, %{chunks: chunks} = request}, _from, state) do
    state = %{state | calls: state.calls + 1}

    if Enum.all?(chunks, &(region_of(&1) == state.key)) do
      {reply, state} = try_lock(state, request)
      {:reply, reply, state}
    else
      {:reply, {:error, :invalid_generation_lock}, state}
    end
  end

  # Participant: make a granted lock durable before its coordinator commits.
  def handle_call({:prepare, txn}, from, state) do
    case state.grants do
      %{^txn => %{durable: true}} ->
        {:reply, {:ok, :prepared}, state}

      %{^txn => grant} ->
        # Durable from here on: a crash of the coordinator now asks it what
        # became of the transaction instead of dropping the lock.
        state = put_in(state.grants[txn], %{grant | durable: true})
        op = {:lock, txn, %{coordinator: grant.coordinator, chunks: grant.chunks}}

        {:noreply,
         write(state, [op], fn state, :ok ->
           GenServer.reply(from, {:ok, :prepared})
           state
         end)}

      _ ->
        {:reply, {:error, :generation_lock_released}, state}
    end
  end

  # Participant: a committed transaction's part.
  def handle_call({:apply, request}, from, state) do
    state = %{state | calls: state.calls + 1}

    case apply_part_locally(state, request, {:call, from}) do
      {:reply, reply, state} -> {:reply, reply, state}
      {:noreply, state} -> {:noreply, state}
    end
  end

  # Coordinator: what became of `txn` (presumed abort).
  def handle_call({:status, txn, asker}, _from, state) do
    state = %{state | calls: state.calls + 1}

    reply =
      cond do
        state.txn != nil and state.txn.id == txn -> {:running, self()}
        Map.has_key?(state.outbox, txn) -> {:committed, Map.get(state.outbox[txn], asker)}
        true -> :unknown
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:handed_over, state) do
    own = chunks_of(state.key)

    if Enum.all?(own, &MapSet.member?(state.final, &1)) and
         not Enum.all?(own, &MapSet.member?(state.dropped, &1)) do
      {:noreply,
       write(state, [{:dropped, own}], fn state, :ok ->
         Process.send_after(self(), :retire, @retire_after)

         %{
           state
           | chunks: Map.drop(state.chunks, own),
             dropped: MapSet.union(state.dropped, MapSet.new(own))
         }
       end)}
    else
      {:noreply, state}
    end
  end

  # Participant: a coordinator gave its lock back (`wake?`: it held it for a
  # real transaction, not a busy attempt).
  def handle_cast({:release, txn, wake?}, state), do: {:noreply, release_lock(state, txn, wake?)}

  # Answers to this owner's requests to other owners come first.
  @impl true
  def handle_info(message, state) do
    case :gen_server.check_response(message, state.out, true) do
      {{:reply, reply}, label, out} ->
        {:noreply, txn_reply(%{state | out: out}, label, reply)}

      {{:error, {reason, _}}, label, out} ->
        {:noreply, txn_reply(%{state | out: out}, label, {:error, {:proto_owner_down, reason}})}

      _ ->
        info(message, state)
    end
  end

  defp info({:proto_saved, token, result}, state) do
    {continuation, writes} = Map.pop(state.writes, token)
    state = %{state | writes: writes}

    case result do
      :ok -> {:noreply, continuation.(state, :ok)}
      {:error, reason} -> {:stop, {:proto_write_failed, reason}, state}
    end
  end

  defp info({:terrain_done, ref, result}, state) do
    {chunks, jobs} = Map.pop(state.terrain.jobs, ref)
    terrain = %{state.terrain | jobs: jobs}

    case result do
      {:ok, generated} ->
        made = Map.new(generated, fn {x, z, image} -> {{x, z}, {:terrain, image}} end)
        # A chunk a transaction applied meanwhile keeps its newer image.
        chunks = Map.merge(made, state.chunks)
        pending = MapSet.difference(terrain.pending, MapSet.new(Map.keys(made)))
        state = %{state | chunks: chunks, terrain: %{terrain | pending: pending}}
        {:noreply, state |> pump_terrain() |> answer_ready()}

      {:error, reason} ->
        Logger.error("Proto terrain of #{inspect(chunks)} failed: #{inspect(reason)}")

        state = %{
          state
          | terrain: %{terrain | pending: MapSet.difference(terrain.pending, MapSet.new(chunks))}
        }

        {:noreply, fail_requests(state, chunks, {:terrain_failed, reason})}
    end
  end

  defp info(:pump_terrain, state),
    do: {:noreply, pump_terrain(%{state | terrain: %{state.terrain | timer: nil}})}

  defp info({:txn_reply, label, reply}, state), do: {:noreply, txn_reply(state, label, reply)}

  defp info({:txn_timeout, id}, %{txn: %{id: id, phase: phase}} = state)
       when phase != :committing,
       do: {:noreply, abort(state, :generation_timeout)}

  defp info({:decorate, id}, %{txn: %{id: id, phase: :decorating}} = state),
    do: {:noreply, decorate(state)}

  defp info({:decorated, id, result}, %{txn: %{id: id, phase: :decorating} = txn} = state),
    do: {:noreply, maybe_commit(%{state | txn: %{txn | decorated: result}})}

  defp info({:full_done, ref, result}, %{full_job: ref} = state) do
    for from <- state.waiters, do: GenServer.reply(from, result)
    {:noreply, %{state | waiters: [], full_job: nil}}
  end

  defp info(:retry_finalize, state),
    do: {:noreply, maybe_finalize(%{state | retry: nil})}

  # An owner that answered busy released a lock: try again almost at once
  # (a little spread, so the woken neighbours do not collide in step).
  defp info({:proto_unlocked, _key}, %{txn: nil, retry: retry} = state) when retry != nil do
    Process.cancel_timer(retry)
    timer = Process.send_after(self(), :retry_finalize, :rand.uniform(4) - 1)
    {:noreply, %{state | retry: timer}}
  end

  defp info({:delivered, worker, token, result}, state),
    do: {:noreply, delivered(state, worker, token, result)}

  defp info({:redeliver, txn, key}, state), do: {:noreply, deliver(state, txn, key)}

  defp info({:resolved, worker, token, result}, state),
    do: {:noreply, resolved(state, worker, token, result)}

  defp info(:resolve, state) do
    Process.send_after(self(), :resolve, @resolve_every)
    # Durable locks of unwatched coordinators, and locks not yet durable (a
    # release may have been lost).
    state = resolve_locks(state, fn grant -> not grant.durable or grant.watch == nil end)

    {calls, rounds} = state.quiet
    rounds = if calls == state.calls and quiescent?(state), do: rounds + 1, else: 0

    if rounds >= @idle_rounds,
      do: {:stop, :normal, state},
      else: {:noreply, %{state | quiet: {state.calls, rounds}}}
  end

  defp info(:retire, state) do
    cond do
      not handed_over?(state) ->
        {:noreply, state}

      quiescent?(state) ->
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :retire, @retire_after)
        {:noreply, state}
    end
  end

  defp info({:DOWN, monitor, :process, _, reason}, state) do
    {:noreply, down(state, monitor, reason)}
  end

  defp info(_, state), do: {:noreply, state}

  # A linked writer ignores a normal exit; stop it, so a later owner of the
  # region is the log's only writer.
  @impl true
  def terminate(_reason, %{log: log}) when is_pid(log) do
    GenServer.stop(log, :normal, 10_000)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp quiescent?(state) do
    state.txn == nil and state.retry == nil and state.full_job == nil and state.waiters == [] and
      state.requests == [] and map_size(state.grants) == 0 and map_size(state.outbox) == 0 and
      map_size(state.writes) == 0 and map_size(state.terrain.jobs) == 0 and
      state.terrain.queue == []
  end

  # A watched coordinator died: a lock not yet durable goes (the transaction
  # cannot have committed), a durable one asks its next incarnation. A
  # delivery worker died without reporting: its attempt failed.
  defp down(state, monitor, _reason) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        cond do
          entry = Enum.find(state.deliveries, fn {_, job} -> job.monitor == monitor end) ->
            {{txn, key}, _} = entry
            Process.send_after(self(), {:redeliver, txn, key}, 500)
            %{state | deliveries: Map.delete(state.deliveries, {txn, key})}

          entry = Enum.find(state.resolving, fn {_, job} -> job.monitor == monitor end) ->
            %{state | resolving: Map.delete(state.resolving, elem(entry, 0))}

          true ->
            state
        end

      {txn, monitors} ->
        state = %{state | monitors: monitors}

        case state.grants do
          %{^txn => %{durable: false} = grant} ->
            release_lock(put_in(state.grants[txn], %{grant | watch: nil}), txn, true)

          %{^txn => grant} ->
            put_in(state.grants[txn], %{grant | watch: nil})
            |> resolve_locks(&(&1.txn == txn))

          _ ->
            state
        end
    end
  end

  ## Durable writes

  # Append `ops`; `continue.(state, :ok)` runs once they are durable. Writes
  # in flight are bounded by the requests, transactions and deliveries that
  # cause them.
  defp write(state, ops, continue) do
    token = make_ref()
    ProtoLog.append(state.log, ops, token)
    %{state | writes: Map.put(state.writes, token, continue)}
  end

  ## Terrain

  # Queue the terrain of `chunks` this owner lacks, earliest `since` first (a
  # chunk asked for again keeps the earliest); the queue holds `{since, {z,
  # x}}`, so equal priorities go Z outer, X inner.
  defp ensure_terrain(state, chunks, since) do
    missing = Enum.reject(chunks, &Map.has_key?(state.chunks, &1))

    if missing == [] do
      state
    else
      %{queue: queue, pending: pending} = terrain = state.terrain
      queued = Map.new(queue, fn {s, {z, x}} -> {{x, z}, s} end)

      queued =
        Enum.reduce(missing, queued, fn chunk, acc ->
          cond do
            Map.has_key?(acc, chunk) -> Map.update!(acc, chunk, &min(&1, since))
            # In flight.
            MapSet.member?(pending, chunk) -> acc
            true -> Map.put(acc, chunk, since)
          end
        end)

      queue = queued |> Enum.map(fn {{x, z}, s} -> {s, {z, x}} end) |> Enum.sort()
      pending = MapSet.union(pending, MapSet.new(missing))
      pump_terrain(%{state | terrain: %{terrain | queue: queue, pending: pending}})
    end
  end

  defp pump_terrain(%{terrain: %{queue: []}} = state), do: state

  defp pump_terrain(%{terrain: terrain} = state) do
    {batch, rest} = Enum.split(terrain.queue, @terrain_batch)
    batch = Enum.map(batch, fn {_, {z, x}} -> {x, z} end)
    owner = self()
    worldgen = state.worldgen
    source = state.biome_source
    ref = make_ref()

    case Task.Supervisor.start_child(Valimc.WorldgenWorkers, fn ->
           result =
             try do
               Native.worldgen_proto_terrain(worldgen, source, batch)
             rescue
               error -> {:error, Exception.message(error)}
             end

           send(owner, {:terrain_done, ref, result})
         end) do
      {:ok, _} ->
        pump_terrain(%{
          state
          | terrain: %{terrain | queue: rest, jobs: Map.put(terrain.jobs, ref, batch)}
        })

      {:error, _} ->
        # Every worker is busy: try again shortly.
        timer = terrain.timer || Process.send_after(self(), :pump_terrain, 5)
        %{state | terrain: %{terrain | timer: timer}}
    end
  end

  defp fail_requests(state, chunks, reason) do
    {failed, kept} =
      Enum.split_with(state.requests, fn r -> Enum.any?(r.chunks, &(&1 in chunks)) end)

    Enum.reduce(failed, %{state | requests: kept}, fn r, acc ->
      answer(acc, r, {:error, reason})
    end)
  end

  ## Participant: terrain and locks

  # A transaction waits for the terrain of its chunks here (bounded); it
  # holds no lock meanwhile.
  defp wait_terrain(state, entry) do
    if length(state.requests) >= @max_requests do
      answer(state, entry, {:error, :generation_busy})
    else
      state = %{state | requests: state.requests ++ [entry]}

      state
      |> ensure_terrain(Enum.reject(entry.chunks, &MapSet.member?(state.final, &1)), entry.since)
      |> answer_ready()
    end
  end

  defp answer_ready(state) do
    {ready, waiting} =
      Enum.split_with(state.requests, fn r ->
        Enum.all?(r.chunks, &(MapSet.member?(state.final, &1) or Map.has_key?(state.chunks, &1)))
      end)

    Enum.reduce(ready, %{state | requests: waiting}, &answer(&2, &1, {:ok, :ready}))
  end

  # Lock the non-final chunks of a request now, or answer busy (remembering
  # its coordinator, to wake it when a lock here is released). A lock for a
  # foreign coordinator is not durable until it is prepared.
  defp try_lock(state, %{txn: txn, coordinator: coordinator, chunks: chunks} = request) do
    needed = Enum.reject(chunks, &MapSet.member?(state.final, &1))

    cond do
      Map.has_key?(state.grants, txn) ->
        {{:ok, grant_reply(state, state.grants[txn].chunks, chunks)}, state}

      needed == [] ->
        {{:ok, grant_reply(state, [], chunks)}, state}

      not Enum.all?(needed, &Map.has_key?(state.chunks, &1)) ->
        {{:error, :generation_not_ready}, ensure_terrain(state, needed, request.since)}

      Enum.any?(needed, &Map.has_key?(state.locks, &1)) ->
        {{:error, :generation_busy}, %{state | wake: MapSet.put(state.wake, request.pid)}}

      true ->
        state = hold(state, txn, coordinator, needed, false)
        state = if coordinator == state.key, do: state, else: watch(state, txn, request.pid)
        {{:ok, grant_reply(state, needed, chunks)}, state}
    end
  end

  defp grant_reply(state, locked, asked) do
    %{
      chunks: Map.take(state.chunks, locked),
      final: Enum.filter(asked, &MapSet.member?(state.final, &1))
    }
  end

  defp hold(state, txn, coordinator, chunks, durable) do
    {:ok, permits, ^txn} =
      Permits.issue(
        state.permits,
        :generation,
        txn,
        coordinator,
        chunks,
        %{chunks: chunks},
        now()
      )

    grant = %{txn: txn, coordinator: coordinator, chunks: chunks, durable: durable, watch: nil}

    %{
      state
      | permits: permits,
        grants: Map.put(state.grants, txn, grant),
        locks: Enum.reduce(chunks, state.locks, &Map.put(&2, &1, txn))
    }
  end

  defp watch(state, txn, pid) do
    monitor = Process.monitor(pid)
    state = %{state | monitors: Map.put(state.monitors, monitor, txn)}
    update_in(state.grants[txn], &%{&1 | watch: monitor})
  end

  defp answer(state, %{reply: {:call, from}}, reply) do
    GenServer.reply(from, reply)
    state
  end

  defp answer(state, %{reply: {:self, label}}, reply) do
    send(self(), {:txn_reply, label, reply})
    state
  end

  # `wake?`: tell the coordinators this owner answered busy that a lock went.
  defp unhold(state, txn, wake? \\ true) do
    case Map.pop(state.grants, txn) do
      {nil, _} ->
        state

      {grant, grants} ->
        if grant.watch, do: Process.demonitor(grant.watch, [:flush])
        if wake?, do: for(pid <- state.wake, do: send(pid, {:proto_unlocked, state.key}))

        %{
          state
          | grants: grants,
            monitors:
              if(grant.watch, do: Map.delete(state.monitors, grant.watch), else: state.monitors),
            permits: Permits.release(state.permits, txn),
            locks: Map.drop(state.locks, grant.chunks),
            wake: if(wake?, do: MapSet.new(), else: state.wake)
        }
    end
  end

  defp release_lock(state, txn, wake? \\ true) do
    {dropped, kept} = Enum.split_with(state.requests, &(&1.txn == txn))

    state =
      Enum.reduce(
        dropped,
        %{state | requests: kept},
        &answer(&2, &1, {:error, :generation_released})
      )

    case state.grants do
      %{^txn => %{durable: true}} ->
        write(unhold(state, txn, wake?), [{:unlock, txn}], fn s, :ok -> s end)

      %{^txn => _} ->
        unhold(state, txn, wake?)

      _ ->
        state
    end
  end

  defp apply_part_locally(
         state,
         %{txn: txn, coordinator: coordinator, sequence: sequence, digest: digest, part: part},
         reply
       ) do
    case Receipts.classify(state.receipts, coordinator, sequence, digest, :plain) do
      {:duplicate, outcome} ->
        {:reply, {:ok, outcome}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :new ->
        case state.grants do
          %{^txn => %{chunks: chunks}} ->
            if Enum.all?(Map.keys(part), &(&1 in chunks)) do
              receipts =
                Receipts.record(state.receipts, coordinator, sequence, digest, :plain, :applied)

              ops = [
                {:chunks, part},
                {:unlock, txn},
                {:receipt, coordinator, receipts[coordinator]}
              ]

              state = %{state | receipts: receipts, chunks: Map.merge(state.chunks, part)}

              state =
                write(state, ops, fn state, :ok ->
                  state = unhold(state, txn)

                  case reply do
                    {:call, from} -> GenServer.reply(from, {:ok, :applied})
                    :none -> :ok
                  end

                  state
                end)

              {:noreply, state}
            else
              {:reply, {:error, :invalid_generation_part}, state}
            end

          _ ->
            {:reply, {:error, :generation_not_locked}, state}
        end
    end
  end

  # Ask the coordinators of matching foreign locks what became of them.
  defp resolve_locks(state, match?) do
    for {txn, grant} <- state.grants,
        grant.coordinator != state.key,
        match?.(grant),
        not Map.has_key?(state.resolving, txn),
        reduce: state do
      acc ->
        asker = acc.key

        case Delivery.start(
               self(),
               fn worker, token, result -> {:resolved, worker, token, {txn, result}} end,
               fn -> __MODULE__.status(grant.coordinator, txn, asker) end,
               link: true
             ) do
          {:ok, job} -> %{acc | resolving: Map.put(acc.resolving, txn, job)}
          {:error, _} -> acc
        end
    end
  end

  defp resolved(state, worker, token, {txn, result}) do
    case state.resolving do
      %{^txn => job} ->
        if Delivery.current?(job, worker, token) do
          Delivery.finish(job)
          state = %{state | resolving: Map.delete(state.resolving, txn)}

          case {result, state.grants[txn]} do
            {_, nil} ->
              state

            {{:running, pid}, grant} ->
              permits =
                case Permits.renew(state.permits, :generation, txn, now()) do
                  {:ok, permits, _} ->
                    permits

                  # An hour without an answer: the lock's grant stays, its permit is issued again.
                  :error ->
                    {:ok, permits, _} =
                      Permits.issue(
                        state.permits,
                        :generation,
                        txn,
                        grant.coordinator,
                        grant.chunks,
                        %{chunks: grant.chunks},
                        now()
                      )

                    permits
                end

              state = %{state | permits: permits}
              if grant.watch, do: state, else: watch(state, txn, pid)

            {{:committed, %{} = delivery}, _} ->
              request =
                Map.merge(delivery, %{txn: txn, coordinator: state.grants[txn].coordinator})

              case apply_part_locally(state, request, :none) do
                {:noreply, state} -> state
                {:reply, _, state} -> state
              end

            {:unknown, _} ->
              release_lock(state, txn)

            _ ->
              # The coordinator could not answer; the periodic pass asks again.
              state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  ## Coordinator: the finalize transaction

  defp maybe_finalize(%{txn: nil, retry: nil} = state) do
    if Enum.all?(chunks_of(state.key), &MapSet.member?(state.final, &1)),
      do: start_full(state),
      else: start_finalize(state)
  end

  defp maybe_finalize(state), do: state

  defp start_finalize(state) do
    n = state.txn_count + 1
    id = {state.key, state.incarnation, n}
    since = state.since || System.monotonic_time(:microsecond)
    participants = state.key |> around(2) |> Enum.group_by(&region_of/1) |> Enum.sort()

    txn = %{
      id: id,
      sequence: state.incarnation * 4_294_967_296 + n,
      phase: :terrain,
      participants: participants,
      waiting: MapSet.new(participants, &elem(&1, 0)),
      granted: %{},
      busy: false,
      error: nil,
      prepare: MapSet.new(),
      decorated: nil,
      timer: Process.send_after(self(), {:txn_timeout, id}, @lock_timeout)
    }

    state = %{state | txn_count: n, txn: txn, since: since}

    Enum.reduce(participants, state, fn {key, chunks}, acc ->
      ask(acc, key, {:terrain, %{txn: id, chunks: chunks, since: since}})
    end)
  end

  # Send a request of the current transaction to `key`'s owner; this owner
  # answers its own at once. Answers arrive as `txn_reply/3`.
  defp ask(state, key, message) do
    label = {state.txn.id, key, elem(message, 0)}

    if key == state.key do
      case message do
        {:terrain, request} ->
          wait_terrain(state, Map.put(request, :reply, {:self, label}))

        {:lock, request} ->
          {reply, state} = try_lock(state, request)
          send(self(), {:txn_reply, label, reply})
          state
      end
    else
      case owner(key) do
        {:ok, pid} ->
          %{state | out: :gen_server.send_request(pid, message, label, state.out)}

        {:error, reason} ->
          send(self(), {:txn_reply, label, {:error, reason}})
          state
      end
    end
  end

  defp txn_reply(%{txn: %{id: id}} = state, {id, key, kind}, reply),
    do: step(state, kind, key, reply)

  # A lock granted to an attempt given up meanwhile goes back.
  defp txn_reply(state, {id, key, :lock}, {:ok, %{chunks: chunks}}) when map_size(chunks) > 0,
    do: release_at(state, key, id, false)

  defp txn_reply(state, _label, _reply), do: state

  defp step(%{txn: %{phase: :terrain} = txn} = state, :terrain, key, reply) do
    case reply do
      {:ok, :ready} ->
        txn = %{txn | waiting: MapSet.delete(txn.waiting, key)}
        state = %{state | txn: txn}
        if MapSet.size(txn.waiting) == 0, do: lock_all(state), else: state

      {:error, :generation_busy} ->
        back_off(state)

      error ->
        abort(state, error)
    end
  end

  defp step(%{txn: %{phase: :locking} = txn} = state, :lock, key, reply) do
    txn =
      case reply do
        {:ok, %{chunks: chunks}} -> %{txn | granted: Map.put(txn.granted, key, chunks)}
        {:error, :generation_busy} -> %{txn | busy: true}
        {:error, :generation_not_ready} -> %{txn | busy: true}
        error -> %{txn | error: txn.error || error}
      end

    txn = %{txn | waiting: MapSet.delete(txn.waiting, key)}
    state = %{state | txn: txn}

    cond do
      MapSet.size(txn.waiting) > 0 -> state
      txn.error != nil -> abort(state, txn.error)
      txn.busy -> back_off(state)
      true -> prepare_all(state)
    end
  end

  defp step(%{txn: %{phase: :decorating} = txn} = state, :prepare, key, reply) do
    case reply do
      {:ok, :prepared} ->
        maybe_commit(%{state | txn: %{txn | prepare: MapSet.delete(txn.prepare, key)}})

      error ->
        abort(state, error)
    end
  end

  defp step(state, _kind, _key, _reply), do: state

  # Ask every owner for its locks at once; the answers decide together.
  defp lock_all(state) do
    %{id: id, participants: participants} = state.txn
    txn = %{state.txn | phase: :locking, waiting: MapSet.new(participants, &elem(&1, 0))}

    Enum.reduce(participants, %{state | txn: txn}, fn {key, chunks}, acc ->
      request = %{
        txn: id,
        coordinator: state.key,
        pid: self(),
        chunks: chunks,
        since: state.since
      }

      ask(acc, key, {:lock, request})
    end)
  end

  # Everything is locked: foreign locks become durable while the area is
  # decorated.
  defp prepare_all(state) do
    txn = state.txn

    keys =
      for {key, chunks} <- txn.granted,
          key != state.key,
          locked_any?(chunks),
          into: MapSet.new(),
          do: key

    state = %{state | txn: %{txn | phase: :decorating, prepare: keys}}
    state = Enum.reduce(keys, state, &ask(&2, &1, {:prepare, txn.id}))
    decorate(state)
  end

  # Some owner was busy: give every lock back and try again after a random
  # delay that grows with consecutive busy attempts (or sooner, when woken).
  # Busy attempts do not count as failures.
  defp back_off(state) do
    txn = state.txn
    Process.cancel_timer(txn.timer)
    state = release_all(%{state | txn: nil}, txn, false)
    busy = state.busy + 1
    delay = :rand.uniform(min(256, 4 * Bitwise.bsl(1, min(busy, 6))))
    %{state | busy: busy, retry: Process.send_after(self(), :retry_finalize, delay)}
  end

  defp release_all(state, txn, wake?) do
    Enum.reduce(txn.participants, state, fn {key, _}, acc ->
      release_at(acc, key, txn.id, wake?)
    end)
  end

  defp release_at(state, key, txn, wake?) do
    if key == state.key do
      release_lock(state, txn, wake?)
    else
      case Registry.lookup(Valimc.ProtoRegistry, Valimc.Dimension.scope(key)) do
        [{pid, _}] -> GenServer.cast(pid, {:release, txn, wake?})
        [] -> :ok
      end

      state
    end
  end

  # While the worker pool is full, the decoration waits (holding its locks)
  # instead of aborting the transaction.
  defp decorate(state) do
    images =
      Enum.reduce(state.txn.granted, %{}, fn {_, chunks}, acc -> Map.merge(acc, chunks) end)

    order =
      for chunk <- around(state.key, 1),
          match?({:terrain, _}, images[chunk]),
          do: chunk

    owner = self()
    id = state.txn.id
    worldgen = state.worldgen
    source = state.biome_source
    list = Enum.map(images, fn {_, {_, image}} -> image end)

    case Task.Supervisor.start_child(Valimc.DecorationWorkers, fn ->
           result =
             try do
               if order == [],
                 do: {:ok, {[], 0}},
                 else: Native.worldgen_proto_decorate(worldgen, source, list, order)
             rescue
               error -> {:error, Exception.message(error)}
             end

           send(owner, {:decorated, id, {images, order, result}})
         end) do
      {:ok, _} ->
        state

      {:error, _} ->
        Process.send_after(self(), {:decorate, id}, 5)
        state
    end
  end

  defp maybe_commit(%{txn: %{decorated: decorated, prepare: prepare}} = state)
       when decorated != nil do
    if MapSet.size(prepare) == 0, do: commit(state, decorated), else: state
  end

  defp maybe_commit(state), do: state

  defp commit(state, {images, order, {:ok, {touched, lenient}}}) do
    if lenient > 0,
      do:
        Logger.warning(
          "Decorating around region #{inspect(state.key)} read #{lenient} blocks of chunks it did not hold"
        )

    touched = Map.new(touched, fn {x, z, image} -> {{x, z}, image} end)
    decorated = MapSet.new(order)

    changed =
      for {chunk, {status, image}} <- images,
          new_status = if(MapSet.member?(decorated, chunk), do: :decorated, else: status),
          new_image = Map.get(touched, chunk, image),
          new_status != status or new_image != image,
          into: %{},
          do: {chunk, {new_status, new_image}}

    own = chunks_of(state.key)
    {mine, foreign} = Enum.split_with(changed, fn {chunk, _} -> region_of(chunk) == state.key end)

    parts =
      for {key, _} <- state.txn.granted, key != state.key, into: %{} do
        part =
          for {chunk, value} <- foreign, region_of(chunk) == key, into: %{}, do: {chunk, value}

        {key,
         %{
           sequence: state.txn.sequence,
           digest: :crypto.hash(:sha256, :erlang.term_to_binary(part)),
           part: part
         }}
      end

    # Participants that locked nothing (all their chunks were final) need no part.
    parts = Map.filter(parts, fn {key, _} -> locked_any?(state.txn.granted[key]) end)
    mine = Map.new(mine)
    id = state.txn.id

    ops =
      [{:chunks, mine}, {:final, own}] ++ if(parts == %{}, do: [], else: [{:outbox, id, parts}])

    Process.cancel_timer(state.txn.timer)

    state = %{
      state
      | chunks: Map.merge(state.chunks, mine),
        txn: %{state.txn | phase: :committing}
    }

    write(state, ops, fn state, :ok ->
      state = %{
        state
        | final: MapSet.union(state.final, MapSet.new(own)),
          outbox: if(parts == %{}, do: state.outbox, else: Map.put(state.outbox, id, parts)),
          txn: nil,
          attempts: 0,
          busy: 0,
          since: nil
      }

      state = unhold(state, id)
      state = deliver_all(state, id)
      start_full(state)
    end)
  end

  defp commit(state, {_images, _order, error}) do
    Logger.error("Decorating around region #{inspect(state.key)} failed: #{inspect(error)}")
    abort(state, error)
  end

  defp locked_any?(chunks), do: map_size(chunks) > 0

  defp abort(state, reason) do
    txn = state.txn
    Process.cancel_timer(txn.timer)
    # Locks of a transaction that got as far as decorating were real holds.
    state = release_all(%{state | txn: nil}, txn, txn.phase == :decorating)
    attempts = state.attempts + 1

    if attempts >= @max_attempts do
      Logger.error("Finalizing region #{inspect(state.key)} failed: #{inspect(reason)}")
      for from <- state.waiters, do: GenServer.reply(from, {:error, reason})
      %{state | waiters: [], attempts: 0}
    else
      delay = min(5000, 20 * attempts) + :rand.uniform(50)
      %{state | attempts: attempts, retry: Process.send_after(self(), :retry_finalize, delay)}
    end
  end

  ## Coordinator: delivery

  defp deliver_all(state, txn),
    do: Enum.reduce(Map.keys(state.outbox[txn] || %{}), state, &deliver(&2, txn, &1))

  defp deliver(state, txn, key) do
    case state.outbox do
      %{^txn => %{^key => delivery}} ->
        request = Map.merge(delivery, %{txn: txn, coordinator: state.key})

        case Delivery.start(
               self(),
               fn worker, token, result -> {:delivered, worker, token, {txn, key, result}} end,
               fn -> __MODULE__.apply_part(key, request) end,
               link: true
             ) do
          {:ok, job} ->
            %{state | deliveries: Map.put(state.deliveries, {txn, key}, job)}

          {:error, _} ->
            Process.send_after(self(), {:redeliver, txn, key}, 100)
            state
        end

      _ ->
        state
    end
  end

  defp delivered(state, worker, token, {txn, key, result}) do
    case state.deliveries do
      %{{^txn, ^key} => job} ->
        if Delivery.current?(job, worker, token) do
          Delivery.finish(job)
          state = %{state | deliveries: Map.delete(state.deliveries, {txn, key})}

          case result do
            {:ok, outcome} when outcome in [:applied, :already_applied] ->
              parts = Map.delete(state.outbox[txn], key)

              outbox =
                if map_size(parts) == 0,
                  do: Map.delete(state.outbox, txn),
                  else: Map.put(state.outbox, txn, parts)

              write(%{state | outbox: outbox}, [{:delivered, txn, key}], fn s, :ok -> s end)

            error ->
              Logger.warning(
                "Delivering generation part #{inspect(txn)} to #{inspect(key)}: #{inspect(error)}"
              )

              Process.send_after(self(), {:redeliver, txn, key}, 500)
              state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  ## Full chunks

  defp start_full(%{waiters: []} = state), do: state
  defp start_full(%{full_job: ref} = state) when ref != nil, do: state

  defp start_full(state) do
    own = chunks_of(state.key)
    images = Enum.map(own, fn chunk -> elem(Map.fetch!(state.chunks, chunk), 1) end)
    owner = self()
    worldgen = state.worldgen
    ref = make_ref()

    case Task.Supervisor.start_child(Valimc.DecorationWorkers, fn ->
           result =
             try do
               Native.worldgen_proto_full(worldgen, images, Generator.protocol_biomes())
             rescue
               error -> {:error, Exception.message(error)}
             end

           send(owner, {:full_done, ref, result})
         end) do
      {:ok, _} ->
        %{state | full_job: ref}

      {:error, _} ->
        %{state | retry: state.retry || Process.send_after(self(), :retry_finalize, 20)}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
