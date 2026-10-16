defmodule Valimc.World.ColumnHeight do
  @moduledoc "Bounded immutable occupancy for one 384-block column; owners choose the heightmap predicate."
  import Bitwise
  @maximum (1 <<< 384) - 1
  defguardp valid(bits) when is_integer(bits) and bits >= 0 and bits <= @maximum

  def empty, do: 0
  def flat, do: (1 <<< 128) - 1

  def update(bits, y, occupied)
      when valid(bits) and is_integer(y) and y in -64..319 and is_boolean(occupied) do
    bit = 1 <<< (y + 64)
    {:ok, if(occupied, do: bits ||| bit, else: bits &&& bnot(bit))}
  end

  def update(_, _, _), do: {:error, :invalid_column_height}

  def height(bits) when valid(bits) do
    <<top, _::binary>> = bytes = :binary.encode_unsigned(bits)
    {:ok, -64 + (byte_size(bytes) - 1) * 8 + width(top, 0)}
  end

  def height(_), do: {:error, :invalid_column_height}
  defp width(0, count), do: count
  defp width(top, count), do: width(top >>> 1, count + 1)
end
