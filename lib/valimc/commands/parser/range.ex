defmodule Valimc.Commands.Parser.Range do
  @moduledoc "Vanilla `MinMaxBounds` ranges (`1`, `1..`, `..5`, `1..5`) for selector options (VMC-053)."
  alias Valimc.Text.{Error, Reader}

  defstruct [:min, :max]

  def ints(reader), do: read(reader, :int)
  def doubles(reader), do: read(reader, :double)
  def floats(reader), do: read(reader, :float)

  defp read(reader, type) do
    unless Reader.can_read?(reader), do: Error.fail_at!("argument.range.empty", [], reader)
    start = reader.cursor

    {range, reader} =
      try do
        {min, reader} = number(reader, type)

        {max, reader} =
          if Reader.can_read?(reader, 2) and Reader.peek(reader) == ?. and
               Reader.peek(reader, 1) == ?.,
             do: number(reader |> Reader.skip() |> Reader.skip(), type),
             else: {min, reader}

        if min == nil and max == nil, do: Error.fail_at!("argument.range.empty", [], reader)
        {%__MODULE__{min: min, max: max}, reader}
      catch
        {:command_syntax, error} -> Error.throw!(%{error | cursor: start})
      end

    if type != :float and range.min != nil and range.max != nil and
         compare(range.min, range.max) == :gt,
       do: Error.fail_at!("argument.range.swapped", [], Reader.set_cursor(reader, start)),
       else: {range, reader}
  end

  defp number(reader, type) do
    {text, reader} = take(reader, reader.cursor)

    cond do
      text == "" ->
        {nil, reader}

      true ->
        case Reader.parse_number(text, type) do
          {:ok, value} -> {value, reader}
          :error -> Error.fail_at!("parsing.#{type}.invalid", [text], reader)
        end
    end
  end

  defp take(reader, start) do
    if Reader.can_read?(reader) and allowed?(reader),
      do: take(Reader.skip(reader), start),
      else: {Reader.slice(reader, start, reader.cursor), reader}
  end

  defp allowed?(reader) do
    c = Reader.peek(reader)

    cond do
      c in ?0..?9 or c == ?- -> true
      c == ?. -> not Reader.can_read?(reader, 2) or Reader.peek(reader, 1) != ?.
      true -> false
    end
  end

  defp compare(a, b) do
    a = order(a)
    b = order(b)
    if a > b, do: :gt, else: :le
  end

  defp order(:infinity), do: {1, 0}
  defp order(:neg_infinity), do: {-1, 0}
  defp order(value), do: {0, value}

  def below_zero?(:neg_infinity), do: true
  def below_zero?(:infinity), do: false
  def below_zero?(value), do: value < 0

  def matches?(%__MODULE__{min: min, max: max}, value),
    do: (min == nil or order(min) <= order(value)) and (max == nil or order(value) <= order(max))

  @doc "Distance ranges compare squared distances against squared bounds."
  def matches_squared?(%__MODULE__{min: min, max: max}, squared),
    do:
      (min == nil or below?(min, squared)) and (max in [nil, :infinity] or squared <= square(max))

  defp below?(:infinity, _squared), do: false
  defp below?(bound, squared), do: square(bound) <= squared

  defp square(value), do: value * value

  @doc "`createRotationPredicate`: wrapped degrees, with ranges that cross 180."
  def rotation?(%__MODULE__{min: min, max: max}, rotation) do
    min = wrap(finite(min) || 0.0)
    max = wrap(finite(max) || 359.0)
    rotation = wrap(rotation)

    if min > max,
      do: rotation >= min or rotation <= max,
      else: rotation >= min and rotation <= max
  end

  defp finite(value) when value in [:infinity, :neg_infinity], do: 0.0
  defp finite(value), do: value

  defp wrap(degrees) do
    degrees = :math.fmod(degrees * 1.0, 360.0)
    degrees = if degrees >= 180.0, do: degrees - 360.0, else: degrees
    if degrees < -180.0, do: degrees + 360.0, else: degrees
  end
end
