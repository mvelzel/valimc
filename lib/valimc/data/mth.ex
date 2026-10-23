defmodule Valimc.Data.Mth do
  @moduledoc "Vanilla's `Mth` trigonometry: the 65,536-entry float sine table."
  import Bitwise
  alias Valimc.Data.Float32

  @radians 10_430.378350470453

  @doc "`Mth.sin` of `value` radians."
  def sin(value), do: table(trunc(value * @radians))

  @doc "`Mth.cos` of `value` radians."
  def cos(value), do: table(trunc(value * @radians + 16_384.0))

  defp table(index), do: Float32.round(:math.sin(band(index, 65_535) / @radians))
end
