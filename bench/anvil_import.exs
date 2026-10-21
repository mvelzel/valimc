# Anvil import throughput (VMC-021d) on a vanilla world.
#
#   python3 scripts/java_tool.py ChunkOracle generate <dir> <dir>/chunks.json
#   MIX_ENV=prod mix run --no-start bench/anvil_import.exs <dir>/universe/w <scratch> [results.json]
#
# Five whole imports (Valimc.Anvil.Import.run, parallel per region file, durable
# region-log writes) after one warmup, then a one-process phase breakdown per full
# chunk: region slot read and inflate, NBT decode, palette conversion, column image.
alias Valimc.Anvil.{Chunk, Import, RegionFile}
alias Valimc.{NBT, Native}

[world, scratch | rest] = System.argv()
Valimc.Protocol.Data.load!()
Valimc.Registry.BlockFacts.install!()
File.rm_rf!(scratch)

import_once = fn n ->
  dir = Path.join(scratch, "run-#{n}")
  {:ok, report} = Import.run(world, dir)
  File.rm_rf!(dir)
  report
end

import_once.(0)
runs = for n <- 1..5, do: import_once.(n)
chunks = hd(runs).chunks
ms = runs |> Enum.map(& &1.milliseconds) |> Enum.sort()

files = Path.wildcard(Path.join(world, "dimensions/minecraft/overworld/region/r.*.mca"))

slots =
  for path <- files,
      bytes = File.read!(path),
      {:ok, region} = RegionFile.coords(path),
      slot <- RegionFile.slots(bytes),
      do: {bytes, slot, {Path.dirname(path), region}}

time = fn fun ->
  {us, value} = :timer.tc(fun)
  {us, value}
end

phases =
  Enum.reduce(slots, %{read: 0, decode: 0, convert: 0, image: 0, full: 0}, fn {bytes, slot, where},
                                                                              acc ->
    {read_us, {:ok, nbt}} = time.(fn -> RegionFile.chunk(bytes, slot, where) end)
    {decode_us, {:ok, tag}} = time.(fn -> NBT.read(nbt) end)
    {convert_us, {result, _}} = time.(fn -> Chunk.column(tag) end)

    case result do
      {:ok, %{sections: sections}} ->
        {image_us, {:ok, _}} = time.(fn -> Native.column_image_of(sections) end)

        %{
          acc
          | read: acc.read + read_us,
            decode: acc.decode + decode_us,
            convert: acc.convert + convert_us,
            image: acc.image + image_us,
            full: acc.full + 1
        }

      _ ->
        acc
    end
  end)

per_chunk = fn us -> Float.round(us / phases.full, 1) end

summary = %{
  chunks: chunks,
  import_ms_min_median_max: [hd(ms), Enum.at(ms, 2), List.last(ms)],
  chunks_per_second_median: round(chunks / (Enum.at(ms, 2) / 1000)),
  per_full_chunk_us: %{
    read_inflate: per_chunk.(phases.read),
    decode: per_chunk.(phases.decode),
    convert: per_chunk.(phases.convert),
    image: per_chunk.(phases.image)
  },
  schedulers: System.schedulers_online(),
  otp: System.otp_release()
}

IO.puts(JSON.encode!(summary))
with [out] <- rest, do: File.write!(out, JSON.encode!(summary))
