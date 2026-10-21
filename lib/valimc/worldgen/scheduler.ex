defmodule Valimc.Worldgen.Scheduler do
  @moduledoc """
  The generation scheduler of one dimension of one world (VMC-077n): it owns
  every chunk's generation status, its proto chunk as a native cell and the
  dimension's structure starts (`Valimc.Worldgen.Frontier`), runs the work on
  `Valimc.Worldgen.Pool` and sends full chunks to the regions that want them.

  A region sends what it wants (`want/5`, its absent chunks with their
  distance to the nearest player that wants them, replaced on every change)
  and gets each chunk once it is full, as `{:resource, epoch,
  {:generated_full, scheduler, full}}`, or `{:generation_failed, chunks,
  reason}` when its generation failed. Once it has persisted a chunk it says
  so (`handed_over/3`) and the cell goes; when it loads, it reports the chunks
  it has (`present/3`). It monitors the scheduler and wants again when it
  restarts.

  Work starts when the scheduler's mailbox is empty, as far as the pool has
  room; when the pool is full the next job to end wakes it.

  Proto chunks and starts live only here. A graceful stop waits briefly for
  running jobs and writes them as the dimension's snapshot
  (`generation.snapshot`), which the next start reads and deletes; after a
  crash, chunks that were not full yet generate again.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Worldgen.{Frontier, Pool}
  alias Valimc.World.Spec

  @snapshot "generation.snapshot"
  # A stop waits this long for running jobs before its snapshot.
  @drain 20_000
  # An idle scheduler (nothing wanted, running or being persisted) stops.
  @idle 60_000
  @gauges 5_000

  defstruct [
    :world,
    :dimension,
    :frontier,
    requesters: %{},
    monitors: %{},
    calls: %{},
    waiting: false,
    dirty: false,
    gauged: nil
  ]

  ## API

  def start_link({world, dimension}),
    do: GenServer.start_link(__MODULE__, {world, dimension}, name: via(world, dimension))

  def child_spec({world, dimension}),
    do: %{
      id: {__MODULE__, world, dimension},
      start: {__MODULE__, :start_link, [{world, dimension}]},
      restart: :temporary,
      shutdown: @drain + 10_000
    }

  defp via(world, dimension),
    do: {:via, Registry, {Valimc.Worldgen.Schedulers, {world, dimension}}}

  @doc "The scheduler of `dimension` of the world at `world`, started if needed."
  def whereis(world, dimension) do
    Valimc.Owners.ensure(
      Valimc.Owners.registered(Valimc.Worldgen.Schedulers, {world, dimension}),
      fn ->
        DynamicSupervisor.start_child(
          Valimc.Worldgen.SchedulerSupervisor,
          {__MODULE__, {world, dimension}}
        )
      end,
      {:retry, :scheduler_restarting}
    )
  catch
    # The supervisor is stopping.
    :exit, _ -> Valimc.Error.retry(:scheduler_unavailable)
  end

  @doc """
  `requester` (a region, fenced by `epoch`) wants `wanted` (`chunk =>
  priority`, smaller first) made full, replacing what it wanted before:
  `{:ok, scheduler}` for it to monitor.
  """
  def want(world, dimension, requester, epoch, wanted) do
    with {:ok, pid} <- whereis(world, dimension) do
      GenServer.cast(pid, {:want, requester, epoch, wanted})
      {:ok, pid}
    end
  end

  @doc "The regions persisted these full chunks."
  def handed_over(world, dimension, chunks), do: cast(world, dimension, {:handed_over, chunks})

  @doc "A region loaded with these chunks full."
  def present(world, dimension, chunks), do: cast(world, dimension, {:present, chunks})

  defp cast(_world, _dimension, {_, []}), do: :ok

  defp cast(world, dimension, message) do
    with {:ok, pid} <- whereis(world, dimension), do: GenServer.cast(pid, message)
  end

  @doc """
  `chunks` made full, in that order, without a region (checks, benches):
  `{:ok, fulls}` or `{:error, reason}`.
  """
  def full_chunks(world, dimension, chunks, timeout \\ 600_000) do
    with {:ok, pid} <- whereis(world, dimension),
         do: GenServer.call(pid, {:full_chunks, chunks}, timeout)
  end

  @doc "The chunks numbered for decoration, in order (with `:generation_order_log` on)."
  def order(world, dimension), do: call(world, dimension, :order)

  @doc "Counts of the scheduler's chunks and work."
  def stats(world, dimension), do: call(world, dimension, :stats)

  @doc "The cells of `chunks` as they are now (checks): `{:ok, [cell | nil]}`."
  def cells(world, dimension, chunks), do: call(world, dimension, {:cells, chunks})

  defp call(world, dimension, message) do
    with {:ok, pid} <- whereis(world, dimension), do: GenServer.call(pid, message, 60_000)
  end

  ## Scheduler

  @impl true
  def init({world, dimension}) do
    Process.flag(:trap_exit, true)
    Valimc.Dimension.put(dimension)
    {:ok, %__MODULE__{world: world, dimension: dimension}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    world = Spec.fetch(state.world)

    case Spec.generation(world, state.dimension) do
      {:ok, spec} ->
        frontier =
          Frontier.new(spec,
            decorated: Spec.decorated?(world, state.dimension),
            sky: Valimc.Dimension.facts(state.dimension).sky_light,
            log: Application.get_env(:valimc, :generation_order_log, false)
          )

        state = %{state | frontier: restore(frontier, state)}
        {:noreply, state, @idle}

      other ->
        {:stop, {:shutdown, {:not_generated, other}}, state}
    end
  end

  defp snapshot_path(%{world: nil}), do: nil

  defp snapshot_path(state),
    do: Path.join(Valimc.Dimension.storage(state.world, state.dimension), @snapshot)

  defp restore(frontier, state) do
    with path when is_binary(path) <- snapshot_path(state),
         {:ok, binary} <- File.read(path) do
      File.rm(path)

      case Frontier.restore(frontier, binary) do
        {:ok, frontier} ->
          frontier

        {:error, reason} ->
          Logger.warning("Ignoring the generation snapshot #{path}: #{inspect(reason)}")
          frontier
      end
    else
      _ -> frontier
    end
  end

  @impl true
  def handle_cast({:want, requester, epoch, wanted}, state) do
    state =
      case state.requesters do
        %{^requester => entry} ->
          %{state | requesters: Map.put(state.requesters, requester, %{entry | epoch: epoch})}

        _ ->
          monitor = Process.monitor(requester)
          entry = %{epoch: epoch, monitor: monitor}

          %{
            state
            | requesters: Map.put(state.requesters, requester, entry),
              monitors: Map.put(state.monitors, monitor, {:requester, requester})
          }
      end

    Valimc.Metrics.add(:worldgen_wants)
    frontier = Frontier.want(state.frontier, requester, wanted)
    noreply(%{state | frontier: frontier, dirty: true})
  end

  def handle_cast({:handed_over, chunks}, state),
    do: noreply(%{state | frontier: Frontier.handed_over(state.frontier, chunks), dirty: true})

  def handle_cast({:present, chunks}, state),
    do: noreply(%{state | frontier: Frontier.present(state.frontier, chunks), dirty: true})

  @impl true
  def handle_call({:full_chunks, chunks}, from, state) do
    ref = make_ref()
    calls = Map.put(state.calls, ref, %{from: from, chunks: chunks, got: %{}})
    frontier = Frontier.want(state.frontier, {:call, ref}, Map.new(chunks, &{&1, -1}))
    noreply(%{state | calls: calls, frontier: frontier, dirty: true})
  end

  def handle_call(:order, _from, state),
    do: reply(Frontier.order(state.frontier), state)

  def handle_call(:stats, _from, state),
    do: reply(Frontier.stats(state.frontier), state)

  def handle_call({:cells, chunks}, _from, state) do
    cells = Enum.map(chunks, &get_in(state.frontier.chunks, [&1, :cell]))
    reply({:ok, cells}, state)
  end

  @impl true
  def handle_info({:job, ref, result}, state) do
    state =
      case Enum.find(state.monitors, &match?({_, {:job, ^ref, _}}, &1)) do
        {monitor, {:job, _, started}} ->
          Process.demonitor(monitor, [:flush])
          Valimc.Metrics.add(:worldgen_microseconds, now() - started)
          %{state | monitors: Map.delete(state.monitors, monitor)}

        nil ->
          state
      end

    {frontier, events} = Frontier.done(state.frontier, ref, result)
    noreply(deliver(%{state | frontier: frontier, dirty: true}, events))
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {{:job, ref, _}, monitors} ->
        Logger.warning("A generation job went down: #{inspect(reason)}")
        {frontier, events} = Frontier.lost(state.frontier, ref)
        state = %{state | monitors: monitors, frontier: frontier, dirty: true}
        noreply(deliver(state, events))

      {{:requester, requester}, monitors} ->
        frontier = Frontier.want(state.frontier, requester, %{})
        requesters = Map.delete(state.requesters, requester)
        noreply(%{state | monitors: monitors, requesters: requesters, frontier: frontier})

      {nil, _} ->
        noreply(state)
    end
  end

  def handle_info({Pool, :free}, state),
    do: noreply(%{state | waiting: false, dirty: true})

  def handle_info(:timeout, %{dirty: true} = state), do: noreply(dispatch(state))

  def handle_info(:timeout, state) do
    if idle?(state),
      do: {:stop, :normal, state},
      else: {:noreply, state, @idle}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: noreply(state)

  # Dispatch once the mailbox is empty; idle-stop after a while otherwise.
  defp noreply(%{dirty: true} = state), do: {:noreply, state, 0}
  defp noreply(state), do: {:noreply, state, @idle}

  defp reply(value, state), do: {:reply, value, state, if(state.dirty, do: 0, else: @idle)}

  defp idle?(state) do
    f = state.frontier
    f.wants == %{} and f.jobs == %{} and MapSet.size(f.delivered) == 0 and state.calls == %{}
  end

  ## Work

  defp dispatch(state) do
    state = gauges(%{state | dirty: false})
    room = Pool.free()

    if room == 0 do
      wait(state)
    else
      if state.frontier.stale, do: Valimc.Metrics.add(:worldgen_refreshes)
      started = now()
      {jobs, frontier} = Frontier.next(state.frontier, room, Pool.free(true))
      Valimc.Metrics.add(:worldgen_dispatch_microseconds, now() - started)
      scheduler = self()

      Enum.reduce(jobs, %{state | frontier: frontier}, fn job, state ->
        run = job.run
        ref = job.ref
        work = fn -> send(scheduler, {:job, ref, Frontier.safe(run)}) end
        started = if job.bulk, do: Pool.start_bulk(work), else: Pool.start(work)

        case started do
          {:ok, pid} ->
            Valimc.Metrics.add(:"worldgen_#{job.kind}_jobs")
            monitor = Process.monitor(pid)
            %{state | monitors: Map.put(state.monitors, monitor, {:job, ref, now()})}

          {:error, :busy} ->
            # Another user of the pool took the slot.
            wait(%{state | frontier: Frontier.cancel(state.frontier, ref)})
        end
      end)
    end
  end

  # Woken by the next job that ends anywhere in the pool.
  defp wait(%{waiting: true} = state), do: state

  defp wait(state) do
    Pool.notify()
    # A job that ended before the notice was registered woke nobody.
    if Pool.free() > 0,
      do: %{state | dirty: true},
      else: %{state | waiting: true}
  end

  defp deliver(state, events), do: Enum.reduce(events, state, &event/2)

  defp event({:full, requesters, chunk, full}, state) do
    Enum.reduce(requesters, state, fn
      {:call, ref}, state ->
        case state.calls do
          %{^ref => call} -> answer(state, ref, %{call | got: Map.put(call.got, chunk, full)})
          _ -> state
        end

      pid, state ->
        case state.requesters do
          %{^pid => %{epoch: epoch}} ->
            send(pid, {:resource, epoch, {:generated_full, self(), full}})
            state

          _ ->
            state
        end
    end)
  end

  defp event({:failed, requesters, chunks, reason}, state) do
    Logger.error("Generating #{inspect(chunks)} failed: #{inspect(reason)}")

    Enum.reduce(requesters, state, fn
      {:call, ref}, state ->
        case Map.pop(state.calls, ref) do
          {nil, _} ->
            state

          {call, calls} ->
            GenServer.reply(call.from, {:error, {:generation_failed, chunks, reason}})
            frontier = Frontier.want(state.frontier, {:call, ref}, %{})
            %{state | calls: calls, frontier: frontier}
        end

      pid, state ->
        case state.requesters do
          %{^pid => %{epoch: epoch}} ->
            send(pid, {:resource, epoch, {:generation_failed, chunks, reason}})
            state

          _ ->
            state
        end
    end)
  end

  defp answer(state, ref, call) do
    if Enum.all?(call.chunks, &Map.has_key?(call.got, &1)) do
      GenServer.reply(call.from, {:ok, Enum.map(call.chunks, &Map.fetch!(call.got, &1))})
      frontier = Frontier.want(state.frontier, {:call, ref}, %{})
      # Nobody persists a call's chunks.
      frontier = %{
        frontier
        | delivered: MapSet.difference(frontier.delivered, MapSet.new(call.chunks))
      }

      %{state | calls: Map.delete(state.calls, ref), frontier: frontier}
    else
      %{state | calls: Map.put(state.calls, ref, call)}
    end
  end

  defp now, do: System.monotonic_time(:microsecond)

  ## Gauges and stop

  defp gauges(state) do
    now = System.monotonic_time(:millisecond)
    if state.gauged && now - state.gauged < @gauges, do: state, else: put_gauges(state, now)
  end

  defp put_gauges(state, now) do
    f = state.frontier
    stats = Frontier.stats(f)
    context = if f.worldgen, do: Valimc.Native.worldgen_memory(f.worldgen), else: 0
    starts = if f.starts, do: elem(Valimc.Native.gen_starts_stats(f.starts), 2), else: 0
    Valimc.Metrics.put(:"worldgen_cells_#{state.dimension}", stats.terrain + stats.decorated)
    Valimc.Metrics.put(:"worldgen_memory_bytes_#{state.dimension}", context + starts)
    %{state | gauged: now}
  end

  @impl true
  def terminate(_reason, %{frontier: %Frontier{}} = state) do
    state = drain(state, System.monotonic_time(:millisecond) + @drain)

    # Not into a world removed meanwhile (tools, tests).
    with path when is_binary(path) <- snapshot_path(state),
         true <- File.dir?(state.world),
         binary when is_binary(binary) <- Frontier.snapshot(state.frontier) do
      case Valimc.DurableFile.write(path, binary) do
        :ok -> :ok
        error -> Logger.error("Writing the generation snapshot #{path}: #{inspect(error)}")
      end
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Let running jobs finish, so their chunks are in the snapshot.
  defp drain(%{frontier: %{jobs: jobs}} = state, _deadline) when jobs == %{}, do: state

  defp drain(state, deadline) do
    receive do
      {:job, ref, result} ->
        {frontier, _events} = Frontier.done(state.frontier, ref, result)
        drain(%{state | frontier: frontier}, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> state
    end
  end
end
