defmodule Valimc.World.TickRate do
  @moduledoc """
  The server tick rate (VMC-053j), vanilla's `ServerTickRateManager`: target
  rate, frozen game, frozen-tick steps and sprints.

  The owner publishes `{interval, frozen, step generation and budget,
  sprinting}` in `:persistent_term`; tick clocks (regions, the world clock and
  player connections) read the interval, and region owners and the world clock
  run their game ticks only when the game is not frozen or a step allows it.
  Each owner counts its own steps of the current step generation. The world
  clock is the reference for step and sprint progress: it reports its ticks, so
  `step stop` and the sprint report follow vanilla. Region tick durations feed a
  100-sample ring for `/tick query`.
  """
  use GenServer
  require Logger
  alias Valimc.Text
  alias Valimc.Protocol.{Packets, Wire}

  @key {__MODULE__, :published}
  @default %{rate: 20.0, interval: 50.0, frozen: false, step: {0, 0}, sprinting: false}
  @samples 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The published state; the default when the owner is not running (tests)."
  def published, do: :persistent_term.get(@key, @default)

  @doc "Milliseconds per tick: 0 while sprinting."
  def interval do
    published = published()
    if published.sprinting, do: 0.0, else: published.interval
  end

  @doc """
  Whether an owner may run game elements this tick, and its new step usage:
  `run?(used)` with `used = {generation, count}` from the owner's last call.
  """
  def run?({generation, used}) do
    %{frozen: frozen, step: {current, budget}} = published()

    used = if generation == current, do: used, else: 0

    cond do
      not frozen -> {true, {current, used}}
      used < budget -> {true, {current, used + 1}}
      true -> {false, {current, used}}
    end
  end

  def run?(_), do: run?({-1, 0})

  @doc "Records a region tick's duration (nanoseconds) for `/tick query`."
  def sample(nanoseconds, late \\ 0) do
    Valimc.Data.ProfileTicks.record(nanoseconds, late)

    case :ets.whereis(__MODULE__) do
      :undefined ->
        :ok

      table ->
        slot = :ets.update_counter(table, :slot, {2, 1, @samples - 1, 0}, {:slot, -1})
        :ets.insert(table, {{:sample, slot}, nanoseconds})
        :ets.update_counter(table, :count, {2, 1}, {:count, 0})
        :ok
    end
  end

  @doc "The 100 sample slots (unused ones 0) and how many ticks were measured."
  def samples do
    case :ets.whereis(__MODULE__) do
      :undefined ->
        {List.duplicate(0, @samples), 0}

      table ->
        slots = for i <- 0..(@samples - 1), do: sample_value(table, i)

        count =
          case :ets.lookup(table, :count) do
            [{:count, count}] -> count
            [] -> 0
          end

        {slots, count}
    end
  end

  defp sample_value(table, i) do
    case :ets.lookup(table, {:sample, i}) do
      [{_, value}] -> value
      [] -> 0
    end
  end

  def state, do: GenServer.call(__MODULE__, :state)
  def set_rate(rate), do: GenServer.call(__MODULE__, {:rate, rate})
  def freeze, do: GenServer.call(__MODULE__, :freeze)
  def unfreeze, do: GenServer.call(__MODULE__, :unfreeze)
  def step(ticks), do: GenServer.call(__MODULE__, {:step, ticks})
  def stop_step, do: GenServer.call(__MODULE__, :stop_step)
  def sprint(ticks), do: GenServer.call(__MODULE__, {:sprint, ticks})
  def stop_sprint, do: GenServer.call(__MODULE__, :stop_sprint)

  @doc "The world clock ran one game tick: step and sprint progress."
  def clock_ticked do
    Valimc.Data.Metrics.add(:clock_ticks)
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :clock_ticked)
    :ok
  end

  @doc "The step count a joining player gets with the ticking state."
  def join_steps do
    published = published()
    {_, budget} = published.step
    if published.frozen, do: budget, else: 0
  end

  def state_packet(published),
    do:
      Packets.packet(
        "ticking_state",
        <<published.rate::float-32, if(published.frozen, do: 1, else: 0)>>
      )

  def step_packet(steps), do: Packets.packet("ticking_step", Wire.varint(steps))

  # ---- owner ----

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    state = %{rate: 20.0, frozen: false, generation: 0, budget: 0, remaining: 0, sprint: nil}
    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:rate, rate}, _from, state),
    do: {:reply, :ok, state |> Map.put(:rate, rate) |> publish() |> broadcast_state()}

  def handle_call(:freeze, _from, state) do
    state = if state.sprint, do: finish_sprint(state), else: state

    state =
      if state.remaining > 0,
        do:
          %{state | remaining: 0, budget: 0, generation: state.generation + 1}
          |> broadcast(step_packet(0)),
        else: state

    {:reply, :ok, %{state | frozen: true} |> publish() |> broadcast_state()}
  end

  def handle_call(:unfreeze, _from, state),
    do: {:reply, :ok, %{state | frozen: false} |> publish() |> broadcast_state()}

  def handle_call({:step, _ticks}, _from, %{frozen: false} = state),
    do: {:reply, :not_frozen, state}

  def handle_call({:step, ticks}, _from, state) do
    state = %{state | remaining: ticks, budget: ticks, generation: state.generation + 1}
    {:reply, :ok, state |> publish() |> broadcast(step_packet(ticks))}
  end

  def handle_call(:stop_step, _from, %{remaining: 0} = state), do: {:reply, :none, state}

  def handle_call(:stop_step, _from, state) do
    state = %{state | remaining: 0, budget: 0, generation: state.generation + 1}
    {:reply, :ok, state |> publish() |> broadcast(step_packet(0))}
  end

  def handle_call({:sprint, ticks}, _from, state) do
    interrupted = state.sprint != nil
    previous = if interrupted, do: state.sprint.previous_frozen, else: state.frozen
    # Sprint ticks run back to back, so their work time is the wall time.
    sprint = %{
      scheduled: ticks,
      remaining: ticks,
      started: System.monotonic_time(:nanosecond),
      previous_frozen: previous
    }

    state = %{state | sprint: sprint, frozen: false} |> publish() |> broadcast_state()
    {:reply, {:ok, interrupted}, state}
  end

  def handle_call(:stop_sprint, _from, %{sprint: nil} = state), do: {:reply, :none, state}
  def handle_call(:stop_sprint, _from, state), do: {:reply, :ok, finish_sprint(state)}

  @impl true
  def handle_cast(:clock_ticked, state) do
    state =
      if state.frozen and state.remaining > 0,
        do: %{state | remaining: state.remaining - 1},
        else: state

    state =
      case state.sprint do
        nil ->
          state

        %{remaining: remaining} = sprint when remaining > 1 ->
          %{state | sprint: %{sprint | remaining: remaining - 1}}

        sprint ->
          finish_sprint(%{state | sprint: %{sprint | remaining: 0}})
      end

    {:noreply, state}
  end

  # `finishTickSprint`: the report comes from the server console to operators.
  defp finish_sprint(%{sprint: sprint} = state) do
    done = sprint.scheduled - sprint.remaining
    ms = max(1.0, (System.monotonic_time(:nanosecond) - sprint.started) * 1.0) / 1.0e6
    tps = trunc(1000 * done / ms)
    mspt = if done == 0, do: 1000.0 / state.rate, else: ms / done

    report =
      Text.translatable("commands.tick.sprint.report", [
        tps,
        Valimc.Text.Number.fixed(mspt, 2)
      ])

    console(report)
    %{state | sprint: nil, frozen: sprint.previous_frozen} |> publish() |> broadcast_state()
  end

  defp publish(state) do
    :persistent_term.put(@key, %{
      rate: state.rate,
      interval: 1000.0 / state.rate,
      frozen: state.frozen,
      step: {state.generation, state.budget},
      sprinting: state.sprint != nil
    })

    state
  end

  defp broadcast_state(state), do: broadcast(state, state_packet(published()))

  defp broadcast(state, packet) do
    Valimc.Player.PlayerList.broadcast({:packet, packet})
    state
  end

  # The sprint report comes from the server's command source: logged, and
  # shown to operators as `[Server: ...]` while `sendCommandFeedback` is on.
  defp console(component) do
    Logger.info("[Server] " <> Valimc.Text.Render.string(component))

    if Valimc.World.GameRules.get(:send_command_feedback) do
      message =
        Text.translatable("chat.type.admin", [Text.literal("Server"), component])
        |> Text.style([{"color", "gray"}, {"italic", true}])

      for player <- Valimc.Player.PlayerList.all(),
          Valimc.Admin.Permissions.operator?(player),
          do: Valimc.Player.PlayerList.deliver(player.pid, {:chat, Text.encode(message)})
    end

    :ok
  end
end
