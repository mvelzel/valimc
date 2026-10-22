defmodule Valimc.Storage.Anvil.RegionWriter do
  @moduledoc """
  Writing vanilla Anvil region files (VMC-021e3), laid out as the pinned
  `RegionFile` reads them.

  Chunks are zlib-compressed (compression 2, vanilla's default) and placed in
  order from sector 2, each padded to whole 4 KiB sectors; the header holds each
  slot's sector offset and count and the write time in seconds. A chunk needing
  more than 255 sectors goes to an external `c.X.Z.mcc` file beside the region
  file, with a one-byte payload carrying the compression plus 128, as vanilla
  writes it.

  Writes are crash-safe (`Valimc.Storage.DurableFile`), external chunks before the
  region file that points at them. A crash leaves either the old file or the
  complete new one.
  """
  @sector 4096
  @zlib 2
  @external 128

  @doc """
  Write region `{rx, rz}` into `dir` from `chunk => nbt` (uncompressed NBT bytes
  of chunks in this region); `timestamp` is the header time in seconds.
  """
  def write(dir, {rx, rz}, chunks, timestamp \\ System.os_time(:second))
      when is_map(chunks) and map_size(chunks) <= 1024 do
    File.mkdir_p!(dir)

    slots =
      chunks
      |> Enum.map(fn {{cx, cz} = chunk, nbt} ->
        true = Integer.floor_div(cx, 32) == rx and Integer.floor_div(cz, 32) == rz
        {Integer.mod(cz, 32) * 32 + Integer.mod(cx, 32), chunk, :zlib.compress(nbt)}
      end)
      |> Enum.sort()

    {body, header, _} =
      Enum.reduce(slots, {[], %{}, 2}, fn {index, {cx, cz}, data}, {body, header, next} ->
        payload =
          if byte_size(data) + 5 > 255 * @sector do
            :ok = Valimc.Storage.DurableFile.write(Path.join(dir, "c.#{cx}.#{cz}.mcc"), data)
            <<1::32, @zlib + @external>>
          else
            <<byte_size(data) + 1::32, @zlib, data::binary>>
          end

        count = div(byte_size(payload) + @sector - 1, @sector)
        padded = [payload, :binary.copy(<<0>>, count * @sector - byte_size(payload))]
        {[padded | body], Map.put(header, index, {next, count}), next + count}
      end)

    offsets =
      for index <- 0..1023, into: <<>> do
        case header do
          %{^index => {sector, count}} -> <<sector::24, count::8>>
          _ -> <<0::32>>
        end
      end

    times =
      for index <- 0..1023, into: <<>> do
        if Map.has_key?(header, index), do: <<timestamp::signed-32>>, else: <<0::32>>
      end

    path = Path.join(dir, "r.#{rx}.#{rz}.mca")

    Valimc.Storage.DurableFile.write(path, [offsets, times, Enum.reverse(body)])
  end
end
