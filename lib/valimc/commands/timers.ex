defmodule Valimc.Commands.Timers do
  @moduledoc "`/stopwatch` and `/tick` (VMC-053j) over `Valimc.World.Stopwatches` and `Valimc.World.TickRate`."
  alias Valimc.Command.{Error, Feedback}
  alias Valimc.Text
  alias Valimc.World.Stopwatches

  @doc "Stopwatch ids for `/stopwatch query|restart|remove`."
  def suggest(["stopwatch" | _], _arguments, _source), do: {:resources, Stopwatches.ids()}

  @doc "`/stopwatch create|query|restart|remove <id>`."
  def stopwatch(%{literals: [mode]} = arguments, source) do
    case mode do
      "create" -> stopwatch_create(arguments, source)
      "query" -> stopwatch_query(arguments, source)
      "restart" -> stopwatch_restart(arguments, source)
      "remove" -> stopwatch_remove(arguments, source)
    end
  end

  defp stopwatch_create(%{"id" => id}, source) do
    if Stopwatches.create(id) == :exists,
      do: Error.fail!("commands.stopwatch.already_exists", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.create.success", [id]))
    1
  end

  defp stopwatch_query(%{"id" => id} = arguments, source) do
    ms = Stopwatches.elapsed(id) || Error.fail!("commands.stopwatch.does_not_exist", [id])
    seconds = ms / 1000.0

    Feedback.success(
      source,
      Text.translatable("commands.stopwatch.query", [id, {:double, seconds}])
    )

    java_int(seconds * Map.get(arguments, "scale", 1.0))
  end

  defp stopwatch_restart(%{"id" => id}, source) do
    if Stopwatches.restart(id) == :missing,
      do: Error.fail!("commands.stopwatch.does_not_exist", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.restart.success", [id]))
    1
  end

  defp stopwatch_remove(%{"id" => id}, source) do
    if Stopwatches.remove(id) == :missing,
      do: Error.fail!("commands.stopwatch.does_not_exist", [id])

    Feedback.success(source, Text.translatable("commands.stopwatch.remove.success", [id]))
    1
  end

  # Java `(int) double`: truncate, saturate.
  defp java_int(value), do: value |> trunc() |> max(-2_147_483_648) |> min(2_147_483_647)

  # ---- tick ----

  alias Valimc.World.TickRate

  defp f1(value), do: Valimc.Text.Number.fixed(value * 1.0, 1)
  defp ms(nanoseconds), do: f1(Valimc.Command.Reader.to_float32(nanoseconds / 1.0e6))

  @doc "`/tick query|rate|freeze|unfreeze|step [stop]|sprint [stop]`."
  def tick(%{literals: literals} = arguments, source) do
    case literals do
      ["query"] -> tick_query(source)
      ["rate"] -> tick_rate(arguments, source)
      ["freeze"] -> tick_freeze(source)
      ["unfreeze"] -> tick_unfreeze(source)
      ["step"] -> tick_step(arguments, source)
      ["step", "stop"] -> tick_step_stop(source)
      ["sprint"] -> tick_sprint(arguments, source)
      ["sprint", "stop"] -> tick_sprint_stop(source)
    end
  end

  # `/tick query`: status, target rate, average tick time and percentiles.
  defp tick_query(source) do
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
    trunc(state.rate)
  end

  defp tick_rate(%{"rate" => rate}, source) do
    TickRate.set_rate(rate)
    Feedback.success(source, Text.translatable("commands.tick.rate.success", [f1(rate)]))
    trunc(rate)
  end

  defp tick_freeze(source) do
    TickRate.freeze()
    Feedback.success(source, Text.translatable("commands.tick.status.frozen"))
    1
  end

  defp tick_unfreeze(source) do
    TickRate.unfreeze()
    Feedback.success(source, Text.translatable("commands.tick.status.running"))
    0
  end

  defp tick_step(arguments, source) do
    ticks = Map.get(arguments, "time", 1)
    if TickRate.step(ticks) == :not_frozen, do: Error.fail!("commands.tick.step.fail")
    Feedback.success(source, Text.translatable("commands.tick.step.success", [ticks]))
    1
  end

  defp tick_step_stop(source) do
    if TickRate.stop_step() == :none, do: Error.fail!("commands.tick.step.stop.fail")
    Feedback.success(source, Text.translatable("commands.tick.step.stop.success"))
    1
  end

  defp tick_sprint(%{"time" => ticks}, source) do
    {:ok, interrupted} = TickRate.sprint(ticks)

    if interrupted,
      do: Feedback.success(source, Text.translatable("commands.tick.sprint.stop.success"))

    Feedback.success(source, Text.translatable("commands.tick.status.sprinting"))
    1
  end

  defp tick_sprint_stop(source) do
    if TickRate.stop_sprint() == :none, do: Error.fail!("commands.tick.sprint.stop.fail")
    Feedback.success(source, Text.translatable("commands.tick.sprint.stop.success"))
    1
  end
end
