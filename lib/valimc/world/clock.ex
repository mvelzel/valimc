defmodule Valimc.World.Clock do
  use GenServer
  alias Valimc.Protocol.Packets
  alias Valimc.World.{ClockRecord, ClockState, ClockStore}

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
          tick_interval: Keyword.get(opts, :tick_interval_ms, 50),
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
      {:ok, data} ->
        next = %{state | data: data, revision: state.revision + 1, dirty: true}
        publish(next)
        {:reply, :ok, next}

      error ->
        {:reply, error, state}
    end
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

    if now < state.next_tick do
      {:noreply, schedule_tick(%{state | tick_timer: nil})}
    else
      data = ClockRecord.tick(state.data)
      count = state.sync_ticks + 1

      next = %{
        state
        | data: data,
          revision: state.revision + 1,
          dirty: true,
          sync_ticks: rem(count, 20),
          tick_timer: nil,
          next_tick: max(state.next_tick + state.tick_interval, now + 1)
      }

      publish(next, count == 20)
      {:noreply, schedule_tick(next)}
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

    :ets.insert(state.table, {:network, version, periodic, latest})
  end

  defp schedule_tick(%{tick_interval: nil} = state), do: state

  defp schedule_tick(state) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:clock_tick, token},
        max(state.next_tick - System.monotonic_time(:millisecond), 1)
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
