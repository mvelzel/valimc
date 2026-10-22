defmodule Valimc.Worldgen.Scheduler do
  @moduledoc """
  The generation scheduler of one dimension of one world (VMC-077n): it owns
  every chunk's generation status, its proto chunk as a native cell and the
  dimension's structure starts (`Valimc.Worldgen.Frontier`), runs the work on
  `Valimc.Worldgen.Pool` and sends full chunks to the regions that want them.

  A region sends what it wants (`want/5`, its absent chunks with their
  distance to the nearest player that wants them, replaced on every change)
  and gets them once they are full, or `{:resource, epoch,
  {:generation_failed, chunks, reason}}` when their generation failed. Once
  it has persisted a chunk it says so (`handed_over/3`) and the cell goes;
  when it loads, it reports the chunks it has (`present/3`). It monitors the
  scheduler and wants again when it restarts.

  Full chunks go in deliveries with credit (VMC-077w): a requester process (a
  region group) gets `{:generated, scheduler, [{key, epoch, fulls}]}`, the
  chunks of each of its sections that wants them, only while fewer than
  #{2} of its deliveries are unacknowledged (`delivered/1`). What finishes
  meanwhile waits here and goes in its next delivery, at most #{64} chunks,
  the players' own and nearest chunks first, so a group installs what is
  ready in one pass per section and finished chunks never queue in its
  mailbox.

  Work starts as soon as what it waits for changed, a job's result included,
  as far as the pool has room (VMC-077x); while the pool is full the next job
  to end wakes it. Wants and players' focus change the priorities only where
  they changed; a full rebuild runs at most four times a second.

  Proto chunks and starts live only here. A graceful stop waits briefly for
  running jobs and writes them as the dimension's snapshot
  (`generation.snapshot`), which the next start reads and deletes; after a
  crash, chunks that were not full yet generate again.

  At most `worldgen_proto_cells` proto chunks stay in memory (VMC-077q):
  past that, the ones work does not need soon are dropped (untouched
  terrain, made again) or spilled to the dimension's scratch file
  (`generation.scratch`), which is never durable state: it is emptied at
  every start, removed at every stop, and a snapshot's chunks are restored
  into it rather than into memory.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Worldgen.{Frontier, Pool}
  alias Valimc.World.Spec

  @snapshot "generation.snapshot"
  @scratch "generation.scratch"
  # A stop waits this long for running jobs before its snapshot.
  @drain 20_000
  # An idle scheduler (nothing wanted, running or being persisted) stops.
  @idle 60_000
  @gauges 5_000
  # Unacknowledged deliveries per requester process, and chunks per delivery.
  @credit 2
  @delivery 64
  # Priorities that went up or away are rebuilt at most this often (ms).
  @refresh 250
  # Proto cells spilled per eviction pass.
  @spills 64

  defstruct [
    :world,
    :dimension,
    :frontier,
    requesters: %{},
    # Focused players' monitors.
    focused: %{},
    # Per requester, the chunks sent to it at its current epoch that its
    # wants may still name: its mailbox or its outbox here holds them (VMC-077u).
    in_flight: %{},
    # Per requester process, its unacknowledged deliveries and the full
    # chunks waiting for its next (`[{requester, chunk, full}]`, newest first).
    outbox: %{},
    monitors: %{},
    # A running job's monitor by its ref.
    job_monitors: %{},
    calls: %{},
    waiting: false,
    dirty: false,
    # When the priorities were last rebuilt (monotonic ms).
    refreshed: nil,
    gauged: nil,
    # The scratch file spilled cells go to: `%{path, file}` (opened at the
    # first spill), and the cells in memory when an eviction pass last ended
    # over the cap with nothing more it could free.
    scratch: nil,
    stuck: nil
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
    Valimc.World.Owners.ensure(
      Valimc.World.Owners.registered(Valimc.Worldgen.Schedulers, {world, dimension}),
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
    :exit, _ -> Valimc.Data.Error.retry(:scheduler_unavailable)
  end

  @doc """
  `requester` (a region section, `{group pid, key}`, fenced by `epoch`) wants `wanted` (`chunk =>
  priority`, smaller first) made full, replacing what it wanted before:
  `{:ok, scheduler}` for it to monitor. A requester that monitors the
  scheduler already passes it as `known`, and nothing is looked up.
  """
  def want(world, dimension, requester, epoch, wanted, known \\ nil) do
    found =
      if is_pid(known) and Process.alive?(known),
        do: {:ok, known},
        else: whereis(world, dimension)

    with {:ok, pid} <- found do
      GenServer.cast(pid, {:want, requester, epoch, wanted})
      {:ok, pid}
    end
  end

  @doc """
  Player `holder` (its connection) is in `chunk` of `dimension`, moving along
  `heading` (VMC-077u): its own chunk and the chunks ahead of it go first. A
  nil chunk forgets it. Only a running scheduler is told: one that starts
  later hears at the player's next chunk.
  """
  def focus(world, dimension, holder, chunk, heading) do
    case Registry.lookup(Valimc.Worldgen.Schedulers, {world, dimension}) do
      [{pid, _}] -> GenServer.cast(pid, {:focus, holder, chunk, heading})
      [] -> :ok
    end
  end

  @doc """
  The regions persisted these full chunks; `scheduler` is the pid deliveries
  came from, if known (else looked up).
  """
  def handed_over(world, dimension, chunks, scheduler \\ nil)
  def handed_over(_world, _dimension, [], _scheduler), do: :ok

  def handed_over(_world, _dimension, chunks, scheduler) when is_pid(scheduler),
    do: GenServer.cast(scheduler, {:handed_over, chunks})

  def handed_over(world, dimension, chunks, nil),
    do: cast(world, dimension, {:handed_over, chunks})

  @doc "The calling process installed a delivery from `scheduler`: it may send the next."
  def delivered(scheduler), do: GenServer.cast(scheduler, {:delivered, self()})

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
    Valimc.World.Dimension.put(dimension)

    state = %__MODULE__{world: world, dimension: dimension, refreshed: now_ms()}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    world = Spec.fetch(state.world)

    case Spec.generation(world, state.dimension) do
      {:ok, spec} ->
        frontier =
          Frontier.new(spec,
            decorated: Spec.decorated?(world, state.dimension),
            sky: Valimc.World.Dimension.facts(state.dimension).sky_light,
            log: Application.get_env(:valimc, :generation_order_log, false)
          )

        path = scratch_path(state)
        File.rm(path)

        state = %{
          state
          | scratch: %{path: path, file: nil},
            frontier: %{frontier | cap: Valimc.config(:worldgen_proto_cells), scratch: path}
        }

        {frontier, state} = restore(state.frontier, state)
        noreply(%{state | frontier: frontier})

      other ->
        {:stop, {:shutdown, {:not_generated, other}}, state}
    end
  end

  defp snapshot_path(%{world: nil}), do: nil

  defp snapshot_path(state),
    do: Path.join(Valimc.World.Dimension.storage(state.world, state.dimension), @snapshot)

  # A snapshot's proto chunks go to the scratch file, not into memory.
  defp restore(frontier, state) do
    with path when is_binary(path) <- snapshot_path(state),
         {:ok, binary} <- File.read(path) do
      File.rm(path)
      state = open_scratch(state)
      file = state.scratch.file

      spill = fn image ->
        {:ok, offset} = :file.position(file, :eof)
        :ok = :file.write(file, image)
        {offset, byte_size(image)}
      end

      case Frontier.restore(frontier, binary, spill) do
        {:ok, frontier} ->
          {frontier, state}

        {:error, reason} ->
          Logger.warning("Ignoring the generation snapshot #{path}: #{inspect(reason)}")
          {frontier, state}
      end
    else
      _ -> {frontier, state}
    end
  end

  defp scratch_path(%{world: nil, dimension: dimension}),
    do:
      Path.join(
        System.tmp_dir!(),
        "valimc-#{dimension}-#{System.unique_integer([:positive])}-#{@scratch}"
      )

  defp scratch_path(state),
    do: Path.join(Valimc.World.Dimension.storage(state.world, state.dimension), @scratch)

  defp open_scratch(%{scratch: %{file: nil, path: path}} = state) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, file} = :file.open(path, [:read, :write, :raw, :binary])
    %{state | scratch: %{state.scratch | file: file}}
  end

  defp open_scratch(state), do: state

  # Past the cap: drop and spill what work does not need soon, a batch per
  # dispatch. A pass looks at every cell in memory: after one that could not
  # get under the cap, the next waits for an eighth of the cap more cells.
  defp spill(%{frontier: %{cap: cap, in_memory: n}} = state)
       when is_integer(cap) and n > cap and
              (state.stuck == nil or n >= state.stuck + max(div(cap, 8), 1)) do
    {frontier, spills} = Frontier.evictions(state.frontier, @spills)
    state = if spills == [], do: state, else: open_scratch(state)
    file = state.scratch.file

    locations =
      for {chunk, cell} <- spills do
        {:ok, bytes} = Valimc.Native.gen_encode(cell)
        {:ok, offset} = :file.position(file, :eof)
        :ok = :file.write(file, bytes)
        {chunk, offset, byte_size(bytes)}
      end

    frontier = Frontier.spilled(frontier, locations)
    Valimc.Data.Metrics.add(:worldgen_spills, length(locations))
    Valimc.Data.Metrics.add(:worldgen_drops, frontier.dropped - state.frontier.dropped)
    # A full batch: more may go at the next dispatch.
    stuck = if frontier.in_memory > cap and length(spills) < @spills, do: frontier.in_memory
    %{state | frontier: frontier, stuck: stuck}
  end

  defp spill(state), do: state

  @impl true
  def handle_cast({:want, requester, epoch, wanted}, state) do
    state =
      case state.requesters do
        %{^requester => entry} ->
          %{state | requesters: Map.put(state.requesters, requester, %{entry | epoch: epoch})}

        _ ->
          monitor = Process.monitor(requester_pid(requester))
          entry = %{epoch: epoch, monitor: monitor}

          %{
            state
            | requesters: Map.put(state.requesters, requester, entry),
              monitors: Map.put(state.monitors, monitor, {:requester, requester})
          }
      end

    Valimc.Data.Metrics.add(:worldgen_wants)
    {wanted, state} = in_flight(state, requester, epoch, wanted)
    frontier = Frontier.want(state.frontier, requester, wanted)
    noreply(%{state | frontier: frontier, dirty: true})
  end

  def handle_cast({:focus, holder, chunk, heading}, state) do
    state =
      case {state.focused, chunk} do
        {%{^holder => monitor}, nil} ->
          Process.demonitor(monitor, [:flush])

          %{
            state
            | focused: Map.delete(state.focused, holder),
              monitors: Map.delete(state.monitors, monitor)
          }

        {%{^holder => _}, _} ->
          state

        {_, nil} ->
          state

        _ ->
          monitor = Process.monitor(holder)

          %{
            state
            | focused: Map.put(state.focused, holder, monitor),
              monitors: Map.put(state.monitors, monitor, {:focus, holder})
          }
      end

    frontier = Frontier.focus(state.frontier, holder, chunk, heading)
    noreply(%{state | frontier: frontier, dirty: true})
  end

  def handle_cast({:delivered, pid}, state) do
    case state.outbox do
      %{^pid => entry} ->
        entry = %{entry | unacked: max(entry.unacked - 1, 0)}
        noreply(flush(%{state | outbox: Map.put(state.outbox, pid, entry)}, pid))

      _ ->
        noreply(state)
    end
  end

  def handle_cast({:handed_over, chunks}, state),
    do: noreply(%{state | frontier: Frontier.handed_over(state.frontier, chunks), dirty: true})

  def handle_cast({:present, chunks}, state),
    do: noreply(%{state | frontier: Frontier.present(state.frontier, chunks), dirty: true})

  # A region that wants chunks again before it read them (its mailbox lags
  # behind its tickets) is not sent them twice: messages to it arrive in
  # order, and a section loaded again has a new epoch. A chunk sent that it no
  # longer wants is done with, so wanting it later sends it again.
  defp in_flight(state, requester, epoch, wanted) do
    case state.in_flight do
      %{^requester => {^epoch, sent}} ->
        {pending, wanted} = Map.split(wanted, MapSet.to_list(sent))
        sent = MapSet.new(Map.keys(pending))
        {wanted, %{state | in_flight: Map.put(state.in_flight, requester, {epoch, sent})}}

      %{^requester => _} ->
        {wanted, %{state | in_flight: Map.delete(state.in_flight, requester)}}

      _ ->
        {wanted, state}
    end
  end

  @impl true
  def handle_call({:full_chunks, chunks}, from, state) do
    ref = make_ref()
    calls = Map.put(state.calls, ref, %{from: from, chunks: chunks, got: %{}})
    frontier = Frontier.want(state.frontier, {:call, ref}, Map.new(chunks, &{&1, -1}))
    noreply(%{state | calls: calls, frontier: frontier, dirty: true})
  end

  def handle_call(:order, _from, state),
    do: reply(Frontier.order(state.frontier), state)

  def handle_call(:stats, _from, state) do
    {:ok, bytes} = Valimc.Native.gen_cells_bytes(Frontier.cells_in_memory(state.frontier))
    reply(Map.put(Frontier.stats(state.frontier), :proto_bytes, bytes), state)
  end

  def handle_call({:cells, chunks}, _from, state) do
    cells =
      Enum.map(chunks, fn chunk ->
        case get_in(state.frontier.chunks, [chunk, :cell]) do
          {:spilled, offset, size} ->
            {:ok, bytes} = Frontier.read_spilled(state.scratch.path, offset, size)
            elem(Valimc.Native.gen_decode(state.frontier.worldgen, bytes), 1)

          cell ->
            cell
        end
      end)

    reply({:ok, cells}, state)
  end

  @impl true
  def handle_info({:job, ref, result}, state) do
    state =
      case Map.pop(state.job_monitors, ref) do
        {nil, _} ->
          state

        {monitor, job_monitors} ->
          {:job, _, started} = Map.fetch!(state.monitors, monitor)
          Process.demonitor(monitor, [:flush])
          Valimc.Data.Metrics.add(:worldgen_microseconds, now() - started)

          with %{kind: kind} <- state.frontier.jobs[ref],
               do: Valimc.Data.Metrics.add(:"worldgen_#{kind}_microseconds", now() - started)

          monitors = Map.delete(state.monitors, monitor)
          %{state | monitors: monitors, job_monitors: job_monitors}
      end

    {frontier, events} = Frontier.done(state.frontier, ref, result)
    noreply(deliver(%{state | frontier: frontier, dirty: true}, events))
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {{:job, ref, _}, monitors} ->
        Logger.warning("A generation job went down: #{inspect(reason)}")
        {frontier, events} = Frontier.lost(state.frontier, ref)
        job_monitors = Map.delete(state.job_monitors, ref)

        state = %{
          state
          | monitors: monitors,
            job_monitors: job_monitors,
            frontier: frontier,
            dirty: true
        }

        noreply(deliver(state, events))

      {{:requester, requester}, monitors} ->
        frontier = Frontier.want(state.frontier, requester, %{})
        requesters = Map.delete(state.requesters, requester)
        in_flight = Map.delete(state.in_flight, requester)
        # Every requester of that process is going: its deliveries with it.
        outbox = Map.delete(state.outbox, requester_pid(requester))

        noreply(%{
          state
          | monitors: monitors,
            requesters: requesters,
            in_flight: in_flight,
            outbox: outbox,
            frontier: frontier
        })

      {{:focus, holder}, monitors} ->
        frontier = Frontier.focus(state.frontier, holder, nil, nil)
        focused = Map.delete(state.focused, holder)
        noreply(%{state | monitors: monitors, focused: focused, frontier: frontier})

      {nil, _} ->
        noreply(state)
    end
  end

  def handle_info({Pool, :free}, state),
    do: noreply(%{state | waiting: false, dirty: true})

  def handle_info(:timeout, state) do
    cond do
      state.dirty or state.frontier.stale -> noreply(%{state | dirty: true})
      idle?(state) -> {:stop, :normal, state}
      true -> {:noreply, state, @idle}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: noreply(state)

  # Work starts as soon as anything changed, as far as the pool has room
  # (VMC-077x): a job's result starts the next one at once.
  defp noreply(state) do
    state = if state.dirty, do: dispatch(state), else: state
    {:noreply, state, timeout(state)}
  end

  defp reply(value, state) do
    state = if state.dirty, do: dispatch(state), else: state
    {:reply, value, state, timeout(state)}
  end

  # Back at once when a dispatch asked for it; when a refresh is pending, once
  # it is due; else idle-stop after a while.
  defp timeout(%{dirty: true}), do: 0

  defp timeout(%{frontier: %{stale: true}} = state),
    do: max(state.refreshed + @refresh - now_ms(), 0)

  defp timeout(_state), do: @idle

  defp idle?(state) do
    f = state.frontier
    f.wants == %{} and f.jobs == %{} and MapSet.size(f.delivered) == 0 and state.calls == %{}
  end

  ## Work

  defp dispatch(state) do
    state = %{state | dirty: false} |> spill() |> gauges() |> refresh()
    room = Pool.free()

    if room == 0 do
      wait(state, false)
    else
      started = now()
      {jobs, frontier} = Frontier.next(state.frontier, room, Pool.free(true))
      Valimc.Data.Metrics.add(:worldgen_dispatch_microseconds, now() - started)
      # Chunks wanted and not sent yet: the pool should be busy while any are.
      Valimc.Data.Metrics.put(:"worldgen_wanted_#{state.dimension}", map_size(frontier.priority))
      scheduler = self()

      state =
        Enum.reduce(jobs, %{state | frontier: frontier}, fn job, state ->
          run = job.run
          ref = job.ref
          work = fn -> send(scheduler, {:job, ref, Frontier.safe(run)}) end
          started = if job.bulk, do: Pool.start_bulk(work), else: Pool.start(work)

          case started do
            {:ok, pid} ->
              Valimc.Data.Metrics.add(:"worldgen_#{job.kind}_jobs")
              monitor = Process.monitor(pid)

              %{
                state
                | monitors: Map.put(state.monitors, monitor, {:job, ref, now()}),
                  job_monitors: Map.put(state.job_monitors, ref, monitor)
              }

            {:error, :busy} ->
              # Another user of the pool took the slot.
              wait(%{state | frontier: Frontier.cancel(state.frontier, ref)}, job.bulk)
          end
        end)

      # Terrain left out while its slots are taken: the next to free one
      # wakes the scheduler, whoever's job held it.
      if Pool.free(true) == 0 and :gb_sets.size(state.frontier.queue) > 0,
        do: wait(state, true),
        else: state
    end
  end

  # The whole rebuild of the priorities, at most every `@refresh` ms.
  defp refresh(%{frontier: %{stale: true}} = state) do
    at = now_ms()

    if at - state.refreshed >= @refresh do
      started = now()
      frontier = Frontier.refresh(state.frontier)
      Valimc.Data.Metrics.add(:worldgen_refreshes)
      Valimc.Data.Metrics.add(:worldgen_refresh_microseconds, now() - started)
      %{state | frontier: frontier, refreshed: at}
    else
      state
    end
  end

  defp refresh(state), do: state

  # Woken by the next job that ends anywhere in the pool (with a slot bulk
  # work may take, for bulk).
  defp wait(%{waiting: true} = state, _bulk), do: state

  defp wait(state, bulk) do
    Pool.notify()
    # A job that ended before the notice was registered woke nobody.
    if Pool.free(bulk) > 0,
      do: %{state | dirty: true},
      else: %{state | waiting: true}
  end

  defp deliver(state, events) do
    state = Enum.reduce(events, state, &event/2)

    events
    |> Enum.flat_map(fn
      {:full, requesters, _, _} -> for {pid, _} <- requesters, is_pid(pid), do: pid
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.reduce(state, &flush(&2, &1))
  end

  # The next delivery to `pid`, if it has credit and chunks wait: the
  # players' own and nearest chunks first, grouped by section.
  defp flush(state, pid) do
    case state.outbox do
      %{^pid => %{unacked: unacked, ready: [_ | _] = ready} = entry} when unacked < @credit ->
        rank = &Frontier.rank(state.frontier, &1)

        {sent, waiting} =
          ready
          |> Enum.reverse()
          |> Enum.sort_by(fn {_, chunk, _} -> rank.(chunk) end)
          |> Enum.split(@delivery)

        # Sections in the order of their first chunk.
        sections =
          sent
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
          |> Enum.sort_by(fn {_, [full | _]} -> rank.({full.x, full.z}) end)
          |> Enum.flat_map(fn {requester, fulls} ->
            case state.requesters do
              %{^requester => %{epoch: epoch}} -> [{requester_key(requester), epoch, fulls}]
              _ -> []
            end
          end)

        unacked = if sections == [], do: unacked, else: unacked + 1
        if sections != [], do: send(pid, {:generated, self(), sections})
        entry = %{entry | unacked: unacked, ready: Enum.reverse(waiting)}
        flush(%{state | outbox: Map.put(state.outbox, pid, entry)}, pid)

      _ ->
        state
    end
  end

  defp event({:full, requesters, chunk, full}, state) do
    Enum.reduce(requesters, state, fn
      {:call, ref}, state ->
        case state.calls do
          %{^ref => call} -> answer(state, ref, %{call | got: Map.put(call.got, chunk, full)})
          _ -> state
        end

      requester, state ->
        case state.requesters do
          %{^requester => %{epoch: epoch}} ->
            pid = requester_pid(requester)
            entry = Map.get(state.outbox, pid, %{unacked: 0, ready: []})
            entry = %{entry | ready: [{requester, chunk, full} | entry.ready]}

            in_flight =
              Map.update(state.in_flight, requester, {epoch, MapSet.new([chunk])}, fn
                {^epoch, sent} -> {epoch, MapSet.put(sent, chunk)}
                _ -> {epoch, MapSet.new([chunk])}
              end)

            %{state | in_flight: in_flight, outbox: Map.put(state.outbox, pid, entry)}

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

      requester, state ->
        case state.requesters do
          %{^requester => %{epoch: epoch}} ->
            send(
              requester_pid(requester),
              {:resource, epoch, {:generation_failed, chunks, reason}}
            )

            state

          _ ->
            state
        end
    end)
  end

  # A region section asks as `{group pid, key}` (VMC-077j); others as their pid.
  defp requester_pid({pid, _key}) when is_pid(pid), do: pid
  defp requester_pid(pid) when is_pid(pid), do: pid

  defp requester_key({_pid, key}), do: key
  defp requester_key(_pid), do: nil

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
  defp now_ms, do: System.monotonic_time(:millisecond)

  ## Gauges and stop

  defp gauges(state) do
    now = System.monotonic_time(:millisecond)
    if state.gauged && now - state.gauged < @gauges, do: state, else: put_gauges(state, now)
  end

  # Memory: the generation context, the start table and the proto cells in
  # memory; and the cells spilled and the scratch file's bytes (VMC-077q).
  defp put_gauges(state, now) do
    f = state.frontier
    d = state.dimension
    context = if f.worldgen, do: Valimc.Native.worldgen_memory(f.worldgen), else: 0
    starts = if f.starts, do: elem(Valimc.Native.gen_starts_stats(f.starts), 2), else: 0
    {:ok, protos} = Valimc.Native.gen_cells_bytes(Frontier.cells_in_memory(f))
    Valimc.Data.Metrics.put(:"worldgen_cells_#{d}", f.in_memory)
    Valimc.Data.Metrics.put(:"worldgen_proto_bytes_#{d}", protos)
    Valimc.Data.Metrics.put(:"worldgen_memory_bytes_#{d}", context + starts + protos)
    Valimc.Data.Metrics.put(:"worldgen_spilled_#{d}", Frontier.stats(f).spilled)
    Valimc.Data.Metrics.put(:"worldgen_scratch_bytes_#{d}", scratch_bytes(state))
    %{state | gauged: now}
  end

  defp scratch_bytes(%{scratch: %{file: file}}) when file != nil,
    do: elem(:file.position(file, :eof), 1)

  defp scratch_bytes(_state), do: 0

  @impl true
  def terminate(_reason, %{frontier: %Frontier{}} = state) do
    state = drain(state, System.monotonic_time(:millisecond) + @drain)

    # Not into a world removed meanwhile (tools, tests).
    with path when is_binary(path) <- snapshot_path(state),
         true <- File.dir?(state.world),
         binary when is_binary(binary) <- Frontier.snapshot(state.frontier) do
      case Valimc.Storage.DurableFile.write(path, binary) do
        :ok -> :ok
        error -> Logger.error("Writing the generation snapshot #{path}: #{inspect(error)}")
      end
    end

    remove_scratch(state)
  end

  def terminate(_reason, state), do: remove_scratch(state)

  defp remove_scratch(%{scratch: %{path: path, file: file}}) do
    if file, do: :file.close(file)
    File.rm(path)
    :ok
  end

  defp remove_scratch(_state), do: :ok

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
