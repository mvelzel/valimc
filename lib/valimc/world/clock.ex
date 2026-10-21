defmodule Valimc.World.Clock do
  use GenServer
  alias Valimc.Protocol.Packets

  alias Valimc.World.{
    Border,
    ClockRecord,
    ClockState,
    ClockStore,
    Difficulty,
    Weather,
    WeatherReplication
  }

  @moduledoc "World clock ownership and immutable time replication, independent of region gameplay."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 20_000}

  def snapshot(pid \\ __MODULE__), do: GenServer.call(pid, :snapshot)
  def flush(pid \\ __MODULE__), do: GenServer.call(pid, :flush, 20_000)
  def configure(operation, pid \\ __MODULE__), do: GenServer.call(pid, {:configure, operation})

  def publication do
    [{:network, version, packet, _latest}] = :ets.lookup(__MODULE__, :network)
    {version, packet}
  end

  def initial do
    [{:network, version, _periodic, latest}] = :ets.lookup(__MODULE__, :network)
    {version, latest}
  end

  def weather do
    [{:weather, view}] = :ets.lookup(__MODULE__, :weather)
    view
  end

  def difficulty do
    [{:difficulty, view}] = :ets.lookup(__MODULE__, :difficulty)
    view
  end

  def survival do
    [{:survival, view}] = :ets.lookup(__MODULE__, :survival)
    view
  end

  @overworld "minecraft:overworld"

  @doc "A dimension's world border (VMC-027b), for replication and commands."
  def border(dimension \\ @overworld),
    do: :ets.lookup_element(__MODULE__, {:border, dimension}, 2)

  @doc """
  A dimension's border as collision and damage readers need it
  (`Border.physics/1`); vanilla's default border when no clock runs (offline
  checks).
  """
  def border_physics(dimension \\ @overworld) do
    :ets.lookup_element(__MODULE__, {:border, dimension}, 3)
  rescue
    ArgumentError -> Border.physics(Border.new())
  end

  @doc "The border collision observation (`Valimc.Physics.BorderSnapshot`)."
  def border_snapshot(dimension \\ @overworld), do: border_physics(dimension).snapshot

  @doc """
  Apply one `/worldborder` change atomically against the current border
  (`Border.command/3` at the current game time): `{:ok, result}` or
  `{:error, reason}`.
  """
  def border_command(operation, dimension \\ @overworld, pid \\ __MODULE__),
    do: GenServer.call(pid, {:border_command, dimension, operation})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = ClockStore.path(Keyword.get(opts, :world_path, Valimc.config(:world_path)))
    {:ok, store} = ClockStore.start_link(path)

    case ClockStore.load(store) do
      {:ok, data} ->
        table_opts = [:set, :protected, read_concurrency: true]

        table_opts =
          if Keyword.get(opts, :name, __MODULE__) == __MODULE__,
            do: [:named_table | table_opts],
            else: table_opts

        table = :ets.new(__MODULE__, table_opts)

        state = %{
          data: data,
          table: table,
          store: store,
          revision: 0,
          dirty: false,
          saving: nil,
          tick_timer: nil,
          save_timer: nil,
          sync_ticks: 0,
          # Without an explicit interval the clock follows `/tick` (`TickRate`).
          tick_interval: Keyword.get(opts, :tick_interval_ms, :rate),
          tick_steps: nil,
          save_interval: Keyword.get(opts, :save_interval_ms, 30_000),
          next_tick:
            System.monotonic_time(:millisecond) + (Keyword.get(opts, :tick_interval_ms, 50) || 50)
        }

        publish(state)
        {:ok, state |> schedule_tick() |> schedule_save()}

      {:error, reason} ->
        Process.exit(store, :shutdown)
        {:stop, {:clock_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.data, state}

  def handle_call(:flush, _, state) do
    result = ClockStore.flush(state.store, state.data)
    {:reply, result, state}
  end

  def handle_call({:configure, operation}, _, state) do
    case change(state.data, operation) do
      {:ok, data} when data == state.data ->
        {:reply, :ok, state}

      {:ok, data} ->
        next = %{state | data: data, revision: state.revision + 1, dirty: true}
        publish(next)
        {:reply, :ok, next}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:border_command, dimension, operation}, _, state) do
    with %Border{} = border <- Map.get(state.data.borders, dimension, :unknown_dimension),
         {:ok, border, result} <- Border.command(border, operation, state.data.game_time) do
      data = %{state.data | borders: Map.put(state.data.borders, dimension, border)}
      next = %{state | data: data, revision: state.revision + 1, dirty: true}
      publish(next)
      {:reply, {:ok, result}, next}
    else
      :unknown_dimension -> {:reply, {:error, :unknown_dimension}, state}
      error -> {:reply, error, state}
    end
  end

  defp change(data, {:difficulty, level}), do: change(data, {:difficulty, level, false})

  defp change(data, {:difficulty, level, force}) do
    with {:ok, difficulty} <- Difficulty.change(data.difficulty, level, force),
         do: {:ok, %{data | difficulty: difficulty}}
  end

  defp change(data, {:difficulty_locked, locked}) do
    with {:ok, difficulty} <- Difficulty.lock(data.difficulty, locked),
         do: {:ok, %{data | difficulty: difficulty}}
  end

  defp change(data, {:natural_regeneration, value}) when is_boolean(value),
    do: {:ok, %{data | natural_regeneration: value}}

  defp change(data, {:advance_weather, value}) when is_boolean(value),
    do: {:ok, %{data | weather: %{data.weather | advance_weather: value}}}

  defp change(data, {:weather, kind, duration}) do
    with {:ok, weather} <- Weather.configure(data.weather, kind, duration),
         do: {:ok, %{data | weather: weather}}
  end

  defp change(data, {:advance_time, value}) when is_boolean(value),
    do: {:ok, %{data | advance_time: value}}

  defp change(data, {name, operation, value}) when is_map_key(data.clocks, name) do
    clock = data.clocks[name]

    next =
      case operation do
        :ticks when is_integer(value) ->
          ClockState.set_ticks(clock, value)

        :paused when is_boolean(value) ->
          %{clock | paused: value}

        :rate when is_number(value) and value >= 0 and value <= 1024 ->
          %{clock | rate: ClockState.float32(value)}

        _ ->
          nil
      end

    if ClockState.valid?(next),
      do: {:ok, %{data | clocks: Map.put(data.clocks, name, next)}},
      else: {:error, :invalid_clock_change}
  end

  defp change(_, _), do: {:error, :invalid_clock_change}

  @impl true
  def handle_info({:clock_tick, token}, %{tick_timer: {token, timer}} = state) do
    Process.cancel_timer(timer)
    now = System.monotonic_time(:millisecond)

    run =
      if state.tick_interval == :rate,
        do: Valimc.World.TickRate.run?(state.tick_steps),
        else: {true, state.tick_steps}

    cond do
      now < state.next_tick ->
        {:noreply, schedule_tick(%{state | tick_timer: nil})}

      # A frozen game keeps its time; the clock ticks again when stepped or unfrozen.
      not elem(run, 0) ->
        next = %{
          state
          | tick_timer: nil,
            tick_steps: elem(run, 1),
            next_tick: max(state.next_tick + interval(state), now + 1)
        }

        {:noreply, schedule_tick(next)}

      true ->
        tick(%{state | tick_steps: elem(run, 1)}, now)
    end
  end

  def handle_info({:clock_tick, _}, state), do: {:noreply, state}

  def handle_info({:clock_save, token}, %{save_timer: {token, timer}} = state) do
    Process.cancel_timer(timer)
    next = state |> Map.put(:save_timer, nil) |> checkpoint() |> schedule_save()
    {:noreply, next}
  end

  def handle_info({:clock_save, _}, state), do: {:noreply, state}

  def handle_info({:clock_saved, token, :ok}, %{saving: %{token: token} = saving} = state) do
    Process.cancel_timer(saving.timer)
    {:noreply, %{state | saving: nil, dirty: state.revision != saving.revision}}
  end

  def handle_info({:clock_saved, token, error}, %{saving: %{token: token}} = state),
    do: {:stop, {:clock_save_failed, error}, state}

  def handle_info({:clock_saved, _, _}, state), do: {:noreply, state}

  def handle_info({:clock_save_deadline, token}, %{saving: %{token: token}} = state),
    do: {:stop, :clock_save_timeout, state}

  def handle_info({:clock_save_deadline, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, store, reason}, %{store: store} = state),
    do: {:stop, {:clock_store_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  defp checkpoint(%{dirty: true, saving: nil} = state) do
    token = make_ref()
    ClockStore.snapshot(state.store, state.data, self(), token)
    timer = Process.send_after(self(), {:clock_save_deadline, token}, 5000)
    %{state | saving: %{token: token, timer: timer, revision: state.revision}}
  end

  defp checkpoint(state), do: state

  defp publish(state, changed \\ true) do
    latest = Packets.time(state.data)

    {version, periodic} =
      if changed do
        {make_ref(), latest}
      else
        [{:network, version, periodic, _}] = :ets.lookup(state.table, :network)
        {version, periodic}
      end

    previous =
      case :ets.lookup(state.table, :weather) do
        [{:weather, view}] -> view
        [] -> nil
      end

    view = WeatherReplication.cache(state.data.weather, previous)

    previous_difficulty =
      case :ets.lookup(state.table, :difficulty) do
        [{:difficulty, cached}] -> cached
        [] -> nil
      end

    difficulty = Difficulty.cache(state.data.difficulty, previous_difficulty)

    borders =
      for {dimension, border} <- state.data.borders,
          do: {{:border, dimension}, border, Border.physics(border)}

    :ets.insert(state.table, [
      {:network, version, periodic, latest},
      {:weather, view},
      {:difficulty, difficulty},
      {:survival, {state.data.difficulty.level, state.data.natural_regeneration}}
      | borders
    ])
  end

  defp interval(%{tick_interval: :rate}), do: Valimc.World.TickRate.interval()
  defp interval(state), do: state.tick_interval

  defp tick(state, now) do
    if state.tick_interval == :rate, do: Valimc.World.TickRate.clock_ticked()
    data = ClockRecord.tick(state.data)
    count = state.sync_ticks + 1

    next = %{
      state
      | data: data,
        revision: state.revision + 1,
        dirty: true,
        sync_ticks: rem(count, 20),
        tick_timer: nil,
        next_tick: max(state.next_tick + interval(state), now + 1)
    }

    publish(next, count == 20)
    {:noreply, schedule_tick(next)}
  end

  defp schedule_tick(%{tick_interval: nil} = state), do: state

  defp schedule_tick(state) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:clock_tick, token},
        max(ceil(state.next_tick - System.monotonic_time(:millisecond)), 1)
      )

    %{state | tick_timer: {token, timer}}
  end

  defp schedule_save(%{save_interval: nil} = state), do: state

  defp schedule_save(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:clock_save, token}, state.save_interval)
    %{state | save_timer: {token, timer}}
  end

  @impl true
  def terminate(reason, state) do
    for timer <- [state.tick_timer, state.save_timer],
        timer != nil,
        do: Process.cancel_timer(elem(timer, 1))

    if state.saving, do: Process.cancel_timer(state.saving.timer)

    if Process.alive?(state.store) do
      if reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason) do
        case ClockStore.flush(state.store, state.data) do
          :ok ->
            :ok

          error ->
            require Logger
            Logger.error("Clock shutdown save failed: #{inspect(error)}")
        end
      end

      monitor = Process.monitor(state.store)
      Process.exit(state.store, :shutdown)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        5000 ->
          Process.exit(state.store, :kill)

          receive do
            {:DOWN, ^monitor, :process, _, _} -> :ok
          end
      end
    end
  end
end
