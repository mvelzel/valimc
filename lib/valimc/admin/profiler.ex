defmodule Valimc.Admin.Profiler do
  @moduledoc """
  Local spark-style profiling (VMC-056). One supervised observer owns a bounded
  capture and 15 minutes of health history. Gameplay only publishes ETS rows.
  Reports are bearer capabilities, retained in memory (16) and as local files.
  """
  use GenServer
  require Logger
  alias Valimc.Admin.ProfileSampler
  alias Valimc.Data.{Metrics, ProfileTicks}
  @reports Valimc.ProfileReports
  @view Valimc.ProfileHealth

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def start(options, notify \\ fn _ -> :ok end),
    do: GenServer.call(__MODULE__, {:start, options, notify})

  def stop, do: GenServer.call(__MODULE__, :stop, 30_000)
  def cancel, do: GenServer.call(__MODULE__, :cancel)
  def info, do: GenServer.call(__MODULE__, :info)
  def health_report, do: GenServer.call(__MODULE__, :health_report)
  def activity, do: GenServer.call(__MODULE__, :activity)

  def monitor(key, threshold, notify),
    do: GenServer.call(__MODULE__, {:monitor, key, threshold, notify})

  def health, do: :ets.lookup_element(@view, :health, 2, %{})
  # The network owner outlives an observer restart; its publication must too.
  def viewer_port(port), do: :persistent_term.put({__MODULE__, :viewer_port}, port)

  def url(id) do
    address = :persistent_term.get({__MODULE__, :viewer_port}, 0)
    port = if is_function(address, 0), do: address.(), else: address
    "http://127.0.0.1:#{port}/r/#{id}"
  end

  def report(id) do
    case :ets.lookup(@reports, id) do
      [{_, data}] -> {:ok, data}
      [] -> :error
    end
  end

  @doc "Validate all options before changing capture state."
  def options(tokens) do
    defaults = %{timeout: 60, interval: 20, process: "*", include_waiting: false}
    parse_options(tokens, defaults, MapSet.new())
  end

  defp parse_options([], options, _seen), do: {:ok, options}

  defp parse_options(["--include-waiting" = flag | rest], options, seen) do
    if MapSet.member?(seen, flag),
      do: {:error, "Duplicate #{flag}"},
      else: parse_options(rest, %{options | include_waiting: true}, MapSet.put(seen, flag))
  end

  defp parse_options([flag, value | rest], options, seen)
       when flag in ["--timeout", "--interval", "--process"] do
    key = %{"--timeout" => :timeout, "--interval" => :interval, "--process" => :process}[flag]
    parsed = if key == :process, do: {:ok, value}, else: Integer.parse(value)

    valid =
      case {key, parsed} do
        {:timeout, {n, ""}} when n in 1..600 -> {:ok, n}
        {:interval, {n, ""}} when n in 10..1000 -> {:ok, n}
        {:process, {:ok, value}} when byte_size(value) in 1..128 -> {:ok, value}
        _ -> :error
      end

    case valid do
      {:ok, value} ->
        if MapSet.member?(seen, flag),
          do: {:error, "Duplicate #{flag}"},
          else: parse_options(rest, Map.put(options, key, value), MapSet.put(seen, flag))

      :error ->
        {:error,
         "Invalid #{flag}: timeout 1–600 s, interval 10–1000 ms, process name up to 128 bytes"}
    end
  end

  defp parse_options(_, _, _),
    do: {:error, "Unsupported option. Use --timeout, --interval, --process or --include-waiting"}

  @impl true
  def init(_opts) do
    :ets.new(@reports, [:named_table, :protected, read_concurrency: true])
    :ets.new(@view, [:named_table, :public, read_concurrency: true])
    :erlang.system_flag(:scheduler_wall_time, true)

    state = %{
      capture: nil,
      history: [],
      reports: [],
      activity: [],
      wall: %{},
      clock: Metrics.get(:clock_ticks),
      at: now(),
      previous_ticks: %{},
      monitors: %{},
      slow_sequence: 0
    }

    send(self(), :health)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, _options, _notify}, _from, %{capture: capture} = state)
      when capture != nil,
      do: {:reply, {:error, "A profile is already running; stop or cancel it first"}, state}

  def handle_call({:start, options, notify}, _from, state) do
    # Revalidate even callers outside the command parser.
    tokens =
      [
        "--timeout",
        to_string(options.timeout),
        "--interval",
        to_string(options.interval),
        "--process",
        options.process
      ] ++ if(options.include_waiting, do: ["--include-waiting"], else: [])

    case options(tokens) do
      {:error, _} = error ->
        {:reply, error, state}

      {:ok, validated} ->
        id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        capture = %{
          id: id,
          started: now(),
          date: DateTime.to_iso8601(DateTime.utc_now()),
          sampler: ProfileSampler.new(validated),
          notify: notify
        }

        Process.send_after(self(), {:sample, id}, validated.interval)
        state = %{state | capture: capture} |> event("Profile started") |> publish_capture()
        {:reply, {:ok, id}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info =
      if state.capture,
        do: %{
          id: state.capture.id,
          elapsed: now() - state.capture.started,
          options: state.capture.sampler.options
        },
        else: nil

    {:reply, info, state}
  end

  def handle_call(:stop, _from, %{capture: nil} = state),
    do: {:reply, {:error, "No profile is running"}, state}

  def handle_call(:stop, _from, state) do
    {result, state} = finish(state)
    {:reply, result, state}
  end

  def handle_call(:cancel, _from, state) do
    if state.capture, do: :ets.delete(@reports, state.capture.id)
    {:reply, :ok, %{state | capture: nil} |> event("Profile cancelled")}
  end

  def handle_call(:activity, _from, state), do: {:reply, state.activity, state}

  def handle_call({:monitor, key, threshold, notify}, _from, state) do
    cond do
      Map.has_key?(state.monitors, key) ->
        {:reply, {:ok, false}, %{state | monitors: Map.delete(state.monitors, key)}}

      map_size(state.monitors) >= 16 ->
        {:reply, {:error, "Tick monitor subscriber limit reached"}, state}

      true ->
        monitor = %{threshold: threshold, notify: notify, expires: now() + 600_000}
        {:reply, {:ok, true}, %{state | monitors: Map.put(state.monitors, key, monitor)}}
    end
  end

  def handle_call(:health_report, _from, state) do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    :ets.insert(
      @reports,
      {id,
       %{kind: "health", status: "live", health: health(), history: Enum.reverse(state.history)}}
    )

    {:reply, {:ok, id}, retain(state, id)}
  end

  @impl true
  def handle_info({:sample, id}, %{capture: %{id: id} = capture} = state) do
    time = now()

    if time - capture.started >= capture.sampler.options.timeout * 1000 do
      {result, state} = finish(state)
      capture.notify.(result)
      {:noreply, state}
    else
      sampler = ProfileSampler.sample(capture.sampler, time)
      # Schedule after work; slow observations cannot accumulate timer messages.
      Process.send_after(self(), {:sample, id}, sampler.options.interval)
      {:noreply, %{state | capture: %{capture | sampler: sampler}}}
    end
  end

  def handle_info({:sample, _stale}, state), do: {:noreply, state}

  def handle_info(:health, state) do
    time = now()
    {health, wall, ticks} = snapshot(state, time)

    history =
      Enum.take(
        [Map.take(health, [:at, :tps, :memory, :run_queue, :scheduler, :mspt]) | state.history],
        900
      )

    health = Map.put(health, :windows, windows(history))
    :ets.insert(@view, {:health, health})

    state = %{
      state
      | history: history,
        wall: wall,
        clock: health.clock_ticks,
        at: time,
        previous_ticks: ticks
    }

    slow = ProfileTicks.slow_since(state.slow_sequence)

    monitors =
      Map.filter(state.monitors, fn {key, monitor} ->
        alive = (not is_pid(key) or Process.alive?(key)) and monitor.expires > time
        matches = Enum.filter(slow, &(&1.ms >= monitor.threshold))

        if alive and matches != [] do
          worst = Enum.max_by(matches, & &1.ms)

          monitor.notify.(
            "#{length(matches)} slow region ticks; worst #{Float.round(worst.ms, 2)}ms at #{worst.pid} (#{worst.late_ms}ms late)."
          )
        end

        alive
      end)

    sequence = Enum.reduce(slow, state.slow_sequence, &max(&1.sequence, &2))
    state = %{state | monitors: monitors, slow_sequence: sequence}
    state = publish_capture(state)

    for {id, %{kind: "health"}} <- :ets.tab2list(@reports),
        do:
          :ets.insert(
            @reports,
            {id,
             %{kind: "health", status: "live", health: health, history: Enum.reverse(history)}}
          )

    Process.send_after(self(), :health, 1000)
    {:noreply, state}
  end

  defp snapshot(state, time) do
    wall =
      Map.new(:erlang.statistics(:scheduler_wall_time_all), fn {id, active, total} ->
        {id, {active, total}}
      end)

    normal = :erlang.system_info(:schedulers)
    dirty = :erlang.system_info(:dirty_cpu_schedulers)

    utilization =
      for {kind, ids} <- [
            normal: 1..System.schedulers_online(),
            dirty_cpu: (normal + 1)..(normal + :erlang.system_info(:dirty_cpu_schedulers_online)),
            dirty_io: (normal + dirty + 1)..map_size(wall)
          ],
          into: %{} do
        {active, total} =
          Enum.reduce(ids, {0, 0}, fn id, {a, t} ->
            with {a1, t1} <- wall[id], {a0, t0} <- state.wall[id], true <- t1 > t0 do
              {a + max(0, a1 - a0), t + t1 - t0}
            else
              _ -> {a, t}
            end
          end)

        {kind, if(total > 0, do: 100.0 * active / total, else: 0.0)}
      end

    clock = Metrics.get(:clock_ticks)
    elapsed = max(time - state.at, 1)
    ticks = ProfileTicks.snapshot()

    owners =
      Enum.map(ticks, fn {pid, count, total, maximum, last, late, at} ->
        {old_count, old_total} = Map.get(state.previous_ticks, pid, {count, total})
        n = count - old_count

        %{
          pid: inspect(pid),
          ticks: count,
          tps: n * 1000.0 / elapsed,
          mean_ms: if(n > 0, do: (total - old_total) / n / 1.0e6, else: 0.0),
          last_ms: last / 1.0e6,
          max_ms: maximum / 1.0e6,
          late_ms: late,
          age_ms: time - at
        }
      end)

    {samples, count} = Valimc.World.TickRate.samples()

    values =
      samples |> Enum.take(min(count, length(samples))) |> Enum.map(&(&1 / 1.0e6)) |> Enum.sort()

    {gc, words, _} = :erlang.statistics(:garbage_collection)

    health = %{
      at: System.system_time(:millisecond),
      clock_ticks: clock,
      tps: max(0, clock - state.clock) * 1000.0 / elapsed,
      tick_state: Map.take(Valimc.World.TickRate.published(), [:rate, :frozen, :sprinting]),
      mspt: %{
        min: List.first(values) || 0.0,
        median: median(values),
        mean: if(values == [], do: 0.0, else: Enum.sum(values) / length(values)),
        p95: Enum.at(values, max(0, ceil(length(values) * 0.95) - 1), 0.0),
        max: List.last(values) || 0.0
      },
      scheduler: utilization,
      memory: Map.new(:erlang.memory()),
      gc: %{collections: gc, reclaimed_words: words},
      run_queue: :erlang.statistics(:run_queue),
      processes: :erlang.system_info(:process_count),
      schedulers: System.schedulers_online(),
      counters: Metrics.counters(),
      owners: Enum.sort_by(owners, &(-&1.last_ms)),
      ets: ets_summary(),
      player_rtt_ms: ProfileTicks.pings() |> Map.values()
    }

    {health, wall,
     Map.new(ticks, fn {pid, count, total, _, _, _, _} -> {pid, {count, total}} end)}
  end

  @doc false
  def median([]), do: 0.0

  def median(sorted) do
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 0,
      do: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2,
      else: Enum.at(sorted, middle)
  end

  @doc false
  def windows(history) do
    latest =
      case history do
        [h | _] -> h.at
        [] -> 0
      end

    for seconds <- [5, 10, 60, 300, 900] do
      points = Enum.take_while(history, &(&1.at > latest - seconds * 1000))
      average = fn fun -> Enum.sum(Enum.map(points, fun)) / max(1, length(points)) end

      %{
        seconds: seconds,
        observations: length(points),
        tps: average.(& &1.tps),
        scheduler:
          Map.new([:normal, :dirty_cpu, :dirty_io], fn key ->
            {key, average.(& &1.scheduler[key])}
          end)
      }
    end
  end

  defp ets_summary do
    :ets.all()
    |> Enum.flat_map(fn table ->
      case :ets.info(table) do
        :undefined ->
          []

        info ->
          [
            %{
              name: inspect(info[:name]),
              size: info[:size],
              bytes: info[:memory] * :erlang.system_info(:wordsize)
            }
          ]
      end
    end)
    |> Enum.sort_by(&(-&1.bytes))
    |> Enum.take(32)
  end

  defp capture_data(state, status) do
    capture = state.capture

    Map.merge(
      ProfileSampler.export(capture.sampler),
      %{
        kind: "profile",
        status: status,
        started: capture.date,
        elapsed_ms: now() - capture.started,
        options: capture.sampler.options,
        health: health(),
        history: Enum.reverse(state.history)
      }
    )
  end

  defp publish_capture(%{capture: nil} = state), do: state

  defp publish_capture(state) do
    :ets.insert(@reports, {state.capture.id, capture_data(state, "running")})
    state
  end

  defp finish(state) do
    id = state.capture.id
    data = capture_data(state, "complete")
    :ets.insert(@reports, {id, data})
    directory = Application.get_env(:valimc, :profiler_path, ".local/profiles")

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- File.write(Path.join(directory, id <> ".json"), :json.encode(data)),
           :ok <-
             File.write(
               Path.join(directory, id <> ".html"),
               Valimc.Admin.ProfileReport.html(data)
             ) do
        {:ok, id}
      else
        {:error, reason} ->
          {:error, "Profile retained at #{url(id)}; saving failed: #{inspect(reason)}"}
      end

    Logger.info("[spark] Profile complete: #{url(id)} (#{directory}/#{id}.html)")
    {result, %{state | capture: nil} |> retain(id) |> event("Profile complete: #{url(id)}")}
  end

  defp retain(state, id) do
    ids = [id | List.delete(state.reports, id)]
    for expired <- Enum.drop(ids, 16), do: :ets.delete(@reports, expired)
    %{state | reports: Enum.take(ids, 16)}
  end

  defp event(state, message),
    do: %{state | activity: Enum.take(["#{DateTime.utc_now()} #{message}" | state.activity], 32)}

  defp now, do: System.monotonic_time(:millisecond)
end
