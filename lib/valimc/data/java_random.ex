defmodule Valimc.Data.JavaRandom do
  @moduledoc """
  Vanilla's `LegacyRandomSource` (`RandomSource.create(seed)`, Java's 48-bit
  linear congruential generator) for the draws made outside generation:
  portals (VMC-026b4: the island a gateway's exit search raises) and the
  natural spawner's level random (VMC-042a). A random is its 48-bit seed.
  """
  import Bitwise

  @multiplier 0x5DEECE66D
  @mask (1 <<< 48) - 1

  @doc "`setSeed(seed)`: the scrambled seed."
  def new(seed), do: bxor(seed, @multiplier) &&& @mask

  @doc "A random seeded from the VM's own random, as `RandomSource.create()`."
  def create, do: new(:rand.uniform(1 <<< 48) - 1)

  defp next(seed, bits) do
    seed = seed * @multiplier + 0xB &&& @mask
    {seed >>> (48 - bits), seed}
  end

  @doc "`nextInt(bound)`: `{value, random}`."
  def next_int(random, bound) when bound > 0 do
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

  @doc "`nextFloat()`: 24 bits, `{value, random}`."
  def next_float(random) do
    {bits, random} = next(random, 24)
    {bits / 16_777_216, random}
  end

  @doc "`nextBoolean()`."
  def next_boolean(random) do
    {bit, random} = next(random, 1)
    {bit != 0, random}
  end

  @doc "`nextDouble()`: 53 bits."
  def next_double(random) do
    {high, random} = next(random, 26)
    {low, random} = next(random, 27)
    {((high <<< 27) + low) * 1.1102230246251565e-16, random}
  end

  @doc "`Mth.randomBetweenInclusive(random, min, max)`."
  def between(random, min, max) do
    {value, random} = next_int(random, max - min + 1)
    {value + min, random}
  end

  @doc "`BlockPos.asLong`: 26 bits of X, 26 of Z and 12 of Y, as a signed long."
  def block_long({x, y, z}) do
    value = (x &&& 0x3FFFFFF) <<< 38 ||| (z &&& 0x3FFFFFF) <<< 12 ||| (y &&& 0xFFF)
    if value >= 1 <<< 63, do: value - (1 <<< 64), else: value
  end
end
