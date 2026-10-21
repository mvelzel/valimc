# VMC-021e: block entities of a vanilla world (AnvilContentOracle) import as
# vanilla loads them. Chests and furnaces ValiMC can hold become owned containers
# whose every slot equals vanilla's loaded stack (decoded from vanilla's network
# encoding); every other block entity is preserved with exactly vanilla's stored
# compound. The chunk packets ValiMC builds from the imported regions are written
# for `AnvilContentOracle verify`, which requires vanilla's block entity list.
alias Valimc.Anvil.Import
alias Valimc.Protocol.{Data, ItemStack}
alias Valimc.World.{BlockEntities, Blocks, Chunk, RegionStorage}

Code.require_file("nbt_canon.exs", __DIR__)

[facts_path, out_dir] = System.argv()
File.rm_rf!(out_dir)
File.mkdir_p!(out_dir)
Data.load!()
Valimc.Registry.BlockFacts.install!()
facts = facts_path |> File.read!() |> JSON.decode!()
imported = Path.join(out_dir, "imported-world")

stored = fn key ->
  {:ok, parts} = RegionStorage.read(imported, :overworld, key)
  parts
end

{:ok, report} = Import.run(facts["world"], imported)

unless report.error_count == 0, do: raise("import errors: #{inspect(report.errors)}")

regions =
  facts["block_entities"]
  |> Enum.map(fn %{"pos" => [x, _, z]} ->
    Valimc.World.region_key(Valimc.World.chunk_key(x, z))
  end)
  |> Enum.uniq()
  |> Map.new(fn key ->
    # Lit as an owner lights it: chunks the import has not are unknown (VMC-077c).
    parts = stored.(key)
    images = parts.columns

    absent =
      for c <- Valimc.World.RegionGeneration.chunks_of(key), not Map.has_key?(images, c), do: c

    {:ok, blocks} = Blocks.new(key, %{}, images, absent)
    containers = parts.containers
    {:ok, preserved} = BlockEntities.new(parts.block_entities)
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

# Entities: dropped items ValiMC can hold become item records with vanilla's
# UUID, position and loaded stack; every other entity is preserved unchanged.
entity_regions =
  facts["entities"]
  |> Enum.map(&Valimc.World.region_key({&1["chunk_x"], &1["chunk_z"]}))
  |> Enum.uniq()

records =
  for key <- entity_regions,
      record <- stored.(key).items,
      into: %{},
      do: {Base.encode16(record.uuid, case: :lower), record}

preserved_entities =
  for key <- entity_regions,
      {_chunk, nbt} <- RegionStorage.extra(imported, :overworld, key).entities,
      {:ok, {:compound, %{"Entities" => list}}} = Valimc.NBT.read(nbt),
      {:list, {:compound, entries}} = list,
      entry <- entries,
      do: NbtCanon.digest({:compound, entry})

# XP orbs become imported births with vanilla's UUID, value and count, and a
# body at vanilla's position.
orbs =
  for key <- entity_regions,
      containers = stored.(key).containers,
      {id, births} <- Valimc.World.CookingOrbs.owned_records(containers),
      {uuid, birth} <- births,
      into: %{},
      do: {Base.encode16(uuid, case: :lower), {birth, containers.orb_bodies.awards[id][uuid]}}

{imported_items, expected_preserved} =
  Enum.reduce(facts["entities"], {0, []}, fn row, {items, rest} ->
    case {records[row["uuid"]], orbs[row["uuid"]]} do
      {nil, {birth, body}} ->
        [x, y, z] = row["pos"]

        unless birth.value == row["value"] and birth.count == row["count"] and
                 body.position == {x, y, z},
               do: raise("orb #{row["uuid"]}: #{inspect({birth, body})} differs from vanilla's")

        {items, rest}

      {nil, nil} ->
        {items, [row["stored"] | rest]}

      {record, _} ->
        {:ok, stack} = ItemStack.decode(Base.decode16!(row["item"], case: :lower), :untrusted)
        [x, y, z] = row["pos"]

        unless record.stack == stack and {record.x, record.y, record.z} == {x, y, z},
          do: raise("item #{row["uuid"]}: #{inspect(record)} differs from vanilla's")

        {items + 1, rest}
    end
  end)

unless Enum.sort(preserved_entities) == Enum.sort(expected_preserved),
  do: raise("preserved entities differ from vanilla's stored compounds")

unless imported_items >= 4 and map_size(records) == imported_items and map_size(orbs) >= 4,
  do:
    raise(
      "item and orb coverage: #{imported_items} of #{map_size(records)}, #{map_size(orbs)} orbs"
    )

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
  # Packets carry computed light (VMC-022c), as owners send it.
  light = Blocks.light_image(region.blocks, chunk)

  {_id, payload} =
    Chunk.packet(encoded, Blocks.chunk_entities(region.blocks, chunk), preserved, light)

  File.write!(Path.join(out_dir, "chunk.#{cx}.#{cz}.bin"), payload)
end

# Corrections resend a preserved block entity's update packet after its block.
updates =
  for %{"pos" => [x, y, z]} <- facts["block_entities"],
      region = regions[Valimc.World.region_key(Valimc.World.chunk_key(x, z))],
      entry =
        BlockEntities.live(region.preserved, {x, y, z}, Blocks.get(region.blocks, {x, y, z})),
      entry != nil and entry.update != nil,
      reduce: 0 do
    n ->
      {_id, payload} =
        Valimc.Protocol.ChestBlockEntity.data_packet({x, y, z}, entry.type, entry.update)

      File.write!(Path.join(out_dir, "update.#{x}.#{y}.#{z}.bin"), IO.iodata_to_binary(payload))
      n + 1
  end

unless updates >= 10, do: raise("too few update packets: #{updates}")

# The imported world exports back to Anvil files for `AnvilContentOracle export`.
{:ok, exported} = Valimc.Anvil.Export.run(imported, Path.join(out_dir, "exported-world"))

IO.puts(
  "PASS: #{length(facts["block_entities"])} vanilla block entities import as vanilla loads them " <>
    "(#{counts.owned} owned containers with vanilla's stacks, #{counts.locked} locked and " <>
    "#{counts.preserved} preserved compounds); #{imported_items} dropped items become item records, " <>
    "#{map_size(orbs)} XP orbs imported births and #{length(expected_preserved)} other entities " <>
    "are preserved; chunk packets written for " <>
    "#{length(chunks)} chunks; exported #{exported.chunks} chunks and #{exported.entities} entities"
)
