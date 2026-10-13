defmodule Valimc.Protocol.PackedVelocity do
  @moduledoc "Bounded Minecraft 26.3 LP vector codec, shared by entity spawn and motion."
  import Bitwise
  alias Valimc.Protocol.Wire
  @maximum 17_179_869_183.0
  @minimum 1.0 / 32766.0

  def encode({x, y, z}) when is_number(x) and is_number(y) and is_number(z) do
    {x, y, z} = {sanitize(x), sanitize(y), sanitize(z)}
    length = max(abs(x), max(abs(y), abs(z)))

    if length < @minimum do
      <<0>>
    else
      scale = ceil(length)
      continuation = scale > 3
      markers = if continuation, do: (scale &&& 3) ||| 4, else: scale

      packed =
        markers ||| pack(x / scale) <<< 3 ||| pack(y / scale) <<< 18 ||| pack(z / scale) <<< 33

      tail = if continuation, do: Wire.varint(scale >>> 2), else: <<>>
      <<packed &&& 255, packed >>> 8 &&& 255, packed >>> 16::unsigned-32, tail::binary>>
    end
  end

  def encode(_), do: raise(ArgumentError, "invalid velocity vector")

  def decode(bytes) do
    case take(bytes) do
      {:ok, vector, <<>>} -> {:ok, vector}
      {:ok, _, _} -> {:error, :trailing_velocity_bytes}
      error -> error
    end
  end

  def take(<<0, rest::binary>>), do: {:ok, {0.0, 0.0, 0.0}, rest}

  def take(<<lowest, middle, highest::unsigned-32, rest::binary>>) do
    packed = highest <<< 16 ||| middle <<< 8 ||| lowest

    {scale, rest} =
      if (lowest &&& 4) != 0 do
        {high, rest} = Wire.take_varint(rest)
        {(lowest &&& 3) ||| high <<< 2, rest}
      else
        {lowest &&& 3, rest}
      end

    {:ok,
     {unpack(packed >>> 3) * scale, unpack(packed >>> 18) * scale, unpack(packed >>> 33) * scale},
     rest}
  rescue
    ArgumentError -> {:error, :malformed_velocity}
  end

  def take(_), do: {:error, :malformed_velocity}
  defp sanitize(value), do: min(max(value, -@maximum), @maximum)
  defp pack(value), do: round((value * 0.5 + 0.5) * 32766.0)
  defp unpack(value), do: min(value &&& 32767, 32766) * 2.0 / 32766.0 - 1.0
end
