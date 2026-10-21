defmodule Valimc.Portal.JavaRandom do
  @moduledoc """
  Vanilla's `LegacyRandomSource` (`RandomSource.create(seed)`, Java's 48-bit
  linear congruential generator) for the few draws portals make (VMC-026b4:
  the island a gateway's exit search raises).
  """
  import Bitwise

  @multiplier 0x5DEECE66D
  @mask (1 <<< 48) - 1

  def new(seed), do: bxor(seed, @multiplier) &&& @mask

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

  @doc "`BlockPos.asLong`: 26 bits of X, 26 of Z and 12 of Y, as a signed long."
  def block_long({x, y, z}) do
    value = (x &&& 0x3FFFFFF) <<< 38 ||| (z &&& 0x3FFFFFF) <<< 12 ||| (y &&& 0xFFF)
    if value >= 1 <<< 63, do: value - (1 <<< 64), else: value
  end
end
