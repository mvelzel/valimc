defmodule Valimc.Commands.WorldBorder do
  @moduledoc """
  `/worldborder` (VMC-027c), vanilla's `WorldBorderCommand`: `add`, `set`,
  `center`, `damage amount`, `damage buffer`, `get`, `warning distance` and
  `warning time` on the source's dimension border (the overworld in this
  preview). Each change runs atomically in the border owner
  (`Valimc.World.Clock.border_command/2`); feedback and return values follow
  vanilla, numbers formatted as `String.format(Locale.ROOT, ...)` does.
  """
  alias Valimc.Command.{Error, Feedback}
  alias Valimc.Text
  alias Valimc.Text.Number
  alias Valimc.World.{Border, Clock}

  @doc "`/worldborder …`, its form named by the parsed literals (`kind/1`)."
  def worldborder(arguments, source) do
    case kind(arguments.literals) do
      :get ->
        {component, result} = query(Clock.border(Valimc.Dimension.name(source.dimension)))
        Feedback.success(source, component, false)
        result

      kind ->
        change(kind, arguments, source)
    end
  end

  @doc "The form of a parsed `/worldborder`: `:get`, `:add`, `:set`, `:center`, …"
  def kind(["damage", "amount"]), do: :damage_amount
  def kind(["damage", "buffer"]), do: :damage_buffer
  def kind(["warning", "distance"]), do: :warning_distance
  def kind(["warning", "time"]), do: :warning_time
  def kind([form]) when form in ~w(get add set center), do: String.to_existing_atom(form)

  defp change(kind, arguments, source) do
    operation = operation(kind, arguments, source.position)

    case Clock.border_command(operation, Valimc.Dimension.name(source.dimension)) do
      {:ok, outcome} ->
        {component, result} = success(operation, outcome)
        Feedback.success(source, component)
        result

      {:error, reason} ->
        Error.throw!(%Error{message: failure(reason)})
    end
  end

  @doc """
  The border operation for a handler's parsed arguments at a source position:
  distances are doubles, damage values floats, a centre a float pair (`Vec2`).
  """
  def operation(:add, arguments, _), do: {:add, arguments["distance"], arguments["time"]}
  def operation(:set, arguments, _), do: {:set, arguments["distance"], ticks(arguments)}

  def operation(:center, %{"pos" => {:world, [x, z]}}, {sx, _, sz}),
    do: {:center, float32(coordinate(x, sx)), float32(coordinate(z, sz))}

  def operation(:damage_amount, arguments, _),
    do: {:damage_amount, arguments["damagePerBlock"]}

  def operation(:damage_buffer, arguments, _), do: {:damage_buffer, arguments["distance"]}
  def operation(:warning_distance, arguments, _), do: {:warning_distance, arguments["distance"]}
  def operation(:warning_time, arguments, _), do: {:warning_time, arguments["time"]}

  defp ticks(arguments), do: Map.get(arguments, "time", 0)

  defp coordinate({true, value}, origin), do: value + origin
  defp coordinate({false, value}, _origin), do: value

  @doc "`/worldborder get`: the size rounded to a whole number and `floor(size + 0.5)`."
  def query(border) do
    size = Border.size(border)

    {Text.translatable("commands.worldborder.get", [Number.fixed(size, 0)]),
     java_int(Float.floor(size + 0.5))}
  end

  @doc "Feedback and return value of a successful change."
  def success({kind, _, _}, {current, distance, ticks}) when kind in [:add, :set] do
    formatted = Number.fixed(distance, 1)

    component =
      cond do
        ticks <= 0 ->
          Text.translatable("commands.worldborder.set.immediate", [formatted])

        distance > current ->
          Text.translatable("commands.worldborder.set.grow", [formatted, seconds(ticks)])

        true ->
          Text.translatable("commands.worldborder.set.shrink", [formatted, seconds(ticks)])
      end

    {component, java_int(distance - current)}
  end

  def success({:center, x, z}, _),
    do:
      {Text.translatable("commands.worldborder.center.success", [
         Number.fixed(x, 2),
         Number.fixed(z, 2)
       ]), 0}

  def success({:damage_amount, value}, _),
    do:
      {Text.translatable("commands.worldborder.damage.amount.success", [Number.fixed(value, 2)]),
       java_int(value)}

  def success({:damage_buffer, value}, _),
    do:
      {Text.translatable("commands.worldborder.damage.buffer.success", [Number.fixed(value, 2)]),
       java_int(value)}

  def success({:warning_time, ticks}, _),
    do: {Text.translatable("commands.worldborder.warning.time.success", [seconds(ticks)]), ticks}

  def success({:warning_distance, blocks}, _),
    do: {Text.translatable("commands.worldborder.warning.distance.success", [blocks]), blocks}

  @doc "The failure message of a refused change."
  def failure(:same_center), do: Text.translatable("commands.worldborder.center.failed")
  def failure(:same_size), do: Text.translatable("commands.worldborder.set.failed.nochange")
  def failure(:too_small), do: Text.translatable("commands.worldborder.set.failed.small")

  def failure(:too_big),
    do: Text.translatable("commands.worldborder.set.failed.big", [{:float, Border.max_size()}])

  def failure(:too_far_out),
    do: Text.translatable("commands.worldborder.set.failed.far", [{:double, Border.max_center()}])

  def failure(:same_warning_time),
    do: Text.translatable("commands.worldborder.warning.time.failed")

  def failure(:same_warning_distance),
    do: Text.translatable("commands.worldborder.warning.distance.failed")

  def failure(:same_damage_buffer),
    do: Text.translatable("commands.worldborder.damage.buffer.failed")

  def failure(:same_damage_amount),
    do: Text.translatable("commands.worldborder.damage.amount.failed")

  defp seconds(ticks), do: Number.fixed(ticks / 20.0, 2)

  defp float32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  # `(int)` of a double: saturating, towards zero.
  defp java_int(value) when value >= 2_147_483_647, do: 2_147_483_647
  defp java_int(value) when value <= -2_147_483_648, do: -2_147_483_648
  defp java_int(value), do: trunc(value)
end
