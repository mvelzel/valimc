defmodule Valimc.Physics.BlockOffset do
  @moduledoc "Pinned horizontal block offsets with Java overflow and float promotion."
  import Bitwise

  @fractions List.to_tuple(
               for n <- 0..15 do
                 <<value::float-32>> = <<n / 15.0::float-32>>
                 value
               end
             )

  def valid_position?({x, y, z}),
    do:
      is_integer(x) and abs(x) <= 30_000_000 and is_integer(z) and abs(z) <= 30_000_000 and
        is_integer(y) and abs(y) <= 1_000_000

  def valid_position?(_), do: false

  def horizontal({x, _y, z} = position, limit) do
    unless valid_position?(position) and is_number(limit) and limit >= 0 and limit <= 0.25,
      do: raise(ArgumentError, "invalid block offset query")

    seed = bxor(signed(x * 3_129_871, 32), z * 116_129_781)
    seed = signed(seed * seed * 42_317_861 + seed * 11, 64) >>> 16
    {component(seed &&& 15, limit), 0.0, component(seed >>> 8 &&& 15, limit)}
  end

  defp component(n, limit), do: max(-limit, min(limit, (elem(@fractions, n) - 0.5) * 0.5))

  defp signed(value, bits) do
    masked = value &&& (1 <<< bits) - 1
    if masked >= 1 <<< (bits - 1), do: masked - (1 <<< bits), else: masked
  end
end
