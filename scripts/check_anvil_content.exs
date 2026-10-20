# VMC-021e: block entities of a vanilla world (AnvilContentOracle) import as
# vanilla loads them. Chests and furnaces ValiMC can hold become owned containers
# whose every slot equals vanilla's loaded stack (decoded from vanilla's network
# encoding); every other block entity is preserved with exactly vanilla's stored
# compound. The chunk packets ValiMC builds from the imported regions are written
# for `AnvilContentOracle verify`, which requires vanilla's block entity list.
alias Valimc.Anvil.Import
alias Valimc.Protocol.{Data, ItemStack}
alias Valimc.World.{BlockEntities, Blocks, Chunk, Containers, Store}

Code.require_file("nbt_canon.exs", __DIR__)

[facts_path, out_dir] = System.argv()
File.rm_rf!(out_dir)
File.mkdir_p!(out_dir)
Data.load!()
Blocks.init!()
facts = facts_path |> File.read!() |> JSON.decode!()
imported = Path.join(out_dir, "imported-world")
{:ok, report} = Import.run(facts["world"], imported)

unless report.error_count == 0, do: raise("import errors: #{inspect(report.errors)}")

regions =
  facts["block_entities"]
  |> Enum.map(fn %{"pos" => [x, _, z]} ->
    Valimc.World.region_key(Valimc.World.chunk_key(x, z))
  end)
  |> Enum.uniq()
  |> Map.new(fn key ->
    {:ok, blocks} = Blocks.new(key, %{}, Store.durable(imported, key, :columns))

    {:ok, containers} =
      case Store.durable(imported, key, :containers) do
        nil -> {:ok, %Containers{}}
        bytes -> Containers.decode(bytes, key)
      end

    {:ok, preserved} = BlockEntities.new(Store.durable(imported, key, :block_entities))
    {key, %{blocks: blocks, containers: containers, preserved: preserved}}
  end)

counts =
  Enum.reduce(facts["block_entities"], %{}, fn row, counts ->
    [x, y, z] = row["pos"]
    position = {x, y, z}
    region = regions[Valimc.World.region_key(Valimc.World.chunk_key(x, z))]
    block = Blocks.get(region.blocks, position)

    unless block == row["state"],
      do: raise("#{inspect(position)}: state #{block}, vanilla #{row["state"]}")

    case {region.containers.entries[position], region.preserved.entries[position]} do
      {entry, nil} when entry != nil ->
        slots =
          case entry do
            %{slots: slots} -> slots
            %{cooking: cooking} -> cooking.slots
          end

        expected =
          Enum.reduce(row["items"], Tuple.duplicate(nil, tuple_size(slots)), fn [slot, hex],
                                                                                acc ->
            case ItemStack.decode(Base.decode16!(hex, case: :lower), :untrusted) do
              {:ok, stack} ->
                put_elem(acc, slot, stack)

              other ->
                raise "#{inspect(position)} slot #{slot}: vanilla's stack decodes to #{inspect(other)}"
            end
          end)

        unless slots == expected,
          do:
            raise(
              "#{inspect(position)}: owned slots #{inspect(slots)}, vanilla #{inspect(expected)}"
            )

        Map.update(counts, :owned, 1, &(&1 + 1))

      {nil, %{type: type, nbt: nbt}} ->
        {:ok, tag} = Valimc.NBT.read(nbt)

        unless Valimc.Physics.BlockEntities.type_name(type) == row["type"],
          do: raise("#{inspect(position)}: type #{type}, vanilla #{row["type"]}")

        unless NbtCanon.digest(tag) == row["stored"],
          do:
            raise(
              "#{inspect(position)} (#{row["type"]}): preserved compound differs from vanilla's"
            )

        kind = if Valimc.Block.block_entity(block), do: :locked, else: :preserved
        Map.update(counts, kind, 1, &(&1 + 1))

      other ->
        raise "#{inspect(position)} (#{row["type"]}): held as #{inspect(other)}"
    end
  end)

unless counts[:owned] >= 6 and counts[:locked] >= 4 and counts[:preserved] >= 40,
  do: raise("fixture coverage: #{inspect(counts)}")

chunks =
  facts["block_entities"]
  |> Enum.map(&{&1["chunk_x"], &1["chunk_z"]})
  |> Enum.uniq()

for {cx, cz} = chunk <- chunks do
  region = regions[Valimc.World.region_key(chunk)]
  positions = BlockEntities.in_chunk(region.preserved, chunk)

  preserved =
    BlockEntities.chunk_entries(
      region.preserved,
      chunk,
      Blocks.get_many(region.blocks, positions)
    )

  encoded = Blocks.encode(region.blocks, chunk)
  {_id, payload} = Chunk.packet(encoded, Blocks.chunk_entities(region.blocks, chunk), preserved)
  File.write!(Path.join(out_dir, "chunk.#{cx}.#{cz}.bin"), payload)
end

IO.puts(
  "PASS: #{length(facts["block_entities"])} vanilla block entities import as vanilla loads them " <>
    "(#{counts.owned} owned containers with vanilla's stacks, #{counts.locked} locked and " <>
    "#{counts.preserved} preserved compounds); chunk packets written for #{length(chunks)} chunks"
)
