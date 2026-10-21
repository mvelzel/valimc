defmodule Valimc.Anvil.Export do
  @moduledoc """
  Export a ValiMC world to vanilla 26.3 Anvil files (VMC-021e3).

  Every chunk a region holds beyond flat terrain (imported columns, edits,
  containers, items, preserved entities) becomes a full chunk in
  `dimensions/minecraft/overworld/region`: its blocks and biomes, its block
  entities (owned chests and furnaces written from their contents, preserved
  compounds while their block still creates their type) and the vanilla data the
  import kept (`chunk_extras`). Items, XP orbs (imported or from cooking, with
  their remaining count) and preserved entities go to the matching `entities`
  region files. Vanilla generates every other chunk itself.

  The vanilla world data an import kept (`vanilla/`: `level.dat`, world
  generation settings, game rules...) is written back, `level.dat` with the
  world's current spawn. A world that was never imported gets a new `level.dat`
  at its spawn and its generation settings (`world_gen_settings.dat`,
  VMC-028a), so vanilla generates the same world around it. Region files are written crash-safely (`RegionWriter`), one
  bounded task per vanilla region.

  Run with the server stopped, into a new or empty directory:

      mix valimc.export VALIMC_WORLD VANILLA_WORLD
      bin/valimc eval 'Valimc.Anvil.Export.cli(["VALIMC_WORLD", "VANILLA_WORLD"])'
  """
  alias Valimc.Anvil.{BlockEntity, Chunk, Entity, RegionWriter}
  alias Valimc.NBT
  alias Valimc.Physics.BlockEntities, as: Types

  alias Valimc.World.{
    BlockEntities,
    Blocks,
    Containers,
    CookingOrbs,
    GenSettings,
    Generator,
    ItemLedger,
    Schema,
    Spawn,
    Store
  }

  @dimension "dimensions/minecraft/overworld"

  @doc "Export `source` into `destination`; returns a report or an error."
  def run(source, destination) do
    started = System.monotonic_time(:millisecond)

    with :ok <- empty(destination),
         {:ok, keys} <- region_keys(source),
         :ok <- File.mkdir_p(destination) do
      size = Valimc.config(:region_size)

      written =
        keys
        |> Enum.group_by(fn {rx, rz} ->
          {Integer.floor_div(rx * size, 32), Integer.floor_div(rz * size, 32)}
        end)
        |> Task.async_stream(&write_region(source, destination, &1),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      case for({region, {:error, reason}} <- written, do: {region, reason}) do
        [] ->
          with :ok <- write_world_data(source, destination),
               :ok <- write_level(source, destination),
               :ok <- write_settings(source, destination) do
            {:ok,
             %{
               regions: length(written),
               chunks: Enum.sum(for {_, {:ok, counts}} <- written, do: counts.chunks),
               entities: Enum.sum(for {_, {:ok, counts}} <- written, do: counts.entities),
               milliseconds: System.monotonic_time(:millisecond) - started
             }}
          end

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

  defp region_keys(source) do
    case File.ls(source) do
      {:ok, names} ->
        keys =
          for name <- Enum.sort(names),
              [_, x, z] <- [Regex.run(~r/\Ar\.(-?\d+)\.(-?\d+)\z/, name)],
              File.dir?(Path.join(source, name)),
              do: {String.to_integer(x), String.to_integer(z)}

        {:ok, keys}

      {:error, reason} ->
        {:error, {:no_world, reason}}
    end
  end

  # One vanilla region: the chunks and entity chunks of its ValiMC regions.
  defp write_region(source, destination, {region, keys}) do
    {chunks, entities} =
      Enum.reduce(keys, {%{}, %{}}, fn key, {chunks, entities} ->
        {c, e} = region_contents(source, key)
        {Map.merge(chunks, c), Map.merge(entities, e)}
      end)

    dimension = Path.join(destination, @dimension)

    result =
      with :ok <- RegionWriter.write(Path.join(dimension, "region"), region, chunks),
           :ok <- write_entities(Path.join(dimension, "entities"), region, entities) do
        {:ok,
         %{chunks: map_size(chunks), entities: Enum.sum(Map.values(entities_count(entities)))}}
      end

    {region, result}
  rescue
    error -> {region, {:error, Exception.message(error)}}
  end

  defp write_entities(_dir, _region, entities) when map_size(entities) == 0, do: :ok

  defp write_entities(dir, region, entities) do
    chunks =
      Map.new(entities, fn {{cx, cz} = chunk, tags} ->
        root =
          {:compound,
           %{
             "DataVersion" => {:int, Schema.data_version()},
             "Position" => {:int_array, <<cx::signed-32, cz::signed-32>>},
             "Entities" => NBT.list(tags)
           }}

        {chunk, IO.iodata_to_binary(NBT.write(root))}
      end)

    RegionWriter.write(dir, region, chunks)
  end

  defp entities_count(entities),
    do: Map.new(entities, fn {chunk, tags} -> {chunk, length(tags)} end)

  # A ValiMC region's chunks (`chunk => nbt`) and entities (`chunk => [compound]`).
  defp region_contents(source, key) do
    edits = Store.durable(source, key, :blocks)
    {:ok, blocks} = Blocks.new(key, edits, Store.durable(source, key, :columns))

    containers =
      case Store.durable(source, key, :containers) do
        nil ->
          %Containers{}

        bytes ->
          {:ok, containers} = Containers.decode(bytes, key)
          containers
      end

    {:ok, preserved} = BlockEntities.new(Store.durable(source, key, :block_entities))
    extras = Store.durable(source, key, :chunk_extras)

    records =
      case Store.durable(source, key, :items) do
        nil ->
          []

        bytes ->
          {:ok, %{records: records}} = ItemLedger.decode(bytes, key)
          records
      end

    entities =
      Enum.reduce(Store.durable(source, key, :entities), %{}, fn {chunk, nbt}, acc ->
        {:ok, {:compound, %{"Entities" => list}}} = NBT.read(nbt)
        Map.update(acc, chunk, elements(list), &(&1 ++ elements(list)))
      end)

    entities =
      Enum.reduce(records, entities, fn record, acc ->
        chunk = Valimc.World.chunk_key(record.x, record.z)
        Map.update(acc, chunk, [Entity.item_tag(record)], &[Entity.item_tag(record) | &1])
      end)

    entities =
      Enum.reduce(orbs(containers), entities, fn {{x, _, z}, tag}, acc ->
        Map.update(acc, Valimc.World.chunk_key(x, z), [tag], &[tag | &1])
      end)

    holders =
      Enum.map(Map.keys(containers.entries), fn {x, _, z} -> Valimc.World.chunk_key(x, z) end)

    exported =
      (Blocks.touched_chunks(blocks) ++ holders ++ Map.keys(entities))
      |> Enum.uniq()
      |> Map.new(fn chunk ->
        {chunk, chunk_nbt(blocks, chunk, containers, preserved, extras[chunk])}
      end)

    {exported, entities}
  end

  # Every XP orb the region holds (imported or from cooking) with its remaining
  # count, at its body's position (or its birth's, before launch).
  defp orbs(containers) do
    for {id, births} <- CookingOrbs.owned_records(containers),
        {uuid, birth} <- births,
        body = get_in(containers.orb_bodies.awards, [id, uuid]),
        left =
          birth.count - Map.get(containers.orb_consumption.counts, uuid, 0) -
            if(body, do: body.expired, else: 0),
        left > 0 do
      body =
        body ||
          %{
            position: birth.position,
            velocity: {0.0, 0.0, 0.0},
            age: 0,
            on_ground: false,
            no_gravity: false
          }

      {body.position, Entity.orb_tag(uuid, birth.value, left, body)}
    end
  end

  defp elements({:list, {:compound, entries}}), do: Enum.map(entries, &{:compound, &1})
  defp elements(_), do: []

  defp chunk_nbt(blocks, chunk, containers, preserved, extras) do
    {:ok, states, biomes} = Blocks.dump_column(blocks, chunk)

    owned =
      for {{x, _, z} = position, entry} <- containers.entries,
          Valimc.World.chunk_key(x, z) == chunk,
          block = Blocks.get(blocks, position),
          Valimc.Block.block_entity(block) != nil,
          do: BlockEntity.container_tag(position, Types.type_name(Types.type_id(block)), entry)

    positions = BlockEntities.in_chunk(preserved, chunk)
    current = Blocks.get_many(blocks, positions)

    kept =
      for position <- positions,
          entry = BlockEntities.live(preserved, position, current[position]),
          entry != nil,
          {:ok, tag} = NBT.read(entry.nbt),
          do: tag

    extras =
      case extras do
        nil ->
          %{}

        nbt ->
          {:ok, {:compound, fields}} = NBT.read(nbt)
          fields
      end

    chunk
    |> Chunk.to_nbt(states, biomes, owned ++ kept, extras)
    |> NBT.write()
    |> IO.iodata_to_binary()
  end

  defp write_world_data(source, destination) do
    kept = Path.join(source, "vanilla")

    kept
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and Path.basename(&1) != "level.dat"))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      target = Path.join(destination, Path.relative_to(path, kept))
      File.mkdir_p!(Path.dirname(target))

      case RegionWriter.durable_write(target, File.read!(path)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Generation settings (VMC-028a): an import's kept file is already written;
  # any other world gets its recorded settings (ValiMC's flat profile's when it
  # records none), so vanilla goes on generating the same world.
  defp write_settings(source, destination) do
    path = "data/minecraft/world_gen_settings.dat"

    if File.exists?(Path.join([source, "vanilla", path])) do
      :ok
    else
      with {:ok, root} <- GenSettings.to_nbt(Generator.settings(source)) do
        File.mkdir_p!(Path.dirname(Path.join(destination, path)))

        RegionWriter.durable_write(
          Path.join(destination, path),
          NBT.write_compressed(root, :gzip)
        )
      end
    end
  end

  # The kept level.dat with the world's current spawn; a world never imported
  # gets a new one, initialized at its spawn.
  defp write_level(source, destination) do
    with {:ok, bytes} <- File.read(Path.join([source, "vanilla", "level.dat"])),
         {:ok, {:compound, %{"Data" => {:compound, data}} = root}} <-
           NBT.read_compressed(bytes, :gzip) do
      spawn =
        case File.read(Spawn.path(source)) do
          {:ok, text} ->
            %{"spawn" => [x, y, z], "yaw" => yaw} = JSON.decode!(text)

            {:compound, fields} = Map.get(data, "spawn", {:compound, %{}})

            {:compound,
             Map.merge(fields, %{
               "pos" => {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>},
               "yaw" => {:float, <<yaw * 1.0::float-32>>}
             })}

          _ ->
            data["spawn"]
        end

      data = if spawn, do: Map.put(data, "spawn", spawn), else: data
      level = NBT.write_compressed({:compound, Map.put(root, "Data", {:compound, data})}, :gzip)
      RegionWriter.durable_write(Path.join(destination, "level.dat"), level)
    else
      {:error, :enoent} -> new_level(source, destination)
      {:error, _} = error -> error
      _ -> {:error, :invalid_level_dat}
    end
  end

  # `PrimaryLevelData` of a new world as a dedicated server saves it, with the
  # world's spawn and default game mode; vanilla fills what it omits.
  defp new_level(source, destination) do
    {:ok, %{"spawn" => [x, y, z], "yaw" => yaw}} =
      source |> Spawn.path() |> File.read!() |> JSON.decode()

    version = Schema.data_version()

    game_type =
      Enum.find_index(
        ~w(survival creative adventure spectator)a,
        &(&1 == Valimc.config(:default_game_mode))
      )

    data = %{
      "DataVersion" => {:int, version},
      "Version" =>
        {:compound,
         %{
           "Id" => {:int, version},
           "Name" => {:string, Valimc.Version.minecraft()},
           "Series" => {:string, "main"},
           "Snapshot" => {:byte, 0}
         }},
      "version" => {:int, 19_133},
      "version_history" => {:list, {:int, [version]}},
      "LevelName" => {:string, "world"},
      "GameType" => {:int, game_type},
      "initialized" => {:byte, 1},
      "allowCommands" => {:byte, 0},
      "WasModded" => {:byte, 0},
      "ServerBrands" => {:list, {:string, ["ValiMC"]}},
      "DataPacks" =>
        {:compound,
         %{"Enabled" => {:list, {:string, ["vanilla"]}}, "Disabled" => {:list, {:end, []}}}},
      "spawn" =>
        {:compound,
         %{
           "dimension" => {:string, "minecraft:overworld"},
           "pos" => {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>},
           "yaw" => {:float, <<yaw * 1.0::float-32>>},
           "pitch" => {:float, <<0.0::float-32>>}
         }}
    }

    level = NBT.write_compressed({:compound, %{"Data" => {:compound, data}}}, :gzip)
    RegionWriter.durable_write(Path.join(destination, "level.dat"), level)
  end

  @doc "Command-line entry: prints the report; exits non-zero on failure."
  def cli([source, destination]) do
    Valimc.Protocol.Data.load!()
    Valimc.World.Blocks.init!()

    case run(Path.expand(source), Path.expand(destination)) do
      {:ok, report} ->
        IO.puts(
          "Exported #{report.chunks} chunks and #{report.entities} entities into " <>
            "#{report.regions} region files in #{report.milliseconds} ms"
        )

      {:error, reason} ->
        IO.puts(:stderr, "Export failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def cli(_) do
    IO.puts(:stderr, "usage: Valimc.Anvil.Export.cli([valimc_world, vanilla_world])")
    System.halt(2)
  end
end
