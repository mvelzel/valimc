# VMC-025, VMC-026a: ValiMC's decoration equals vanilla's (DecorationOracle),
# in the dimension the oracle decorated. For each case, ValiMC builds the same
# 5 × 5 chunks of terrain, decorates the same 3 × 3 chunks in the same order
# with the same placed features, and every block, post-processing mark,
# scheduled tick, block entity (position, and for created ones their loot table
# and seed, spawned entity, bees or gateway exit) and added entity of the 25
# chunks
# must equal vanilla's.
#
# VMC-025f: with structure placement facts (StructurePlacementOracle, which
# name structures), ValiMC decorates with every placed feature and those
# structures' starts placed in their steps, and every start as placement left
# it must equal vanilla's too; the terrain carries each chunk's beards from the
# starts that reference it (VMC-025f3).
# With a second argument (structure placement facts), ValiMC's block entities
# are written there for `StructurePlacementOracle verify`, which compares their
# NBT as vanilla saves it.
{facts_path, ours_path} =
  case System.argv() do
    [facts_path] -> {facts_path, nil}
    [facts_path, ours_path] -> {facts_path, ours_path}
  end

facts = facts_path |> File.read!() |> JSON.decode!()
settings = Map.get(facts, "noise_settings", "minecraft:overworld")
biome_source = Map.get(facts, "biome_source", "minecraft:overworld")
{min_y, height} = {Map.get(facts, "min_y", -64), Map.get(facts, "height", 384)}

structures = facts["structures"]

features =
  for {step, index} <- Enum.with_index(Map.get(facts, "features", [])),
      [global, _id] <- step,
      do: {index, global}

{:ok, _} = Application.ensure_all_started(:crypto)

names = fn id ->
  "minecraft:" <> Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(id))
end

block_names = fn id -> "minecraft:" <> Valimc.Data.Blocks.name(id) end

expand = fn runs ->
  for [id, count] <- Enum.chunk_every(runs, 2), into: <<>>, do: :binary.copy(<<id::16>>, count)
end

position = fn {x, y, z} -> "#{x},#{y},#{z}" end

# ValiMC's block entities of an area, for `StructurePlacementOracle verify`.
block_entities = fn seed, x, z, decorated ->
  Process.get(:block_entities, []) ++
    for chunk <- decorated,
        {{bx, by, bz}, state, type, nbt, loot, loot_seed} <- chunk.block_entity_nbt,
        nbt != "" or loot != "" do
      %{
        "case" => "#{seed}:#{x}:#{z}",
        "pos" => "#{bx},#{by},#{bz}",
        "state" => state,
        "type" => type
      }
      |> then(&if(nbt != "", do: Map.put(&1, "nbt", nbt), else: &1))
      |> then(
        &if(loot != "",
          do: Map.merge(&1, %{"loot_table" => loot, "loot_seed" => loot_seed}),
          else: &1
        )
      )
    end
end

# The first differing block (Y fastest from the bottom, then X, then Z) and the count.
first_difference = fn ours, want, {cx, cz} ->
  pairs = Enum.zip(for(<<a::16 <- ours>>, do: a), for(<<b::16 <- want>>, do: b))
  differing = pairs |> Enum.with_index() |> Enum.filter(fn {{a, b}, _} -> a != b end)

  case differing do
    [] ->
      {:size, byte_size(ours), byte_size(want)}

    [{{a, b}, index} | _] ->
      y = rem(index, height) + min_y
      x = rem(div(index, height), 16)
      z = div(index, height * 16)
      {length(differing), {cx * 16 + x, y, cz * 16 + z}, names.(a), names.(b)}
  end
end

# Entities in order (type, position, yaw, persistence, vehicle, data); a yaw
# ValiMC leaves random (`NaN`: vanilla takes it from `Math.random`, as end city
# shulkers keep it) matches any.
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

