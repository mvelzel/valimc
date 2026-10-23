# VMC-025d: live generation equals vanilla's decoration of the same chunks in
# the same order (DecorationOracle live). For each case ValiMC's generation
# scheduler (VMC-077n) is asked for the same regions' chunks one region after
# the other in a fresh decorated world of the case's seed, which numbers each
# region's undecorated 10 × 10 Z outer and X inner as the oracle decorates it;
# every block, post-processing mark, scheduled tick, block entity and added
# entity of each final chunk must equal vanilla's, and each block entity's NBT as the region
# stores it (`Valimc.Worldgen.FullChunk`) must equal vanilla's full chunk save.
# With a world (VMC-028c), every case's world takes its data packs and their
# extracted worldgen facts.
#
# VMC-026b: the oracle's facts name their dimension; the Nether's and the
# End's run in that dimension's scheduler, in a normal world of the case's seed.
#
# VMC-025f5: facts with `structures` (StructurePlacementOracle live) come from
# a world that generates structures, and so do the case's worlds here. A block
# entity a structure template gave its NBT is written to `--ours PATH` (case
# index, position, state, the compound the region stores) for
# `StructurePlacementOracle verify-live`, which loads it into vanilla's.
{ours_path, args} =
  case System.argv() do
    [facts, "--ours", ours | rest] -> {ours, [facts | rest]}
    args -> {nil, args}
  end

[facts_path | pack_world] = args
facts = facts_path |> File.read!() |> JSON.decode!()
alias Valimc.Native
alias Valimc.World.RegionGeneration
alias Valimc.Worldgen.{FullChunk, Scheduler}

dimension =
  case facts["dimension"] || "overworld" do
    "overworld" -> :overworld
    "nether" -> :the_nether
    "end" -> :the_end
  end

Valimc.World.Dimension.put(dimension)
{min_y, height} = Valimc.World.Dimension.bounds()

if {facts["min_y"] || -64, facts["height"] || 384} != {min_y, height},
  do: raise("dimension bounds differ from the oracle's")

size = Valimc.Data.Grid.region_size()
if facts["region_size"] != size, do: raise("region size #{size}, oracle #{facts["region_size"]}")

expand = fn runs ->
  for [id, count] <- Enum.chunk_every(runs, 2), into: <<>>, do: :binary.copy(<<id::16>>, count)
end

position = fn {x, y, z} -> "#{x},#{y},#{z}" end

names = fn id ->
  "minecraft:" <> Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(id))
end

block_names = fn id -> "minecraft:" <> Valimc.Data.Blocks.name(id) end

# Entities in order, as `check_decoration.exs` compares them (VMC-042b).
same_entities = fn ours, want ->
  length(ours) == length(want) and
    Enum.zip(ours, want)
    |> Enum.all?(fn {o, w} ->
      o == w or
        case {String.split(o, ",", parts: 8), String.split(w, ",", parts: 8)} do
          {[t, x, y, z, "NaN" | rest], [t, x, y, z, _ | rest]} -> true
          _ -> false
        end
    end)
end

