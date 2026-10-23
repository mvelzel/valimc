defmodule Valimc.AI.Random do
  @moduledoc """
  A mob's own random (`Entity.random`, vanilla's `LegacyRandomSource`: Java's
  48-bit linear congruential generator) as a plain integer state, so each
  mob draws the same sequence vanilla's would from the same seed. A new mob
  seeds it from its uuid (`new/1`); the state is saved with the mob.

  Every draw returns `{value, random}`.
  """
  import Bitwise
  alias Valimc.Data.Float32

  @multiplier 0x5DEECE66D
  @mask (1 <<< 48) - 1

  @doc "`setSeed(seed)` (a signed long); a uuid seeds from its first eight bytes."
  def new(<<seed::signed-64, _::binary>>), do: new(seed)
  def new(seed) when is_integer(seed), do: bxor(seed, @multiplier) &&& @mask

  @doc "Whether `random` is a state `new/1` can make."
  def valid?(random), do: is_integer(random) and random >= 0 and random <= @mask

  defp next(seed, bits) do
    seed = seed * @multiplier + 0xB &&& @mask
    value = seed >>> (48 - bits)
    # `(int)`: the top bit of a 32-bit draw is its sign.
    value = if bits == 32 and value >= 1 <<< 31, do: value - (1 <<< 32), else: value
    {value, seed}
  end

  @doc "`nextInt(bound)`."
  def int(random, bound) when bound > 0 do
    if (bound &&& bound - 1) == 0 do
      {value, random} = next(random, 31)
      {(bound * value) >>> 31, random}
    else
      rejection(random, bound)
    end
  end

  defp rejection(random, bound) do
    {bits, random} = next(random, 31)
    value = rem(bits, bound)
    # Java's int overflow test: bits - value + (bound - 1) < 0.
    if bits - value + (bound - 1) > 0x7FFFFFFF,
      do: rejection(random, bound),
      else: {value, random}
  end

  @doc "`nextFloat()`: 24 bits."
  def float(random) do
    {value, random} = next(random, 24)
    # 5.9604645E-8F is 2^-24 exactly.
    {value * 5.9604644775390625e-8, random}
  end

  @doc "`nextDouble()`: 53 bits."
  def double(random) do
    {upper, random} = next(random, 26)
    {lower, random} = next(random, 27)
    {((upper <<< 27) + lower) * 1.1102230246251565e-16, random}
  end

  @doc "`nextBoolean()`."
  def boolean(random) do
    {value, random} = next(random, 1)
    {value != 0, random}
  end

  @doc "`nextLong()`."
  def long(random) do
    {upper, random} = next(random, 32)
    {lower, random} = next(random, 32)
    value = (upper <<< 32) + lower &&& 0xFFFFFFFFFFFFFFFF
    {if(value >= 1 <<< 63, do: value - (1 <<< 64), else: value), random}
  end

  @doc """
  `LivingEntity.getVoicePitch`: `(nextFloat() - nextFloat()) * 0.2 + 1.0`,
  1.5 for a baby (`true`), or around another base (a baby zombie
  villager's 2.0).
  """
  def voice_pitch(random, baby \\ false) do
    {a, random} = float(random)
    {b, random} = float(random)

    base =
      case baby do
        true -> 1.5
        false -> 1.0
        base when is_float(base) -> base
      end

    {Float32.round(Float32.round(Float32.round(a - b) * Float32.round(0.2)) + base), random}
  end
end
