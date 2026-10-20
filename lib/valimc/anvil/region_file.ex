defmodule Valimc.Anvil.RegionFile do
  @moduledoc """
  Reading vanilla Anvil region files (`r.X.Z.mca`, VMC-021a), as the pinned
  `RegionFile` reads them.

  The first 4 KiB hold 1,024 big-endian slot entries (sector offset << 8 |
  sector count) in `z * 32 + x` order; the next 4 KiB hold timestamps. A slot
  whose sector overlaps the header, has no sectors or starts past the end of the
  file is dropped, and a short header reads as empty slots. A chunk's sectors
  start with its length (the compression byte plus data), the compression byte
  (1 gzip, 2 zlib, 3 none, 4 LZ4; +128 for an external `c.X.Z.mcc` file in the
  same directory) and the data.

  Vanilla treats every damaged slot as a missing chunk (it logs and regenerates),
  so `chunk/4` returns `:absent` for them; a payload that fails to inflate or
  parse, or uses the custom compression id 127, is an error.
  """
  alias Valimc.NBT

  @sector 4096
  @compressions %{1 => :gzip, 2 => :zlib, 3 => :none, 4 => :lz4}
  # Vanilla registers 127 for custom compressions but cannot read them: an error.
  @custom 127

  @doc "Region coordinates from a file name `r.X.Z.mca`."
  def coords(path) do
    with [_, x, z] <- Regex.run(~r/\Ar\.(-?\d+)\.(-?\d+)\.mca\z/, Path.basename(path)),
         {x, ""} <- Integer.parse(x),
         {z, ""} <- Integer.parse(z),
         do: {:ok, {x, z}},
         else: (_ -> :error)
  end

  @doc """
  The usable slots of a region file's bytes: `{index, sector, count, timestamp}`
  for each chunk the header places, after vanilla's header checks.
  """
  def slots(bytes) when is_binary(bytes) do
    header = pad(binary_part(bytes, 0, min(byte_size(bytes), 2 * @sector)), 2 * @sector)
    <<offsets::binary-size(@sector), timestamps::binary-size(@sector)>> = header
    size = byte_size(bytes)

    for {<<sector::24, count::8>>, <<timestamp::signed-32>>, index} <-
          Enum.zip([chunks4(offsets), chunks4(timestamps), 0..1023]),
        sector != 0 or count != 0,
        sector >= 2 and count > 0 and sector * @sector <= size,
        do: {index, sector, count, timestamp}
  end

  defp chunks4(bytes), do: for(<<entry::binary-4 <- bytes>>, do: entry)
  defp pad(bytes, size), do: bytes <> :binary.copy(<<0>>, size - byte_size(bytes))

  @doc "Chunk coordinates of a slot in region `{rx, rz}`."
  def chunk_pos({rx, rz}, index), do: {rx * 32 + rem(index, 32), rz * 32 + div(index, 32)}

  @doc """
  The uncompressed NBT bytes of one slot: `{:ok, bytes}`, `:absent` (vanilla
  reads no chunk) or `{:error, reason}`. `dir` holds external `.mcc` files.
  """
  def chunk(
        bytes,
        {_index, sector, count, _} = slot,
        {dir, region},
        max \\ NBT.disk_limits().bytes
      ) do
    start = sector * @sector
    available = max(0, min(count * @sector, byte_size(bytes) - start))

    case binary_part(bytes, start, available) do
      <<length::signed-32, type, rest::binary>> when length != 0 ->
        payload(length - 1, type, rest, slot, {dir, region}, max)

      _ ->
        :absent
    end
  end

  defp payload(_size, type, _rest, {index, _, _, _}, {dir, region}, max) when type >= 128 do
    {cx, cz} = chunk_pos(region, index)

    with {:ok, data} <- File.read(Path.join(dir, "c.#{cx}.#{cz}.mcc")) do
      case type - 128 do
        @custom -> {:error, :custom_compression}
        id -> if c = @compressions[id], do: inflate(data, c, max), else: :absent
      end
    else
      _ -> :absent
    end
  end

  defp payload(size, type, rest, _slot, _where, max) when size >= 0 and size <= byte_size(rest) do
    case type do
      @custom ->
        {:error, :custom_compression}

      _ ->
        if c = @compressions[type], do: inflate(binary_part(rest, 0, size), c, max), else: :absent
    end
  end

  defp payload(_size, _type, _rest, _slot, _where, _max), do: :absent

  defp inflate(data, compression, max), do: NBT.decompress(data, compression, max)

  @doc """
  Every chunk of the region file at `path`: `{{cx, cz}, result}` per usable slot,
  where result is as for `chunk/4`.
  """
  def chunks(path, max \\ NBT.disk_limits().bytes) do
    with {:ok, region} <- coords(path),
         {:ok, bytes} <- File.read(path) do
      where = {Path.dirname(path), region}

      {:ok,
       for slot <- slots(bytes) do
         {chunk_pos(region, elem(slot, 0)), chunk(bytes, slot, where, max)}
       end}
    else
      :error -> {:error, :not_a_region_file}
      error -> error
    end
  end
end
