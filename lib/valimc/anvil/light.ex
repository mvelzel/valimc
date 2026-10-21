defmodule Valimc.Anvil.Light do
  @moduledoc """
  A chunk's light as packets carry it (VMC-021e5, VMC-077c): the image a
  region's light gives (`Valimc.World.Blocks.light_image/3`) and its encoding
  as the light part of `level_chunk_with_light` and `light_update`.

  The image holds 26 light sections (y −5..20, one beyond the world on each
  side), each its sky then its block layer as absent (tag 0), one repeated
  byte (tag 1) or its 2,048 bytes (tag 2). An absent layer is left out of the
  packet: for a light update that is a section that did not change.
  """
  import Bitwise
  alias Valimc.Protocol.Wire

  @sections 26

  # `[{sky, block}]` per section, each nil or 2,048 bytes.
  defp decode(image), do: decode(image, @sections, [])

  defp decode(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode(bytes, n, acc) when n > 0 do
    with {:ok, sky, rest} <- take(bytes),
         {:ok, block, rest} <- take(rest),
         do: decode(rest, n - 1, [{sky, block} | acc])
  end

  defp decode(_, _, _), do: :error

  defp take(<<0, rest::binary>>), do: {:ok, nil, rest}
  defp take(<<1, value, rest::binary>>), do: {:ok, :binary.copy(<<value>>, 2048), rest}
  defp take(<<2, data::binary-size(2048), rest::binary>>), do: {:ok, data, rest}
  defp take(_), do: :error

  @doc """
  The light part of a chunk packet: sky and block masks of the stored sections,
  empty masks, then the arrays. With no image, full sky light everywhere (the
  flat-world presentation).

  Packets carry the light sections of `dimension` (VMC-026b): one below and
  one above its stored sections, so 18 of the image's 26 in the Nether and
  the End, and no sky light where the dimension has none (the Nether).
  """
  def packet(image, dimension \\ Valimc.Dimension.current())

  def packet(nil, dimension) do
    {_first, count} = window(dimension)
    full = (1 <<< count) - 1
    light = :binary.copy(<<255>>, 2048)

    if Valimc.Dimension.facts(dimension).sky_light do
      [
        bitset(full),
        bitset(0),
        bitset(0),
        bitset(full),
        Wire.varint(count),
        List.duplicate([Wire.varint(2048), light], count),
        <<0>>
      ]
    else
      [bitset(0), bitset(0), bitset(0), bitset(full), <<0>>, <<0>>]
    end
  end

  def packet(image, dimension) do
    {:ok, layers} = decode(image)
    {first, count} = window(dimension)
    indexed = layers |> Enum.slice(first, count) |> Enum.with_index()
    sky? = Valimc.Dimension.facts(dimension).sky_light
    # All-zero layers go in the empty masks, as vanilla sends them.
    zero = :binary.copy(<<0>>, 2048)
    sky = for {{data, _}, i} <- indexed, sky?, data not in [nil, zero], do: {i, data}
    block = for {{_, data}, i} <- indexed, data not in [nil, zero], do: {i, data}
    empty_sky = for {{^zero, _}, i} <- indexed, sky?, do: {i, nil}
    empty_block = for {{_, ^zero}, i} <- indexed, do: {i, nil}

    [
      bitset(mask(sky)),
      bitset(mask(block)),
      bitset(mask(empty_sky)),
      bitset(mask(empty_block)),
      Wire.varint(length(sky)),
      Enum.map(sky, fn {_, data} -> [Wire.varint(2048), data] end),
      Wire.varint(length(block)),
      Enum.map(block, fn {_, data} -> [Wire.varint(2048), data] end)
    ]
  end

  # The image's light sections a dimension's packets carry.
  defp window(dimension) do
    {first, count} = Valimc.Dimension.section_window(dimension)
    {first, count + 2}
  end

  defp mask(layers), do: Enum.reduce(layers, 0, fn {i, _}, acc -> acc ||| 1 <<< i end)

  # A `BitSet` as 26.3 writes it: its little-endian bytes, trailing zeros dropped.
  defp bitset(0), do: <<0>>

  defp bitset(value) do
    bytes = :binary.encode_unsigned(value, :little)
    [Wire.varint(byte_size(bytes)), bytes]
  end
end
