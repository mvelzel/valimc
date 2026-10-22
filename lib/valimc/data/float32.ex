defmodule Valimc.Data.Float32 do
  @moduledoc """
  Java's `float` (VMC-077r): a number rounded to the nearest 32-bit float, as
  vanilla's `(float)` casts and float arithmetic round. Erlang has no
  infinite floats: `round/1` raises past the float range, `round_or_infinity/1`
  gives `:infinity` or `:neg_infinity` there, as Java's float parsing does.
  """

  @doc "`(float) value`."
  def round(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  @doc "`(float) value`, or `:infinity` / `:neg_infinity` past the float range."
  def round_or_infinity(:infinity), do: :infinity
  def round_or_infinity(:neg_infinity), do: :neg_infinity

  def round_or_infinity(value) do
    case <<value::float-32>> do
      <<_sign::1, 0xFF::8, _::23>> -> if value > 0, do: :infinity, else: :neg_infinity
      <<f::float-32>> -> f
    end
  rescue
    ArgumentError -> if value > 0, do: :infinity, else: :neg_infinity
  end
end
