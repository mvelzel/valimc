defmodule Valimc.Commands.Timers do
  @moduledoc "`/stopwatch` and `/tick` (VMC-053j) over `Valimc.World.Stopwatches` and `Valimc.World.TickRate`."
  alias Valimc.Command.{Error, Feedback, Text}
  alias Valimc.World.Stopwatches

  def stopwatch_create(%{"id" => id}, source) do
    if Stopwatches.create(id) == :exists,
      do: Error.fail!("commands.stopwatch.already_exists", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.create.success", [id]))
    {1, source.state}
  end

  def stopwatch_query(%{"id" => id} = arguments, source) do
    ms = Stopwatches.elapsed(id) || Error.fail!("commands.stopwatch.does_not_exist", [id])
    seconds = ms / 1000.0

    Feedback.success(
      source,
      Text.translatable("commands.stopwatch.query", [id, {:double, seconds}])
    )

    {java_int(seconds * Map.get(arguments, "scale", 1.0)), source.state}
  end

  def stopwatch_restart(%{"id" => id}, source) do
    if Stopwatches.restart(id) == :missing,
      do: Error.fail!("commands.stopwatch.does_not_exist", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.restart.success", [id]))
    {1, source.state}
  end

  def stopwatch_remove(%{"id" => id}, source) do
    if Stopwatches.remove(id) == :missing,
      do: Error.fail!("commands.stopwatch.does_not_exist", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.remove.success", [id]))
    {1, source.state}
  end

  # Java `(int) double`: truncate, saturate.
  defp java_int(value), do: value |> trunc() |> max(-2_147_483_648) |> min(2_147_483_647)

  # ---- tick ----

  alias Valimc.World.TickRate

  defp f1(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
  defp ms(nanoseconds), do: f1(Valimc.Command.Reader.to_float32(nanoseconds / 1.0e6))

  @doc "`/tick query`: status, target rate, average tick time and percentiles."
  def tick_query(_arguments, source) do
    state = TickRate.state()
    {samples, count} = TickRate.samples()
    average = Enum.sum(samples) / min(100, max(count, 1))
    busy = ms(average)
    rate = f1(state.rate)
    target = trunc(1.0e9 / state.rate)

    lines =
      if state.sprint do
        [
          Text.translatable("commands.tick.status.sprinting"),
          Text.translatable("commands.tick.query.rate.sprinting", [rate, busy])
        ]
      else
        status =
          cond do
            state.frozen -> "commands.tick.status.frozen"
            target < average -> "commands.tick.status.lagging"
            true -> "commands.tick.status.running"
          end

        [
          Text.translatable(status),
          Text.translatable("commands.tick.query.rate.running", [rate, busy, ms(target)])
        ]
      end

    sorted = Enum.sort(samples)

    percentiles =
      Text.translatable("commands.tick.query.percentiles", [
        ms(Enum.at(sorted, 50)),
        ms(Enum.at(sorted, 95)),
        ms(Enum.at(sorted, 99)),
        100
      ])

    for line <- lines ++ [percentiles], do: Feedback.success(source, line, false)
    {trunc(state.rate), source.state}
  end

  def tick_rate(%{"rate" => rate}, source) do
    TickRate.set_rate(rate)
    Feedback.success(source, Text.translatable("commands.tick.rate.success", [f1(rate)]))
    {trunc(rate), source.state}
  end

  def tick_freeze(_arguments, source) do
    TickRate.freeze()
    Feedback.success(source, Text.translatable("commands.tick.status.frozen"))
    {1, source.state}
  end

  def tick_unfreeze(_arguments, source) do
    TickRate.unfreeze()
    Feedback.success(source, Text.translatable("commands.tick.status.running"))
    {0, source.state}
  end

  def tick_step(arguments, source) do
    ticks = Map.get(arguments, "time", 1)
    if TickRate.step(ticks) == :not_frozen, do: Error.fail!("commands.tick.step.fail")
    Feedback.success(source, Text.translatable("commands.tick.step.success", [ticks]))
    {1, source.state}
  end

  def tick_step_stop(_arguments, source) do
    if TickRate.stop_step() == :none, do: Error.fail!("commands.tick.step.stop.fail")
    Feedback.success(source, Text.translatable("commands.tick.step.stop.success"))
    {1, source.state}
  end

  def tick_sprint(%{"time" => ticks}, source) do
    {:ok, interrupted} = TickRate.sprint(ticks)

    if interrupted,
      do: Feedback.success(source, Text.translatable("commands.tick.sprint.stop.success"))

    Feedback.success(source, Text.translatable("commands.tick.status.sprinting"))
    {1, source.state}
  end

  def tick_sprint_stop(_arguments, source) do
    if TickRate.stop_sprint() == :none, do: Error.fail!("commands.tick.sprint.stop.fail")
    Feedback.success(source, Text.translatable("commands.tick.sprint.stop.success"))
    {1, source.state}
  end
end