{failures, blocks, marks, ticks, entities, data, added} =
  for %{"seed" => seed, "x" => x, "z" => z, "order" => order, "chunks" => chunks} = area <-
        facts["cases"],
      reduce: {[], 0, 0, 0, 0, 0, 0} do
    {failures, blocks, marks, ticks, entities, data, added} ->
      seed = String.to_integer(seed)
      {:ok, state} = Valimc.Worldgen.new(seed, settings)

      order = Enum.map(order, fn [cx, cz] -> {cx, cz} end)

      result =
        if structures do
          Valimc.Native.worldgen_decorate_structures(
            state,
            biome_source,
            {x, z},
            order,
            structures
          )
        else
          Valimc.Native.worldgen_decorate(state, biome_source, {x, z}, order, features)
        end

      # An area ValiMC cannot decorate fails as a whole.
      {decorated, failures} =
        case result do
          {:ok, {decorated, starts}} ->
            want = Map.fetch!(area, "starts")
            if ours_path, do: Process.put(:block_entities, block_entities.(seed, x, z, decorated))

            failures =
              if Enum.sort(starts) == Enum.sort(want),
                do: failures,
                else: [
                  {seed, {x, z}, :starts, [ours: starts -- want, vanilla: want -- starts]}
                  | failures
                ]

            {decorated, failures}

          {:ok, decorated} ->
            {decorated, failures}

          {:error, reason} ->
            {[], [{seed, {x, z}, :area, [error: reason]} | failures]}
        end

      ours = Map.new(decorated, fn %{x: cx, z: cz} = chunk -> {{cx, cz}, chunk} end)
      chunks = if decorated == [], do: [], else: chunks

      Enum.reduce(chunks, {failures, blocks, marks, ticks, entities, data, added}, fn expected,
                                                                                      totals ->
        {failures, blocks, marks, ticks, entities, data, added} = totals
        key = {expected["x"], expected["z"]}
        chunk = ours[key]
        want = expand.(expected["runs"])

        block_ticks =
          Enum.map(chunk.block_ticks, fn {p, id, delay, priority} ->
            "#{position.(p)},#{block_names.(id)},#{delay},#{priority}"
          end)

        fluid_ticks =
          Enum.map(chunk.fluid_ticks, fn {p, name, delay, priority} ->
            "#{position.(p)},#{name},#{delay},#{priority}"
          end)

        problems =
          [
            if(chunk.blocks != want, do: {:blocks, first_difference.(chunk.blocks, want, key)}),
            if(Enum.map(chunk.marks, position) |> Enum.sort() != Enum.sort(expected["marks"]),
              do:
                {:marks, Enum.map(chunk.marks, position) -- expected["marks"],
                 expected["marks"] -- Enum.map(chunk.marks, position)}
            ),
            if(Enum.sort(block_ticks) != Enum.sort(expected["block_ticks"]),
              do:
                {:block_ticks, block_ticks -- expected["block_ticks"],
                 expected["block_ticks"] -- block_ticks}
            ),
            if(Enum.sort(fluid_ticks) != Enum.sort(expected["fluid_ticks"]),
              do:
                {:fluid_ticks, fluid_ticks -- expected["fluid_ticks"],
                 expected["fluid_ticks"] -- fluid_ticks}
            ),
            if(
              Enum.map(chunk.block_entities, position) |> Enum.sort() !=
                Enum.sort(expected["block_entities"]),
              do:
                {:block_entities, Enum.map(chunk.block_entities, position),
                 expected["block_entities"]}
            ),
            if(Enum.sort(chunk.block_entity_data) != Enum.sort(expected["block_entity_data"]),
              do:
                {:block_entity_data, chunk.block_entity_data -- expected["block_entity_data"],
                 expected["block_entity_data"] -- chunk.block_entity_data}
            ),
            if(not same_entities.(chunk.entities, Map.get(expected, "entities", [])),
              do: {:entities, chunk.entities, expected["entities"]}
            )
          ]
          |> Enum.reject(&is_nil/1)

        failures =
          if problems == [], do: failures, else: [{seed, {x, z}, key, problems} | failures]

        {failures, blocks + div(byte_size(want), 2), marks + length(expected["marks"]),
         ticks + length(expected["block_ticks"]) + length(expected["fluid_ticks"]),
         entities + length(expected["block_entities"]),
         data + length(expected["block_entity_data"]),
         added + length(Map.get(expected, "entities", []))}
      end)
  end

if ours_path, do: File.write!(ours_path, JSON.encode!(Process.get(:block_entities, [])))

if failures != [] do
  for failure <- failures |> Enum.reverse() |> Enum.take(8), do: IO.inspect(failure, limit: 20)

  areas =
    failures
    |> Enum.frequencies_by(fn {seed, centre, _, _} -> {seed, centre} end)
    |> Enum.sort()

  # What differs, over every failure: area errors (numbers left out) and the kinds of difference.
  reasons =
    failures
    |> Enum.flat_map(fn {_, _, _, problems} ->
      Enum.map(problems, fn
        {:error, reason} -> String.replace(reason, ~r/-?\d+/, "N")
        {kind, _} -> to_string(kind)
        {kind, _, _} -> to_string(kind)
      end)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)

  IO.puts("Differences: #{inspect(reasons, limit: :infinity, printable_limit: :infinity)}")

  IO.puts(
    "FAIL: #{length(failures)} decorated chunks differ from vanilla's, per area: #{inspect(areas)}"
  )

  System.halt(1)
end

included = if structures, do: "every placed feature", else: "#{length(features)} placed features"

placed =
  if structures do
    starts = facts["cases"] |> Enum.map(&length(&1["starts"])) |> Enum.sum()
    " and #{length(structures)} structures' starts (#{starts} starts as placement left them)"
  else
    ""
  end

IO.puts(
  "PASS: #{length(facts["cases"])} decorated #{Map.get(facts, "dimension", "overworld")} areas with " <>
    "#{included}#{placed} equal vanilla's (#{blocks} blocks, #{marks} post-processing marks, " <>
    "#{ticks} scheduled ticks, #{entities} block entities, #{data} of them filled in, #{added} entities)"
)