# Random: the fresh VMs of parallel stages repeat `System.unique_integer`, and
# one run's cleanup would remove another's worlds.
root =
  Path.join(
    System.tmp_dir!(),
    "valimc-live-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  )

{failures, chunks, entities} =
  for {%{"seed" => seed, "regions" => regions} = entry, index} <- Enum.with_index(facts["cases"]),
      reduce: {[], 0, 0} do
    {failures, chunks, entities} ->
      seed = String.to_integer(seed)
      base = Path.join(root, "case-#{index}")
      File.mkdir_p!(base)

      for world <- pack_world,
          part <- ["datapacks", "worldgen"],
          do: File.cp_r!(Path.join(world, part), Path.join(base, part))

      # The world preset of the case's noise settings and biome source (VMC-028b).
      level_type =
        case {entry["noise_settings"], entry["fixed_biome"]} do
          _ when dimension != :overworld -> "minecraft:normal"
          {"minecraft:overworld", nil} -> "minecraft:normal"
          {"minecraft:overworld", "minecraft:plains"} -> "minecraft:single_biome_surface"
          {noise, nil} -> noise
        end

      settings =
        Valimc.Worldgen.GenSettings.create(level_type, nil, seed, facts["structures"] == true)

      :ok =
        Valimc.World.Spec.write(base, %{
          "type" => "vanilla",
          "seed" => seed,
          "features" => true,
          "settings" => settings
        })

      Enum.reduce(regions, {failures, chunks, entities}, fn %{
                                                              "x" => rx,
                                                              "z" => rz,
                                                              "chunks" => want
                                                            },
                                                            {failures, chunks, entities} ->
        key = {rx, rz}
        own = RegionGeneration.chunks_of(key)
        {:ok, full} = Scheduler.full_chunks(base, dimension, own)

        # The region store takes them as a live region does (VMC-025f5: a
        # template's smoker once failed there).
        case FullChunk.parts(full, %{}, []) do
          {:ok, _} -> :ok
          error -> raise "region #{inspect(key)} cannot store its full chunks: #{inspect(error)}"
        end

        {:ok, cells} = Scheduler.cells(base, dimension, own)
        {:ok, inspected} = Native.gen_inspect(cells)

        ours = Map.new(Enum.zip(own, Enum.zip(inspected, full)))

        Enum.reduce(want, {failures, chunks, entities}, fn expected,
                                                           {failures, chunks, entities} ->
          chunk = {expected["x"], expected["z"]}
          {got, whole} = ours[chunk]
          want_blocks = expand.(expected["runs"])

          ticks =
            Enum.map(got.block_ticks, fn {p, b, d, pr} ->
              "#{position.(p)},#{block_names.(b)},#{d},#{pr}"
            end)

          fluids =
            Enum.map(got.fluid_ticks, fn {p, f, d, pr} ->
              "#{position.(p)},#{f},#{d},#{pr}"
            end)

          {templated, plain} = Enum.split_with(whole.block_entities, &is_binary(&1[:nbt]))

          if templated != [] and ours_path == nil,
            do: raise("template block entities without --ours")

          for entity <- templated do
            {:ok, tag} = FullChunk.block_entity_tag(entity)

            Process.put(:ours, [
              %{
                "case" => index,
                "pos" => position.(entity.position),
                "state" => entity.state,
                "nbt" => Base.encode64(IO.iodata_to_binary(Valimc.Data.NBT.write(tag)))
              }
              | Process.get(:ours, [])
            ])
          end

          templated = MapSet.new(templated, &position.(&1.position))

          nbt =
            for entity <- plain, into: %{} do
              {:ok, tag} = FullChunk.block_entity_tag(entity)
              {position.(entity.position), tag}
            end

          vanilla =
            for line <- expected["nbt"],
                [x, y, z, encoded] = String.split(line, ",", parts: 4),
                not MapSet.member?(templated, "#{x},#{y},#{z}"),
                into: %{} do
              {:ok, tag} = Valimc.Data.NBT.read(Base.decode64!(encoded))
              {"#{x},#{y},#{z}", tag}
            end

          checks = [
            {:blocks, got.blocks == want_blocks,
             fn ->
               pairs =
                 Enum.zip(
                   for(<<a::16 <- got.blocks>>, do: a),
                   for(<<b::16 <- want_blocks>>, do: b)
                 )

               {i, {a, b}} =
                 pairs
                 |> Enum.with_index()
                 |> Enum.find(fn {{a, b}, _} -> a != b end)
                 |> then(fn {p, i} -> {i, p} end)

               {rem(i, height) + min_y, rem(div(i, height), 16), div(i, height * 16), names.(a),
                names.(b)}
             end},
            {:marks, Enum.sort(Enum.map(got.marks, position)) == Enum.sort(expected["marks"]),
             fn ->
               {Enum.map(got.marks, position) -- expected["marks"],
                expected["marks"] -- Enum.map(got.marks, position)}
             end},
            {:block_ticks, Enum.sort(ticks) == Enum.sort(expected["block_ticks"]),
             fn -> {ticks -- expected["block_ticks"], expected["block_ticks"] -- ticks} end},
            {:fluid_ticks, Enum.sort(fluids) == Enum.sort(expected["fluid_ticks"]),
             fn -> {fluids -- expected["fluid_ticks"], expected["fluid_ticks"] -- fluids} end},
            {:block_entities,
             Enum.sort(Enum.map(got.block_entities, position)) ==
               Enum.sort(expected["block_entities"]),
             fn -> {Enum.map(got.block_entities, position), expected["block_entities"]} end},
            {:block_entity_data,
             Enum.sort(got.block_entity_data) == Enum.sort(expected["block_entity_data"]),
             fn ->
               {got.block_entity_data -- expected["block_entity_data"],
                expected["block_entity_data"] -- got.block_entity_data}
             end},
            # VMC-042b: the entities structures and features added, each a
            # record the region keeps.
            {:entities,
             same_entities.(got.entities, expected["entities"] || []) and
               length(FullChunk.entity_records([whole])) == length(got.entities),
             fn -> {got.entities, expected["entities"]} end},
            {:block_entity_nbt, nbt == vanilla,
             fn ->
               differing = for {p, tag} <- vanilla, nbt[p] != tag, do: {p, nbt[p], tag}
               {Enum.take(differing, 2), Map.keys(nbt) -- Map.keys(vanilla)}
             end}
          ]

          failed = for {name, false, detail} <- checks, do: {seed, chunk, name, detail.()}
          {failed ++ failures, chunks + 1, entities + map_size(vanilla)}
        end)
      end)
      |> tap(fn _ ->
        # Its proto chunks go with it, without a snapshot.
        for {pid, _} <- Registry.lookup(Valimc.Worldgen.Schedulers, {base, dimension}),
            do: Process.exit(pid, :kill)
      end)
  end

File.rm_rf(root)
if ours_path, do: File.write!(ours_path, JSON.encode!(Enum.reverse(Process.get(:ours, []))))

# New block entities (what a pending one becomes) and what decoration writes
# into created ones, against vanilla's saved NBT.
default_failures =
  for line <- facts["defaults"],
      [label, encoded] = String.split(line, ",", parts: 2),
      {:ok, want} = Valimc.Data.NBT.read(Base.decode64!(encoded)),
      entity =
        (case String.split(label, " ") do
           ["minecraft:" <> block] ->
             %{kind: nil}
             |> Map.put(:state, Valimc.Data.Blocks.default_state(block))

           ["minecraft:bee_nest", "bees", bees] ->
             %{
               kind: "minecraft:beehive",
               bees: Enum.map(String.split(bees, "/"), &String.to_integer/1)
             }
             |> Map.put(:state, Valimc.Data.Blocks.default_state("bee_nest"))

           ["minecraft:suspicious_sand", "loot", table, seed] ->
             %{
               kind: "minecraft:brushable_block",
               loot_table: table,
               loot_seed: String.to_integer(seed)
             }
             |> Map.put(:state, Valimc.Data.Blocks.default_state("suspicious_sand"))
         end),
      entity =
        Map.merge(
          %{position: {1, 2, 3}, loot_table: nil, loot_seed: 0, spawner_entity: nil, bees: []},
          entity
        ),
      FullChunk.block_entity_tag(entity) != {:ok, want},
      do: {label, FullChunk.block_entity_tag(entity), want}

failures = failures ++ Enum.map(default_failures, &{:default, &1})

if failures != [] do
  for failure <- Enum.take(Enum.reverse(failures), 20), do: IO.inspect(failure, limit: 40)
  IO.puts("FAIL: #{length(failures)} differences in #{chunks} final chunks")
  System.halt(1)
end

IO.puts(
  "PASS: #{chunks} final chunks of #{length(facts["cases"])} live generation sequences equal vanilla's " <>
    "(blocks, marks, ticks, #{entities} block entities with their NBT); " <>
    "#{length(facts["defaults"])} block entity shapes equal vanilla's"
)
