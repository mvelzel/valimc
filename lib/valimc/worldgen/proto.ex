defmodule Valimc.Worldgen.Proto do
  @moduledoc """
  One region's proto chunks in a decorated vanilla world (VMC-025d2): the
  owner of its chunks before they are final, of their statuses (`:terrain`,
  `:decorated`) and of the finalize transaction that makes the region final.
  Its durable state is a `Valimc.Worldgen.ProtoLog`; terrain, decoration and
  full chunks run on `Valimc.WorldgenWorkers` (dirty NIFs), never in here.

  A chunk is final once every chunk of its 3 × 3 is decorated. A decoration
  reads and writes only its 3 × 3 (VMC-025 measured it), so a final chunk is
  never touched again, and every undecorated chunk's 3 × 3 is non-final.

  Finalizing region `R` (coordinated by `R`'s owner, presumed abort with
  durable prepare):

  1. Lock: in region key order (no deadlock), each of the nine owners around
     `R` generates the terrain it lacks among its chunks of the 12 × 12 around
     `R`, reports which are final and locks the others for the transaction
     (`Txn.Permits` kind `:generation`); a foreign lock is durable before the
     grant is answered, a conflicting request waits (bounded).
  2. Decorate every undecorated chunk of the 10 × 10 around `R`, Z outer and X
     inner, in one native call over the locked images.
  3. Commit one frame: `R`'s changed chunks, its 64 chunks final, and an
     outbox entry per foreign participant (`Txn.Receipts` sequence from the
     log incarnation and transaction count, digest of the part).
  4. Deliver each part (`Txn.Delivery`); the participant applies it, unlocks
     and records the receipt in one frame, idempotently.

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
    waiters: [],
    calls: 0,
    quiet: {0, 0}
  ]

  # A grant may wait for terrain and for conflicting transactions.
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
  def lock(key, request), do: call(key, {:lock, request}, @lock_timeout)
  @doc false
  def apply_part(key, request), do: call(key, {:apply, request}, @call_timeout)
  @doc false
  def release(key, txn), do: call(key, {:release, txn}, @call_timeout)
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
    {:ok, %__MODULE__{key: key}, {:continue, :load}}
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

  # Participant: lock chunks for a foreign (or this owner's) transaction.
  def handle_call(
        {:lock, %{txn: txn, coordinator: coordinator, chunks: chunks} = request},
        from,
        state
      ) do
    state = %{state | calls: state.calls + 1}

    cond do
      not Enum.all?(chunks, &(region_of(&1) == state.key)) ->
        {:reply, {:error, :invalid_generation_lock}, state}

      Map.has_key?(state.grants, txn) ->
        {:reply, {:ok, grant_reply(state, state.grants[txn].chunks, chunks)}, state}

      length(state.requests) >= @max_requests ->
        {:reply, {:error, :generation_busy}, state}

      true ->
        entry = %{
          txn: txn,
          coordinator: coordinator,
          pid: request[:pid],
          chunks: chunks,
          reply: {:call, from},
          durable: coordinator != state.key
        }

        state = %{state | requests: state.requests ++ [entry]}
        state = ensure_terrain(state, Enum.reject(chunks, &MapSet.member?(state.final, &1)))
        {:noreply, grant_waiting(state)}
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

  # Participant: the coordinator aborted (or gave up waiting).
  def handle_call({:release, txn}, _from, state), do: {:reply, :ok, release_lock(state, txn)}

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

  @impl true
  def handle_info({:proto_saved, token, result}, state) do
    {continuation, writes} = Map.pop(state.writes, token)
    state = %{state | writes: writes}

    case result do
      :ok -> {:noreply, continuation.(state, :ok)}
      {:error, reason} -> {:stop, {:proto_write_failed, reason}, state}
    end
  end

  def handle_info({:terrain_done, ref, result}, state) do
    {chunks, jobs} = Map.pop(state.terrain.jobs, ref)
    terrain = %{state.terrain | jobs: jobs}

    case result do
      {:ok, generated} ->
        made = Map.new(generated, fn {x, z, image} -> {{x, z}, {:terrain, image}} end)
        # A chunk a transaction applied meanwhile keeps its newer image.
        chunks = Map.merge(made, state.chunks)
        pending = MapSet.difference(terrain.pending, MapSet.new(Map.keys(made)))
        state = %{state | chunks: chunks, terrain: %{terrain | pending: pending}}
        {:noreply, state |> pump_terrain() |> grant_waiting()}

      {:error, reason} ->
        Logger.error("Proto terrain of #{inspect(chunks)} failed: #{inspect(reason)}")

        state = %{
          state
          | terrain: %{terrain | pending: MapSet.difference(terrain.pending, MapSet.new(chunks))}
        }

        {:noreply, fail_requests(state, chunks, {:terrain_failed, reason})}
    end
  end

  def handle_info(:pump_terrain, state),
    do: {:noreply, pump_terrain(%{state | terrain: %{state.terrain | timer: nil}})}

  def handle_info({:txn_step, id, result}, %{txn: %{id: id}} = state),
    do: {:noreply, txn_step(state, result)}

  def handle_info({:txn_step, _, _}, state), do: {:noreply, state}

  def handle_info({:decorated, id, result}, %{txn: %{id: id, phase: :decorating}} = state),
    do: {:noreply, commit(state, result)}

  def handle_info({:decorated, _, _}, state), do: {:noreply, state}

  def handle_info({:full_done, ref, result}, %{full_job: ref} = state) do
    for from <- state.waiters, do: GenServer.reply(from, result)
    {:noreply, %{state | waiters: [], full_job: nil}}
  end

  def handle_info({:full_done, _, _}, state), do: {:noreply, state}

  def handle_info(:retry_finalize, state),
    do: {:noreply, maybe_finalize(%{state | retry: nil})}

  def handle_info({:delivered, worker, token, result}, state),
    do: {:noreply, delivered(state, worker, token, result)}

  def handle_info({:redeliver, txn, key}, state), do: {:noreply, deliver(state, txn, key)}

  def handle_info({:resolved, worker, token, result}, state),
    do: {:noreply, resolved(state, worker, token, result)}

  def handle_info(:resolve, state) do
    Process.send_after(self(), :resolve, @resolve_every)
    state = resolve_locks(state, fn grant -> grant.durable and grant.watch == nil end)
    {calls, rounds} = state.quiet
    rounds = if calls == state.calls and quiescent?(state), do: rounds + 1, else: 0

    if rounds >= @idle_rounds,
      do: {:stop, :normal, state},
      else: {:noreply, %{state | quiet: {state.calls, rounds}}}
  end

  def handle_info(:retire, state) do
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

  def handle_info({:DOWN, monitor, :process, _, reason}, state) do
    {:noreply, down(state, monitor, reason)}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

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

  # A watched coordinator died: ask its next incarnation. A delivery worker
  # died without reporting: its attempt failed.
  defp down(state, monitor, reason) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        cond do
          state.txn != nil and state.txn.job != nil and state.txn.job.monitor == monitor ->
            abort(%{state | txn: %{state.txn | job: nil}}, {:lock_worker_down, reason})

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

        state =
          case state.grants do
            %{^txn => grant} -> put_in(state.grants[txn], %{grant | watch: nil})
            _ -> state
          end

        resolve_locks(state, &(&1.txn == txn))
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

  defp ensure_terrain(state, chunks) do
    missing =
      Enum.reject(chunks, fn c ->
        Map.has_key?(state.chunks, c) or MapSet.member?(state.terrain.pending, c)
      end)

    if missing == [] do
      state
    else
      terrain = %{
        state.terrain
        | queue: state.terrain.queue ++ missing,
          pending: MapSet.union(state.terrain.pending, MapSet.new(missing))
      }

      pump_terrain(%{state | terrain: terrain})
    end
  end

  defp pump_terrain(%{terrain: %{queue: []}} = state), do: state

  defp pump_terrain(%{terrain: terrain} = state) do
    {batch, rest} = Enum.split(terrain.queue, @terrain_batch)
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

  ## Participant: locks

  # Grant waiting requests in arrival order once their terrain exists and none
  # of their chunks is locked.
  defp grant_waiting(state) do
    {granted, waiting} =
      Enum.reduce(state.requests, {[], []}, fn r, {granted, waiting} ->
        needed = Enum.reject(r.chunks, &MapSet.member?(state.final, &1))
        ready = Enum.all?(needed, &Map.has_key?(state.chunks, &1))
        free = Enum.all?(needed, &(not Map.has_key?(state.locks, &1)))
        # Earlier grants in this pass also lock their chunks.
        free = free and not Enum.any?(granted, fn g -> Enum.any?(needed, &(&1 in g.needed)) end)

        if ready and free,
          do: {[Map.put(r, :needed, needed) | granted], waiting},
          else: {granted, [r | waiting]}
      end)

    state = %{state | requests: Enum.reverse(waiting)}
    Enum.reduce(Enum.reverse(granted), state, &grant(&2, &1))
  end

  # Nothing to lock (every chunk asked for is final): no lock to hold.
  defp grant(state, %{needed: []} = r),
    do: answer(state, r, {:ok, grant_reply(state, [], r.chunks)})

  defp grant(state, %{needed: needed} = r) do
    state = hold(state, r.txn, r.coordinator, needed, r.durable)
    state = watch(state, r.txn, r.pid)

    if r.durable do
      write(state, [{:lock, r.txn, %{coordinator: r.coordinator, chunks: needed}}], fn state,
                                                                                       :ok ->
        if Map.has_key?(state.grants, r.txn),
          do: answer(state, r, {:ok, grant_reply(state, needed, r.chunks)}),
          else: answer(state, r, {:error, :generation_lock_released})
      end)
    else
      answer(state, r, {:ok, grant_reply(state, needed, r.chunks)})
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

  defp watch(state, _txn, nil), do: state

  defp watch(state, txn, pid) do
    monitor = Process.monitor(pid)
    state = %{state | monitors: Map.put(state.monitors, monitor, txn)}
    update_in(state.grants[txn], &%{&1 | watch: monitor})
  end

  defp answer(state, %{reply: {:call, from}}, reply) do
    GenServer.reply(from, reply)
    state
  end

  defp answer(state, %{reply: :self, txn: txn}, reply) do
    send(self(), {:txn_step, txn, {:granted, state.key, reply}})
    state
  end

  defp unhold(state, txn) do
    case Map.pop(state.grants, txn) do
      {nil, _} ->
        state

      {grant, grants} ->
        if grant.watch, do: Process.demonitor(grant.watch, [:flush])

        %{
          state
          | grants: grants,
            monitors:
              if(grant.watch, do: Map.delete(state.monitors, grant.watch), else: state.monitors),
            permits: Permits.release(state.permits, txn),
            locks: Map.drop(state.locks, grant.chunks)
        }
        |> grant_waiting()
    end
  end

  defp release_lock(state, txn) do
    {dropped, kept} = Enum.split_with(state.requests, &(&1.txn == txn))

    state =
      Enum.reduce(
        dropped,
        %{state | requests: kept},
        &answer(&2, &1, {:error, :generation_released})
      )

    case state.grants do
      %{^txn => %{durable: true}} ->
        write(unhold(state, txn), [{:unlock, txn}], fn s, :ok -> s end)

      %{^txn => _} ->
        unhold(state, txn)

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

  # Ask the coordinators of matching durable locks what became of them.
  defp resolve_locks(state, match?) do
    for {txn, grant} <- state.grants,
        grant.durable,
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

              watch(%{state | permits: permits}, txn, pid)

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
    needed = MapSet.new(around(state.key, 2))

    participants =
      needed
      |> Enum.group_by(&region_of/1)
      |> Enum.sort()

    txn = %{
      id: id,
      sequence: state.incarnation * 4_294_967_296 + n,
      phase: :locking,
      remaining: participants,
      contacted: [],
      granted: %{},
      job: nil
    }

    state |> Map.put(:txn_count, n) |> Map.put(:txn, txn) |> acquire_next()
  end

  defp acquire_next(state) do
    case state.txn.remaining do
      [] -> decorate(state)
      [{key, chunks} | rest] -> acquire(state, key, chunks, rest)
    end
  end

  defp acquire(state, key, chunks, rest) do
    txn = %{state.txn | remaining: rest, contacted: [key | state.txn.contacted]}
    state = %{state | txn: txn}

    if key == state.key do
      entry = %{
        txn: txn.id,
        coordinator: state.key,
        pid: nil,
        chunks: chunks,
        reply: :self,
        durable: false
      }

      state = %{state | requests: state.requests ++ [entry]}
      state = ensure_terrain(state, Enum.reject(chunks, &MapSet.member?(state.final, &1)))
      grant_waiting(state)
    else
      request = %{txn: txn.id, coordinator: state.key, pid: self(), chunks: chunks}
      id = txn.id

      case Delivery.start(
             self(),
             fn _worker, _token, result -> {:txn_step, id, {:granted, key, result}} end,
             fn -> __MODULE__.lock(key, request) end,
             link: true
           ) do
        {:ok, job} -> %{state | txn: %{state.txn | job: job}}
        {:error, reason} -> abort(state, reason)
      end
    end
  end

  defp txn_step(state, {:granted, key, {:ok, %{chunks: chunks}}}) do
    if job = state.txn.job, do: Delivery.finish(job)
    granted = Map.put(state.txn.granted, key, chunks)
    acquire_next(%{state | txn: %{state.txn | granted: granted, job: nil}})
  end

  defp txn_step(state, {:granted, _key, error}) do
    if job = state.txn.job, do: Delivery.finish(job)
    abort(%{state | txn: %{state.txn | job: nil}}, error)
  end

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

    case Task.Supervisor.start_child(Valimc.WorldgenWorkers, fn ->
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
      {:ok, _} -> %{state | txn: %{state.txn | phase: :decorating}}
      {:error, _} -> abort(state, :worldgen_workers_busy)
    end
  end

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
          attempts: 0
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
    if txn.job, do: Delivery.abort(txn.job)

    for key <- txn.contacted, key != state.key do
      spawn_release(key, txn.id)
    end

    state = release_lock(%{state | txn: nil}, txn.id)
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

  # Releases are best effort: a participant that misses one asks for the
  # transaction's status and learns it was aborted.
  defp spawn_release(key, txn) do
    Task.Supervisor.start_child(
      Valimc.TransferWorkers,
      Valimc.Dimension.bind(fn -> release(key, txn) end)
    )
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

    case Task.Supervisor.start_child(Valimc.WorldgenWorkers, fn ->
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
