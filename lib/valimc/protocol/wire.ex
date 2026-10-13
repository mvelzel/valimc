defmodule Valimc.Protocol.Wire do
  @moduledoc "Bounded Minecraft binary framing. No atoms are created from network input."
  import Bitwise

  def varint(n) when is_integer(n) and n >= -2_147_483_648 and n <= 4_294_967_295,
    do: encode_varint(n &&& 0xFFFFFFFF)

  defp encode_varint(n) when n < 128, do: <<n>>
  defp encode_varint(n), do: <<(n &&& 127) ||| 128>> <> encode_varint(n >>> 7)

  def read_varint(binary), do: decode_varint(binary, 0, 0)
  defp decode_varint(<<>>, _, _), do: :more

  defp decode_varint(<<b, rest::binary>>, acc, shift) when shift < 35 do
    if shift == 28 and b > 15 do
      {:error, :invalid_varint}
    else
      value = acc ||| (b &&& 127) <<< shift
      if (b &&& 128) == 0, do: {:ok, value, rest}, else: decode_varint(rest, value, shift + 7)
    end
  end

  defp decode_varint(_, _, _), do: {:error, :invalid_varint}

  def take_varint(binary) do
    case read_varint(binary) do
      {:ok, value, rest} -> {value, rest}
      _ -> raise ArgumentError, "invalid or truncated VarInt"
    end
  end

  def string(text) when is_binary(text), do: [varint(byte_size(text)), text]

  def take_string(binary, max_chars \\ 32767) do
    {size, rest} = take_varint(binary)

    if size > max_chars * 3 or size > byte_size(rest),
      do: raise(ArgumentError, "invalid string length")

    <<value::binary-size(^size), tail::binary>> = rest

    if not String.valid?(value) or String.length(value) > max_chars,
      do: raise(ArgumentError, "invalid Minecraft string")

    {value, tail}
  end

  def bool(true), do: <<1>>
  def bool(false), do: <<0>>
  def position({x, y, z}), do: <<x &&& 0x3FFFFFF::26, z &&& 0x3FFFFFF::26, y &&& 0xFFF::12>>

  def take_position(<<x::signed-26, z::signed-26, y::signed-12, rest::binary>>),
    do: {{x, y, z}, rest}

  # Network NBT has an unnamed root in current Java versions.
  def text_component(text), do: [<<10, 8, 0, 4>>, "text", <<byte_size(text)::16>>, text, <<0>>]

  def frame(id, payload, threshold \\ nil) do
    data = [varint(id), payload]
    size = IO.iodata_length(data)

    body =
      cond do
        threshold == nil -> data
        size < threshold -> [<<0>>, data]
        true -> [varint(size), :zlib.compress(data)]
      end

    IO.iodata_to_binary([varint(IO.iodata_length(body)), body])
  end

  def next_frame(binary, limit, threshold \\ nil) do
    case read_varint(binary) do
      {:ok, size, _} when size == 0 or size > limit ->
        {:error, :packet_size}

      {:ok, size, rest} when byte_size(rest) >= size ->
        <<body::binary-size(^size), tail::binary>> = rest

        with {:ok, data} <- uncompress(body, threshold, limit),
             {:ok, id, payload} <- read_varint(data) do
          {:ok, id, payload, tail}
        else
          _ -> {:error, :malformed_packet}
        end

      {:ok, _, _} ->
        :more

      other ->
        other
    end
  rescue
    _ -> {:error, :malformed_packet}
  end

  defp uncompress(body, nil, _), do: {:ok, body}

  defp uncompress(body, threshold, limit) do
    case read_varint(body) do
      {:ok, 0, rest} when byte_size(rest) < threshold -> {:ok, rest}
      {:ok, size, rest} when size >= threshold and size <= limit -> inflate_bounded(rest, size)
      _ -> {:error, :compression}
    end
  end

  defp inflate_bounded(data, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      output = inflate_chunks(z, data, expected, 0, [])
      if byte_size(output) == expected, do: {:ok, output}, else: {:error, :compression_size}
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks(z, input, limit, size, acc) do
    {status, chunk} = :zlib.safeInflate(z, input)
    total = size + IO.iodata_length(chunk)
    if total > limit, do: raise(ArgumentError, "decompression limit exceeded")

    case status do
      :finished -> IO.iodata_to_binary(Enum.reverse([chunk | acc]))
      :continue -> inflate_chunks(z, <<>>, limit, total, [chunk | acc])
    end
  end
end
