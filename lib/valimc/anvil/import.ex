defmodule Valimc.Anvil.Import do
  @moduledoc """
  Import a vanilla 26.3 world into a new ValiMC world directory (VMC-021d).

  Every full overworld chunk becomes a column image in its ValiMC region's log
  (`Store.import_region/3`); chunks of other statuses are left out (ValiMC shows
  flat terrain there until generation exists). The spawn comes from `level.dat`.
  Region files convert in parallel, one bounded task per file.

  Block entities (VMC-021e1, `Valimc.Anvil.BlockEntity`): chests and furnaces
  ValiMC can hold become owned containers; the others are preserved with their
  compounds. The rest of each chunk's data (structures, pending ticks, post
  processing...) is kept for export as the region's `chunk_extras`. Light, POI
  and the other dimensions are not imported.

  Run with the server stopped, into a new or empty directory:

      mix valimc.import VANILLA_WORLD VALIMC_WORLD
      bin/valimc eval 'Valimc.Anvil.Import.cli(["VANILLA_WORLD", "VALIMC_WORLD"])'
  """
  alias Valimc.Anvil.{BlockEntity, Chunk, RegionFile}
  alias Valimc.{NBT, Native}
  alias Valimc.World.{BlockEntities, Blocks, Containers, Schema, Spawn, Store}

  @overworld "dimensions/minecraft/overworld/region"
  @max_errors 20

  @doc "Import `source` into `destination`; returns a report or an error."
  def run(source, destination) do
    started = System.monotonic_time(:millisecond)

    with :ok <- empty(destination),
         {:ok, spawn} <- read_spawn(source),
         {:ok, files} <- region_files(source) do
      converted =
        files
        |> Task.async_stream(&convert/1, ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      chunks = for %{chunks: chunks} <- converted, chunk <- chunks, do: chunk
      File.mkdir_p!(destination)

      written =
        chunks
        |> Enum.group_by(fn %{chunk: chunk} -> Valimc.World.region_key(chunk) end)
        |> Task.async_stream(&write_region(destination, &1), ordered: false, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      case for({key, {:error, reason}, _} <- written, do: {key, reason}) do
        [] ->
          {position, yaw} = spawn
          :ok = Spawn.write(destination, position, yaw)

          {:ok,
           %{
             regions: length(written),
             chunks: length(chunks),
             block_entities:
               Enum.reduce(written, %{}, fn {_, _, counts}, acc ->
                 Map.merge(acc, counts, fn _, a, b -> a + b end)
               end),
             skipped:
               Enum.reduce(converted, %{}, &Map.merge(&2, &1.skipped, fn _, a, b -> a + b end)),
             errors: converted |> Enum.flat_map(& &1.errors) |> Enum.take(@max_errors),
             error_count: Enum.sum(Enum.map(converted, &length(&1.errors))),
             spawn: position,
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
         {:ok, _} <- Schema.check(:level, level),
         {:compound, %{"Data" => {:compound, data}}} <- level,
         {:compound, spawn} <- data["spawn"],
         {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} <- spawn["pos"] do
      yaw =
        case spawn["yaw"] do
          {:float, <<yaw::float-32>>} -> yaw
          _ -> 0.0
        end

      {:ok, {{x, y, z}, yaw}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_level_dat}
    end
  end

  defp region_files(source) do
    dir = Path.join(source, @overworld)

    case File.ls(dir) do
      {:ok, names} ->
        {:ok,
         for(
           name <- Enum.sort(names),
           match?({:ok, _}, RegionFile.coords(name)),
           do: Path.join(dir, name)
         )}

      {:error, reason} ->
        {:error, {:no_overworld_regions, reason}}
    end
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
                case NBT.read(bytes) do
                  {:ok, tag} ->
                    case Chunk.column(tag, cache) do
                      {{:ok, column}, cache} -> {{:ok, column, tag}, cache}
                      other -> other
                    end

                  error ->
                    {error, cache}
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
          extras: extras(root)
        }

        %{acc | chunks: [entry | acc.chunks]}

      {:error, reason} ->
        %{acc | errors: [{chunk, reason} | acc.errors]}
    end
  end

  defp add(acc, _pos, {:skip, status}),
    do: %{acc | skipped: Map.update(acc.skipped, status, 1, &(&1 + 1))}

  defp add(acc, pos, {:error, reason}), do: %{acc | errors: [{pos, reason} | acc.errors]}

  defp block_entity_tags({:list, {:compound, entries}}), do: Enum.map(entries, &{:compound, &1})
  defp block_entity_tags(_), do: []

  # Chunk data ValiMC does not model, kept for export: structures, pending ticks,
  # post processing, inhabited time... Sections, heightmaps and light are rebuilt.
  @modelled ~w(sections block_entities Heightmaps xPos yPos zPos Status DataVersion isLightOn)
  defp extras(root), do: IO.iodata_to_binary(NBT.write({:compound, Map.drop(root, @modelled)}))

  # One ValiMC region: its column images, block entities as owned containers or
  # preserved compounds, and chunk extras, written as one checkpoint.
  defp write_region(destination, {key, chunks}) do
    images = Map.new(chunks, &{&1.chunk, &1.image})
    {:ok, blocks} = Blocks.new(key, %{}, images)

    {containers, preserved, counts} =
      for %{chunk: chunk, block_entities: tags} <- chunks,
          tag <- tags,
          reduce: {%Containers{}, %{}, %{}} do
        {containers, preserved, counts} ->
          place(key, chunk, blocks, tag, containers, preserved, counts)
      end

    parts = %{
      columns: images,
      block_entities: preserved,
      chunk_extras: Map.new(chunks, &{&1.chunk, &1.extras})
    }

    result =
      with {:ok, parts} <- container_part(key, containers, parts),
           {:ok, _} <- BlockEntities.new(preserved),
           do: Store.import_region(destination, key, parts)

    {key, result, counts}
  end

  defp container_part(_key, %Containers{entries: entries}, parts) when map_size(entries) == 0,
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
        IO.puts("Block entities: #{inspect(report.block_entities)}")
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
