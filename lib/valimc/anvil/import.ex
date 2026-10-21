defmodule Valimc.Anvil.Import do
  @moduledoc """
  Import a vanilla 26.3 world into a new ValiMC world directory (VMC-021d).
  Region and entity chunks of 26.2 and 26.3's snapshots are upgraded first, as
  vanilla's data fixers upgrade them (`Valimc.World.DataFix`, VMC-028d).

  Every full overworld chunk becomes a column image in its ValiMC region's log
  (`Store.import_region/3`); chunks of other statuses are left out (ValiMC shows
  flat terrain there until generation exists). The spawn comes from `level.dat`.
  Region files convert in parallel, one bounded task per file.

  Block entities (VMC-021e1, `Valimc.Anvil.BlockEntity`): chests and furnaces
  ValiMC can hold become owned containers; the others are preserved with their
  compounds. The rest of each chunk's data (structures, pending ticks, post
  processing...) is kept for export as the region's `chunk_extras`.

  Entities (VMC-021e2, `Valimc.Anvil.Entity`): dropped items become item records
  in the region their position falls in (at most 256 per region, as owners
  allow; vanilla skips a repeated UUID), XP orbs become imported orb births
  (VMC-021e4, 256 awards per region); every other entity is preserved per chunk
  for export. Every other vanilla file except chunk storage (`level.dat`,
  world and dimension data such as world generation settings, game rules,
  weather and world border) is kept under `vanilla/` for export; the world's
  generation settings are also recorded in `world.json` (VMC-028a), so clients
  get its hashed seed and `/seed` its seed. Stored light
  (VMC-021e5, `Valimc.Anvil.Light`) lights imported chunks as vanilla does; POI
  and the other dimensions are not imported.

  Run with the server stopped, into a new or empty directory:

      mix valimc.import VANILLA_WORLD VALIMC_WORLD
      bin/valimc eval 'Valimc.Anvil.Import.cli(["VANILLA_WORLD", "VALIMC_WORLD"])'
  """
  alias Valimc.Anvil.{BlockEntity, Chunk, Entity, RegionFile}
  alias Valimc.{NBT, Native}

  alias Valimc.World.{
    BlockEntities,
    Blocks,
    Containers,
    CookingOrbs,
    DataFix,
    GenSettings,
    ItemLedger,
    Settings,
    Spec,
    Store
  }

  @overworld "dimensions/minecraft/overworld/region"
  @entities "dimensions/minecraft/overworld/entities"
  @max_items 256
  @max_errors 20

  @doc "Import `source` into `destination`; returns a report or an error."
  def run(source, destination) do
    started = System.monotonic_time(:millisecond)

    with :ok <- empty(destination),
         {:ok, spawn} <- read_spawn(source),
         {:ok, files} <- region_files(source, @overworld, true) do
      {:ok, entity_files} = region_files(source, @entities, false)

      converted =
        files
        |> Task.async_stream(&convert/1, ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      entities =
        entity_files
        |> Task.async_stream(&convert_entities/1, ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      converted = converted ++ entities
      chunks = for %{chunks: chunks} <- converted, chunk <- chunks, do: chunk
      File.mkdir_p!(destination)

      written =
        chunks
        |> regions(for(%{entities: list} <- entities, entity <- list, do: entity))
        |> Task.async_stream(&write_region(destination, &1), ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      case for({key, {:error, reason}, _} <- written, do: {key, reason}) do
        [] ->
          :ok = Settings.write(destination, %{spawn: spawn})
          :ok = Spec.write(destination, imported_generator(read_settings(source)))
          :ok = keep_world_data(source, Path.join(destination, "vanilla"))

          {:ok,
           %{
             regions: length(written),
             chunks: length(chunks),
             contents:
               Enum.reduce(written, %{}, fn {_, _, counts}, acc ->
                 Map.merge(acc, counts, fn _, a, b -> a + b end)
               end),
             skipped:
               Enum.reduce(
                 converted,
                 %{},
                 &Map.merge(&2, Map.get(&1, :skipped, %{}), fn _, a, b -> a + b end)
               ),
             errors: converted |> Enum.flat_map(& &1.errors) |> Enum.take(@max_errors),
             error_count: Enum.sum(Enum.map(converted, &length(&1.errors))),
             spawn: spawn.position,
             milliseconds: System.monotonic_time(:millisecond) - started
           }}

        failures ->
          {:error, {:region_writes_failed, failures}}
      end
    end
  end

  defp empty(destination) do
    case File.ls(destination) do
      {:ok, []} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :destination_not_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_spawn(source) do
    with {:ok, bytes} <- File.read(Path.join(source, "level.dat")),
         {:ok, level} <- NBT.read_compressed(bytes, :gzip),
         {:ok, _} <- DataFix.readable(:level, level),
         {:compound, %{"Data" => {:compound, data}}} <- level,
         {:compound, spawn} <- data["spawn"],
         {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} <- spawn["pos"] do
      angle = fn
        {:float, <<angle::float-32>>} -> angle
        _ -> 0.0
      end

      dimension =
        with {:string, name} <- spawn["dimension"],
             {:ok, dimension} <- Valimc.Dimension.parse(name),
             do: dimension,
             else: (_ -> :overworld)

      {:ok,
       %{
         dimension: dimension,
         position: {x, y, z},
         yaw: angle.(spawn["yaw"]),
         pitch: angle.(spawn["pitch"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_level_dat}
    end
  end

  # The imported world's generator (VMC-028a): the settings of its
  # `world_gen_settings.dat` (`root`; nil without one, ValiMC's flat profile),
  # or why ValiMC cannot read them. Imports keep flat terrain outside their
  # imported chunks.
  defp imported_generator(nil), do: %{"type" => "flat"}

  defp imported_generator(root) do
    case GenSettings.from_nbt(root) do
      {:ok, %{"seed" => seed} = settings} ->
        %{"type" => "imported", "seed" => seed, "settings" => settings}

      {:error, reason} ->
        %{"type" => "imported", "unreadable" => inspect(reason)}
    end
  end

  # `world_gen_settings.dat`'s root (VMC-028a), nil when the world has none or
  # it does not read.
  defp read_settings(source) do
    with {:ok, bytes} <- File.read(Path.join(source, "data/minecraft/world_gen_settings.dat")),
         {:ok, root} <- NBT.read_compressed(bytes, :gzip) do
      root
    else
      _ -> nil
    end
  end

  defp region_files(source, folder, required) do
    dir = Path.join(source, folder)

    case File.ls(dir) do
      {:ok, names} ->
        {:ok,
         for(
           name <- Enum.sort(names),
           match?({:ok, _}, RegionFile.coords(name)),
           do: Path.join(dir, name)
         )}

      {:error, :enoent} when not required ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:no_overworld_regions, reason}}
    end
  end

  # One entities region file: `{chunk, compound}` for every stored entity.
  defp convert_entities(path) do
    case RegionFile.chunks(path) do
      {:ok, chunks} ->
        Enum.reduce(chunks, %{chunks: [], entities: [], errors: []}, fn
          {_pos, :absent}, acc ->
            acc

          {pos, {:error, reason}}, acc ->
            %{acc | errors: [{pos, reason} | acc.errors]}

          {pos, {:ok, bytes}}, acc ->
            with {:ok, tag} <- NBT.read(bytes),
                 {:ok, tag} <- DataFix.upgrade(:entities, tag),
                 {:compound, root} = tag,
                 {:int_array, <<x::signed-32, z::signed-32>>} <- root["Position"] do
              list =
                case root["Entities"] do
                  {:list, {:compound, entries}} -> entries
                  _ -> []
                end

              %{acc | entities: Enum.map(list, &{{x, z}, {:compound, &1}}) ++ acc.entities}
            else
              {:error, reason} -> %{acc | errors: [{pos, reason} | acc.errors]}
              _ -> %{acc | errors: [{pos, :invalid_entity_chunk} | acc.errors]}
            end
        end)

      {:error, reason} ->
        %{chunks: [], entities: [], errors: [{path, reason}]}
    end
  end

  # Chunks and entities grouped by ValiMC region: an imported item belongs to
  # the region of its position, a preserved entity to that of its stored chunk.
  defp regions(chunks, entities) do
    empty = %{chunks: [], items: [], orbs: [], preserved: []}

    groups =
      Enum.reduce(chunks, %{}, fn %{chunk: chunk} = entry, groups ->
        Map.update(groups, Valimc.World.region_key(chunk), %{empty | chunks: [entry]}, fn g ->
          %{g | chunks: [entry | g.chunks]}
        end)
      end)

    Enum.reduce(entities, groups, fn {chunk, tag}, groups ->
      {key, field, value} =
        case Entity.convert(tag) do
          {:item, record} ->
            key = Valimc.World.region_key(Valimc.World.chunk_key(record.x, record.z))
            {key, :items, {chunk, tag, record}}

          {:orb, %{position: {x, _, z}} = orb} ->
            {Valimc.World.region_key(Valimc.World.chunk_key(x, z)), :orbs, {chunk, tag, orb}}

          :preserve ->
            {Valimc.World.region_key(chunk), :preserved, {chunk, tag}}
        end

      Map.update(
        groups,
        key,
        Map.put(empty, field, [value]),
        &Map.update!(&1, field, fn l -> [value | l] end)
      )
    end)
  end

  # One region file: column images of its full chunks, skipped statuses, errors.
  defp convert(path) do
    case RegionFile.chunks(path) do
      {:ok, chunks} ->
        {acc, _cache} =
          Enum.reduce(chunks, {%{chunks: [], skipped: %{}, errors: []}, %{}}, fn
            {_pos, :absent}, acc ->
              acc

            {pos, {:error, reason}}, {acc, cache} ->
              {%{acc | errors: [{pos, reason} | acc.errors]}, cache}

            {pos, {:ok, bytes}}, {acc, cache} ->
              {result, cache} =
                with {:ok, tag} <- NBT.read(bytes),
                     {:ok, tag} <- DataFix.upgrade(:chunk, tag) do
                  case Chunk.column(tag, cache) do
                    {{:ok, column}, cache} -> {{:ok, column, tag}, cache}
                    other -> other
                  end
                else
                  error -> {error, cache}
                end

              {add(acc, pos, result), cache}
          end)

        acc

      {:error, reason} ->
        %{chunks: [], skipped: %{}, errors: [{path, reason}]}
    end
  end

  defp add(acc, _pos, {:ok, %{chunk: chunk, sections: sections}, {:compound, root}}) do
    case Native.column_image_of(sections) do
      {:ok, image} ->
        entry = %{
          chunk: chunk,
          image: image,
          block_entities: block_entity_tags(root["block_entities"]),
          extras: extras(root),
          light: Valimc.Anvil.Light.image({:compound, root})
        }

        %{acc | chunks: [entry | acc.chunks]}

      {:error, reason} ->
        %{acc | errors: [{chunk, reason} | acc.errors]}
    end
  end

  defp add(acc, _pos, {:skip, status}),
    do: %{acc | skipped: Map.update(acc.skipped, status, 1, &(&1 + 1))}

  defp add(acc, pos, {:error, reason}), do: %{acc | errors: [{pos, reason} | acc.errors]}

  # World data ValiMC does not model, kept for export (VMC-021e3): everything but
  # chunk storage (region, entities and POI files), the lock and backups.
  defp keep_world_data(source, kept) do
    source
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn path ->
      Path.extname(path) in [".mca", ".mcc"] or
        Path.basename(path) in ["session.lock", "level.dat_old"]
    end)
    |> Enum.each(fn path ->
      target = Path.join(kept, Path.relative_to(path, source))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(path, target)
    end)
  end

  defp block_entity_tags({:list, {:compound, entries}}), do: Enum.map(entries, &{:compound, &1})
  defp block_entity_tags(_), do: []

  # Chunk data ValiMC does not model, kept for export: structures, pending ticks,
  # post processing, inhabited time... Sections, heightmaps and light are rebuilt.
  @modelled ~w(sections block_entities Heightmaps xPos yPos zPos Status DataVersion isLightOn)
  defp extras(root), do: IO.iodata_to_binary(NBT.write({:compound, Map.drop(root, @modelled)}))

  # One ValiMC region: its column images, block entities as owned containers or
  # preserved compounds, and chunk extras, written as one checkpoint.
  defp write_region(destination, {key, %{chunks: chunks} = group}) do
    images = Map.new(chunks, &{&1.chunk, &1.image})
    {:ok, blocks} = Blocks.new(key, %{}, images)

    {containers, preserved, counts} =
      for %{chunk: chunk, block_entities: tags} <- chunks,
          tag <- tags,
          reduce: {%Containers{}, %{}, %{}} do
        {containers, preserved, counts} ->
          place(key, chunk, blocks, tag, containers, preserved, counts)
      end

    {records, counts, extra} = entities(group, counts)
    {containers, counts, entities} = orbs(key, containers, group.orbs, counts, extra)

    parts = %{
      columns: images,
      block_entities: preserved,
      chunk_extras: Map.new(chunks, &{&1.chunk, &1.extras}),
      entities: entities,
      light: for(%{light: light} = c <- chunks, light != nil, into: %{}, do: {c.chunk, light})
    }

    result =
      with {:ok, parts} <- container_part(key, containers, parts),
           {:ok, parts} <- item_part(key, records, parts),
           {:ok, _} <- BlockEntities.new(preserved),
           do: Store.import_region(destination, key, parts)

    {key, result, counts}
  end

  # XP orbs in stored order while the region's award capacity lasts; the rest are
  # preserved with the other entities. A repeated UUID is skipped.
  defp orbs(key, containers, orbs, counts, kept) do
    {unique, _} =
      orbs
      |> Enum.reverse()
      |> Enum.flat_map_reduce(MapSet.new(), fn {_, _, orb} = entry, seen ->
        if MapSet.member?(seen, orb.uuid),
          do: {[], seen},
          else: {[entry], MapSet.put(seen, orb.uuid)}
      end)

    {:ok, containers, left} =
      CookingOrbs.import_orbs(containers, key, Enum.map(unique, &elem(&1, 2)))

    imported = length(unique) - length(left)
    {_, rest} = Enum.split(unique, imported)

    entities =
      Enum.reduce(rest, kept, fn {chunk, tag, _}, acc ->
        Map.update(acc, chunk, [tag], &(&1 ++ [tag]))
      end)
      |> Map.new(fn {chunk, tags} ->
        {chunk, IO.iodata_to_binary(NBT.write({:compound, %{"Entities" => NBT.list(tags)}}))}
      end)

    counts =
      counts
      |> Map.update(:orbs, imported, &(&1 + imported))
      |> Map.update(:entities_preserved, length(rest), &(&1 + length(rest)))

    {containers, counts, entities}
  end

  # Items in stored order up to the owner's bound; a repeated UUID is skipped as
  # vanilla's entity lookup skips it, an item past the bound is preserved.
  defp entities(%{items: items, preserved: preserved}, counts) do
    {records, extra, _} =
      items
      |> Enum.reverse()
      |> Enum.reduce({[], [], MapSet.new()}, fn {chunk, tag, record}, {records, extra, seen} ->
        cond do
          MapSet.member?(seen, record.uuid) -> {records, extra, seen}
          length(records) >= @max_items -> {records, [{chunk, tag} | extra], seen}
          true -> {[record | records], extra, MapSet.put(seen, record.uuid)}
        end
      end)

    kept = Enum.reverse(preserved) ++ Enum.reverse(extra)

    stored = Enum.group_by(kept, &elem(&1, 0), &elem(&1, 1))

    counts =
      counts
      |> Map.update(:items, length(records), &(&1 + length(records)))
      |> Map.update(:entities_preserved, length(kept), &(&1 + length(kept)))

    {Enum.reverse(records), counts, stored}
  end

  defp item_part(_key, [], parts), do: {:ok, parts}

  defp item_part(key, records, parts) do
    with {:ok, bytes} <- ItemLedger.encode(key, records, %{}),
         do: {:ok, Map.put(parts, :items, bytes)}
  end

  defp container_part(_key, %Containers{} = containers, parts)
       when containers == %Containers{},
       do: {:ok, parts}

  defp container_part(key, containers, parts) do
    with {:ok, bytes} <- Containers.encode(key, containers),
         do: {:ok, Map.put(parts, :containers, bytes)}
  end

  defp place(key, chunk, blocks, tag, containers, preserved, counts) do
    {position, tag} = BlockEntity.position(tag, chunk)
    {_, y, _} = position
    state = if Valimc.World.Chunk.valid_y?(y), do: Blocks.get(blocks, position)

    case state && BlockEntity.convert(tag, state) do
      {:ok, ^position, held} ->
        case own(key, position, held, containers) do
          {:ok, containers} ->
            {containers, preserved, bump(counts, :containers)}

          :preserve ->
            locked = Valimc.Block.block_entity(state) != nil

            case BlockEntities.encode_nbt(tag) do
              {:ok, nbt} ->
                type = Valimc.Physics.BlockEntities.type_id(state)

                {containers, Map.put(preserved, position, {type, nbt}),
                 bump(counts, if(locked, do: :locked, else: :preserved))}

              {:error, _} ->
                {containers, preserved, bump(counts, :dropped)}
            end
        end

      _ ->
        {containers, preserved, bump(counts, :dropped)}
    end
  end

  defp own(key, position, {:chest, slots}, containers) do
    with {:ok, containers, entry} <- Containers.create(containers, key, position, 3),
         {:ok, containers, _} <- Containers.replace(containers, position, entry.revision, slots) do
      {:ok, containers}
    else
      _ -> :preserve
    end
  end

  defp own(key, position, {:cooking, entry}, containers) do
    with {:ok, containers, created} <-
           Containers.create_cooking(containers, key, position, entry.kind),
         {:ok, containers, _} <-
           Containers.replace_cooking(
             containers,
             position,
             created.revision,
             entry.cooking,
             entry.recipes
           ) do
      {:ok, containers}
    else
      _ -> :preserve
    end
  end

  defp own(_key, _position, {:preserved, _}, _containers), do: :preserve

  defp bump(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  @doc "Command-line entry: prints the report; exits non-zero on failure."
  def cli([source, destination]) do
    Valimc.Protocol.Data.load!()
    Valimc.World.Blocks.init!()

    case run(Path.expand(source), Path.expand(destination)) do
      {:ok, report} ->
        IO.puts(
          "Imported #{report.chunks} chunks into #{report.regions} regions in #{report.milliseconds} ms"
        )

        IO.puts("Skipped (not full): #{inspect(report.skipped)}; errors: #{report.error_count}")
        IO.puts("Block entities and entities: #{inspect(report.contents)}")
        if report.errors != [], do: IO.puts("First errors: #{inspect(report.errors)}")
        IO.puts("Spawn: #{inspect(report.spawn)}")

      {:error, reason} ->
        IO.puts(:stderr, "Import failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def cli(_) do
    IO.puts(:stderr, "usage: Valimc.Anvil.Import.cli([vanilla_world, valimc_world])")
    System.halt(2)
  end
end
