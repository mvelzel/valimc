defmodule Valimc.Anvil.Light do
  @moduledoc """
  Stored vanilla light of imported chunks (VMC-021e5), until ValiMC computes light
  itself (VMC-022).

  A chunk saved with `isLightOn` holds, per light section (y −5..20, one beyond
  the world on each side), optional `SkyLight` and `BlockLight` nibble arrays.
  Vanilla stores sky light only around the surface and block light only where
  it is not zero; the client derives the rest (a missing sky section takes the
  light at the bottom of the next stored section above, or full sky; missing
  block light is zero). Sending exactly the stored arrays therefore lights an
  imported chunk as vanilla does.

  The image keeps each array as absent, one repeated byte, or its 2,048 bytes.
  Light is not recomputed when blocks change: the client relights what it sees
  change, but a later join sees the imported light.
  """
  import Bitwise
  alias Valimc.Protocol.Wire

  @sections 26
  @min -5

  @doc "The light image of a chunk root, or nil when it has no valid stored light."
  def image({:compound, root}) do
    with {:byte, on} when on != 0 <- root["isLightOn"],
         {:list, {:compound, sections}} <- root["sections"] do
      by_y =
        for %{"Y" => {:byte, y}} = section <- sections,
            y >= @min and y < @min + @sections,
            into: %{},
            do: {y, section}

      parts =
        for y <- @min..(@min + @sections - 1) do
          section = Map.get(by_y, y, %{})
          [layer(section["SkyLight"]), layer(section["BlockLight"])]
        end

      if Enum.all?(List.flatten(parts), &(&1 != :invalid)),
        do: IO.iodata_to_binary(parts),
        else: nil
    else
      _ -> nil
    end
  end

  def image(_), do: nil

  defp layer(nil), do: <<0>>

  defp layer({:byte_array, <<first, _::binary>> = bytes}) when byte_size(bytes) == 2048 do
    if bytes == :binary.copy(<<first>>, 2048), do: <<1, first>>, else: [<<2>>, bytes]
  end

  defp layer(_), do: :invalid

  @doc "Whether `image` is a well-formed light image."
  def valid?(image) when is_binary(image), do: match?({:ok, _}, decode(image))
  def valid?(_), do: false

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
