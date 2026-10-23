defmodule Valimc.AI.Mth do
  @moduledoc """
  The `Mth` and `Control` arithmetic the AI turns heads and bodies with, as
  vanilla rounds it: `atan2` from vanilla's own tables (`MobAiOracle
  facts`), and the float angle helpers (`wrapDegrees`, `degreesDifference`,
  `rotateIfNecessary`, `approach`, `rotateTowards`), each float operation
  rounded as Java's.
  """
  import Bitwise
  alias Valimc.AI.Facts
  alias Valimc.Data.Float32

  @frac_bias 1.7592186044416e13
  @asin Facts.atan2_table(:asin)
  @cos Facts.atan2_table(:cos)

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

  @doc """
  The yaw that faces `{dx, dz}`: `(float)(atan2(dz, dx) * 180 / PI) - 90`
  (javac folds `180.0F / (float)Math.PI` into one double).
  """
  def yaw(dx, dz), do: f(f(atan2(dz, dx) * 57.2957763671875) - 90.0)

  @doc "The pitch that faces `dy` over horizontal distance `sd`."
  def pitch(dy, sd), do: f(-(atan2(dy, sd) * 57.2957763671875))

  @doc "`Mth.wrapDegrees` of a float."
  def wrap(angle) do
    a = :math.fmod(angle, 360.0)
    a = if a >= 180.0, do: f(a - 360.0), else: a
    if a < -180.0, do: f(a + 360.0), else: a
  end

  @doc "`Mth.degreesDifference(from, to)`."
  def difference(from, to), do: wrap(f(to - from))

  @doc "`Mth.clamp` of floats."
  def clamp(value, min, _max) when value < min, do: min
  def clamp(value, _min, max), do: min(value, max)

  @doc "`Mth.rotateIfNecessary(base, target, max)`."
  def rotate_if_necessary(base, target, max),
    do: f(target - clamp(difference(base, target), -max, max))

  @doc "`Control.rotateTowards(from, to, max)`."
  def rotate_towards(from, to, max), do: f(from + clamp(difference(from, to), -max, max))

  @doc "`Mth.approach(current, target, increment)`."
  def approach(current, target, increment) do
    increment = abs(increment)

    if current < target,
      do: clamp(f(current + increment), current, target),
      else: clamp(f(current - increment), target, current)
  end

  @doc "`Mth.approachDegrees(current, target, increment)`."
  def approach_degrees(current, target, increment),
    do: approach(current, f(current + difference(current, target)), increment)

  @doc "`Mth.positiveCeilDiv`, as `Goal.reducedTickDelay` halves a delay."
  def ceil_div(input, divisor), do: -Integer.floor_div(-input, divisor)

  @doc "`Goal.reducedTickDelay`: a delay for goals that tick every other tick."
  def reduced(ticks), do: ceil_div(ticks, 2)

  @doc "`BlockPos.containing(x, y, z)`."
  def block({x, y, z}), do: {Kernel.floor(x), Kernel.floor(y), Kernel.floor(z)}

  defp f(value), do: Float32.round(value)
end
