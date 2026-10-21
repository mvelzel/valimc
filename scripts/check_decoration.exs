# VMC-025: ValiMC's decoration equals vanilla's (DecorationOracle). For each
# case, ValiMC builds the same 5 × 5 chunks of terrain, decorates the same 3 × 3
# chunks in the same order with the same placed features, and every block,
# post-processing mark, scheduled tick and block entity of the 25 chunks
# (position, and for created ones their loot table and seed, spawned entity or bees)
# must equal vanilla's.
[facts_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

features =
  for {step, index} <- Enum.with_index(facts["features"]),
      [global, _id] <- step,
      do: {index, global}

{:ok, _} = Application.ensure_all_started(:crypto)

names = fn id ->
  "minecraft:" <> Valimc.Registry.Blocks.name(Valimc.Registry.Blocks.block_id(id))
end

block_names = fn id -> "minecraft:" <> Valimc.Registry.Blocks.name(id) end

expand = fn runs ->
  for [id, count] <- Enum.chunk_every(runs, 2), into: <<>>, do: :binary.copy(<<id::16>>, count)
end

position = fn {x, y, z} -> "#{x},#{y},#{z}" end

# The first differing block (Y fastest from -64, then X, then Z) and the count.
first_difference = fn ours, want, {cx, cz} ->
  pairs = Enum.zip(for(<<a::16 <- ours>>, do: a), for(<<b::16 <- want>>, do: b))
  differing = pairs |> Enum.with_index() |> Enum.filter(fn {{a, b}, _} -> a != b end)

  case differing do
    [] ->
      {:size, byte_size(ours), byte_size(want)}

    [{{a, b}, index} | _] ->
      y = rem(index, 384) - 64
      x = rem(div(index, 384), 16)
      z = div(index, 384 * 16)
      {length(differing), {cx * 16 + x, y, cz * 16 + z}, names.(a), names.(b)}
  end
end

{failures, blocks, marks, ticks, entities, data} =
  for %{"seed" => seed, "x" => x, "z" => z, "order" => order, "chunks" => chunks} <-
        facts["cases"],
      reduce: {[], 0, 0, 0, 0, 0} do
    {failures, blocks, marks, ticks, entities, data} ->
      seed = String.to_integer(seed)
      {:ok, state} = Valimc.Worldgen.new(seed)

      result =
        Valimc.Native.worldgen_decorate(
          state,
          "minecraft:overworld",
          {x, z},
          Enum.map(order, fn [cx, cz] -> {cx, cz} end),
          features
        )

      # An area ValiMC cannot decorate fails as a whole.
      {decorated, failures} =
        case result do
          {:ok, decorated} -> {decorated, failures}
          {:error, reason} -> {[], [{seed, {x, z}, :area, [error: reason]} | failures]}
        end

      ours = Map.new(decorated, fn %{x: cx, z: cz} = chunk -> {{cx, cz}, chunk} end)
      chunks = if decorated == [], do: [], else: chunks

      Enum.reduce(chunks, {failures, blocks, marks, ticks, entities, data}, fn expected,
                                                                               {failures, blocks,
                                                                                marks, ticks,
                                                                                entities, data} ->
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
            )
          ]
          |> Enum.reject(&is_nil/1)

        failures =
          if problems == [], do: failures, else: [{seed, {x, z}, key, problems} | failures]

        {failures, blocks + div(byte_size(want), 2), marks + length(expected["marks"]),
         ticks + length(expected["block_ticks"]) + length(expected["fluid_ticks"]),
         entities + length(expected["block_entities"]),
         data + length(expected["block_entity_data"])}
      end)
  end

if failures != [] do
  for failure <- failures |> Enum.reverse() |> Enum.take(8), do: IO.inspect(failure, limit: 20)

  areas =
    failures
    |> Enum.frequencies_by(fn {seed, centre, _, _} -> {seed, centre} end)
    |> Enum.sort()

  IO.puts(
    "FAIL: #{length(failures)} decorated chunks differ from vanilla's, per area: #{inspect(areas)}"
  )

  System.halt(1)
end

included = length(features)

IO.puts(
  "PASS: #{length(facts["cases"])} decorated areas with #{included} placed features equal vanilla's " <>
    "(#{blocks} blocks, #{marks} post-processing marks, #{ticks} scheduled ticks, #{entities} block entities, " <>
    "#{data} of them filled in)"
)
