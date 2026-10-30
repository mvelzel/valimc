defmodule Valimc.Data.Mth do
  @moduledoc """
  Vanilla's `Mth` arithmetic as it rounds: the 65,536-entry float sine
  table, `atan2` from vanilla's own tables (`Valimc.Data.AiFacts`) and
  `wrapDegrees`.
  """
  import Bitwise
  alias Valimc.Data.Float32

  @radians 10_430.378350470453

  @doc "`Mth.sin` of `value` radians."
  def sin(value), do: table(trunc(value * @radians))

  @doc "`Mth.cos` of `value` radians."
  def cos(value), do: table(trunc(value * @radians + 16_384.0))

  defp table(index), do: Float32.round(:math.sin(band(index, 65_535) / @radians))

  @asin Valimc.Data.AiFacts.atan2_table(:asin)
  @cos Valimc.Data.AiFacts.atan2_table(:cos)
  @frac_bias 1.7592186044416e13

  @doc "`Mth.atan2(y, x)`: a table lookup and one correction term."
  def atan2(y, x) do
    d2 = x * x + y * y
    {y, neg_y} = if y < 0.0, do: {-y, true}, else: {y, false}
    {x, neg_x} = if x < 0.0, do: {-x, true}, else: {x, false}
    {x, y, steep} = if y > x, do: {y, x, true}, else: {x, y, false}
    rinv = fast_inv_sqrt(d2)
    x = x * rinv
    y = y * rinv
    yp = @frac_bias + y
    <<bits::64>> = <<yp::float-64>>
    index = bits &&& 0xFFFFFFFF
    phi = elem(@asin, index)
    c_phi = elem(@cos, index)
    s_phi = yp - @frac_bias
    sd = y * c_phi - x * s_phi
    d = (6.0 + sd * sd) * sd * 0.16666666666666666
    theta = phi + d
    theta = if steep, do: :math.pi() / 2 - theta, else: theta
    theta = if neg_x, do: :math.pi() - theta, else: theta
    if neg_y, do: -theta, else: theta
  end

  defp fast_inv_sqrt(x) do
    half = 0.5 * x
    <<i::signed-64>> = <<x::float-64>>
    i = 6_910_469_410_427_058_090 - (i >>> 1)
    <<x::float-64>> = <<i::signed-64>>
    x * (1.5 - half * x * x)
  end

  @doc "`Mth.wrapDegrees` of a float."
  def wrap(angle) do
    a = :math.fmod(angle, 360.0)
    a = if a >= 180.0, do: Float32.round(a - 360.0), else: a
    if a < -180.0, do: Float32.round(a + 360.0), else: a
  end
end
