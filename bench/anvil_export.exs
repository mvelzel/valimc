# Anvil export throughput and light cost (VMC-021e3/e5) on a vanilla world.
#
#   python3 scripts/java_tool.py ChunkOracle generate <dir> <dir>/chunks.json
#   MIX_ENV=prod mix run --no-start bench/anvil_export.exs <dir>/universe/w <scratch>
#
# Imports the world once, then five whole exports (Valimc.Anvil.Export.run,
# parallel per vanilla region, crash-safe writes) after one warmup, then a
# one-process phase breakdown per chunk: column dump, chunk NBT, NBT write, zlib,
# and block palette packing in Rust against its Elixir reference.
# Finally every imported chunk's packet with its light (each chunk's own, stored
# at import, then lit across the faces, VMC-077c) against the full-bright packet: bytes before and after network compression, and encode time.
alias Valimc.Anvil.{Chunk, Export, Import}
alias Valimc.NBT
alias Valimc.Protocol.Packets
alias Valimc.World.{Blocks, RegionStorage}

[world, scratch | _] = System.argv()
Valimc.Protocol.Data.load!()
Valimc.Registry.BlockFacts.install!()
File.rm_rf!(scratch)
imported = Path.join(scratch, "imported")
{:ok, report} = Import.run(world, imported)

export_once = fn n ->
  dir = Path.join(scratch, "export-#{n}")
  {:ok, report} = Export.run(imported, dir)
  File.rm_rf!(dir)
  report
end

export_once.(0)
runs = for n <- 1..5, do: export_once.(n)
ms = runs |> Enum.map(& &1.milliseconds) |> Enum.sort()

{:ok, keys} = RegionStorage.keys(imported, :overworld)

columns =
  Map.new(keys, fn key ->
    {:ok, parts} = RegionStorage.read(imported, :overworld, key)
    {key, parts.columns}
  end)

phases =
  for {key, images} <- columns,
      reduce: %{dump: 0, nbt: 0, write: 0, zlib: 0, native: 0, reference: 0, chunks: 0} do
    acc ->
      {:ok, blocks} = Blocks.new(key, %{}, images)

      Enum.reduce(Map.keys(images), acc, fn chunk, acc ->
        {dump, {:ok, states, biomes}} = :timer.tc(fn -> Blocks.dump_column(blocks, chunk) end)
        {nbt, tag} = :timer.tc(fn -> Chunk.to_nbt(chunk, states, biomes, []) end)
        {write, bytes} = :timer.tc(fn -> IO.iodata_to_binary(NBT.write(tag)) end)
        {zlib, _} = :timer.tc(fn -> :zlib.compress(bytes) end)
        sections = for s <- 0..23, do: binary_part(states, s * 8192, 8192)

        {native, _} =
          :timer.tc(fn -> Enum.each(sections, &Valimc.Native.pack_paletted(&1, 4)) end)

        {reference, _} = :timer.tc(fn -> Enum.each(sections, &Chunk.pack_reference(&1, 4)) end)

        %{
          acc
          | dump: acc.dump + dump,
            nbt: acc.nbt + nbt,
            write: acc.write + write,
            zlib: acc.zlib + zlib,
            native: acc.native + native,
            reference: acc.reference + reference,
            chunks: acc.chunks + 1
        }
      end)
  end

packets =
  for {key, images} <- columns, reduce: %{lit: [], bright: [], lit_us: 0, bright_us: 0} do
    acc ->
      absent = for c <- Valimc.Worldgen.Proto.chunks_of(key), not Map.has_key?(images, c), do: c
      {:ok, blocks} = Blocks.new(key, %{}, images, absent)

      Enum.reduce(Map.keys(images), acc, fn chunk, acc ->
        encoded = Blocks.encode(blocks, chunk)

        frame = fn image ->
          :timer.tc(fn ->
            Valimc.World.Chunk.packet(encoded, %{}, [], image)
            |> Packets.frame(256)
            |> IO.iodata_to_binary()
          end)
        end

        {lit_us, lit} = frame.(Blocks.light_image(blocks, chunk))
        {bright_us, bright} = frame.(nil)

        %{
          acc
          | lit: [byte_size(lit) | acc.lit],
            bright: [byte_size(bright) | acc.bright],
            lit_us: acc.lit_us + lit_us,
            bright_us: acc.bright_us + bright_us
        }
      end)
  end

per = fn total -> Float.round(total / phases.chunks, 1) end
mean = fn list -> div(Enum.sum(list), length(list)) end

IO.puts("Imported #{report.chunks} chunks")
IO.puts("Export of #{hd(runs).chunks} chunks: median #{Enum.at(ms, 2)} ms (runs #{inspect(ms)})")

IO.puts(
  "Per chunk (one process, µs): dump #{per.(phases.dump)}, chunk NBT #{per.(phases.nbt)}, " <>
    "NBT write #{per.(phases.write)}, zlib #{per.(phases.zlib)}"
)

IO.puts(
  "Block palette packing per chunk (24 sections, µs): native #{per.(phases.native)}, " <>
    "Elixir reference #{per.(phases.reference)}"
)

IO.puts(
  "Chunk frames: lit #{mean.(packets.lit)} B, full bright #{mean.(packets.bright)} B; " <>
    "encode #{per.(packets.lit_us)} µs vs #{per.(packets.bright_us)} µs"
)
