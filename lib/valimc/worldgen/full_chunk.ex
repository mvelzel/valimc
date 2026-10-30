defmodule Valimc.Worldgen.FullChunk do
  @moduledoc """
  Decorated chunks made full (VMC-025d3), as the live region stores them: the
  column image, block entities as the compounds vanilla's full chunk saves
  (`saveWithFullMetadata`; a created one with what decoration wrote into it, a
  pending one as its block's new block entity, which `LevelChunk` promotes it
  to), block ticks at delay 0 where the block still matches, and, until fluids
  exist (VMC-031), post-processing marks and fluid ticks. The entities
  structures and features added become body records, and the starts the
  chunk references whose structures override spawns stay with it
  (VMC-042b).

  Block entities go through the import path (`Valimc.Storage.Anvil.BlockEntity`), so a
  generated dungeon chest is preserved with its loot table like an imported
  one.
  """
  require Logger
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Storage.Anvil.BlockEntity
  alias Valimc.World.BlockEntities

  @doc """
  The region store's parts for `full` chunks (`gen_full` maps),
  adding their block entities and ticks to the region's `entities` and `ticks`:
  column images to store, column handles to install (nil where a full chunk
  carries none) and the rest.
  """
  def parts(full, entities, ticks) do
    # Ticks gather per chunk, newest first, and join once.
    initial = %{
      columns: %{},
      handles: %{},
      post_processing: %{},
      block_entities: entities,
      ticks: [ticks],
      entities: %{},
      structures: %{}
    }

    full
    |> Enum.reduce_while({:ok, initial}, fn chunk, {:ok, acc} ->
      key = {chunk.x, chunk.z}

      pending =
        if chunk.marks == [] and chunk.fluid_ticks == [],
          do: acc.post_processing,
          else: Map.put(acc.post_processing, key, {chunk.marks, chunk.fluid_ticks})

      case block_entities(chunk.block_entities, acc.block_entities) do
        {:ok, entities} ->
          {:cont,
           {:ok,
            %{
              acc
              | columns: Map.put(acc.columns, key, chunk.image),
                handles: Map.put(acc.handles, key, Map.get(chunk, :column)),
                post_processing: pending,
                block_entities: entities,
                ticks: [for({p, state} <- chunk.block_ticks, do: {p, state, 0, 0}) | acc.ticks],
                entities: Map.put(acc.entities, key, entity_records([chunk])),
                structures:
                  case Map.get(chunk, :structures, []) do
                    [] -> acc.structures
                    kept -> Map.put(acc.structures, key, kept)
                  end
            }}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, %{parts | ticks: parts.ticks |> Enum.reverse() |> Enum.concat()}}
      error -> error
    end
  end

  @doc """
  The body records of the entities generation added to `full` chunks (or
  `/place` placed, VMC-042b), in order. A yaw vanilla leaves random
  (`Math.random`, nil here) is drawn; a rider's vehicle is a body of its own
  until vehicles exist.
  """
  def entity_records(full) do
    for %{entities: entities} <- full,
        %{kind: kind, position: position} = entity <- entities,
        {:ok, body} <- [Body.generated(kind, entity.nbt, entity.persistent)] do
      yaw = entity.yaw || :rand.uniform() * 360.0
      body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}
      Store.body_record(body, :crypto.strong_rand_bytes(16), position)
    end
  end

  @doc """
  Generated block entities (`gen_full`'s or `/place`'s) as the
  region keeps them, `position => {type_id, nbt}`, added to `entities`. A
  block entity of a type not modelled here is left out (the client makes its
  own); everything else must convert.
  """
  def block_entities(list, entities) do
    Enum.reduce_while(list, {:ok, entities}, fn entity, {:ok, acc} ->
      with {:ok, tag} <- block_entity_tag(entity),
           {:ok, position, held} <- BlockEntity.convert(tag, entity.state),
           {:ok, type} <- preserved_type(held, entity.state),
           {:ok, nbt} <- BlockEntities.encode_nbt(tag) do
        {:cont, {:ok, Map.put(acc, position, {type, nbt})}}
      else
        :fresh ->
          {:cont, {:ok, acc}}

        # One vanilla would not load either (VMC-025f5).
        {:drop, reason} ->
          Logger.warning(
            "Generated block entity at #{inspect(entity.position)} dropped: #{inspect(reason)}"
          )

          {:cont, {:ok, acc}}

        {:error, {:unsupported_block_entity, id}} ->
          Logger.warning("Generated block entity #{id} at #{inspect(entity.position)} left out")
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, {:generated_block_entity, entity.position, reason}}}
      end
    end)
  end

  @doc """
  An end gateway's preserved entry (`{type_id, nbt}`) at `position` with
  `exit` (`{position, exact}`), as the region keeps it (VMC-026b4).
  """
  def gateway_entry(position, exit) do
    state = Valimc.Data.Blocks.default_state("end_gateway")
    entity = %{position: position, kind: "minecraft:end_gateway", exit: exit, state: state}

    with {:ok, tag} <- block_entity_tag(entity),
         {:ok, ^position, {:preserved, type}} <- BlockEntity.convert(tag, state),
         {:ok, nbt} <- BlockEntities.encode_nbt(tag),
         do: {:ok, {type, nbt}}
  end

  # A container a template gave contents ValiMC owns (VMC-025f5: a village's
  # furnaces and smokers, an empty chest). Empty, it is the block's fresh
  # block entity, which the region makes when it is used; with contents it is
  # kept as data, as an import keeps one it cannot own.
  defp preserved_type({:preserved, type}, _state), do: {:ok, type}

  defp preserved_type({:chest, slots}, state),
    do: if(empty?(slots), do: :fresh, else: kept(state))

  defp preserved_type({:machine, %{slots: slots}}, state),
    do: if(empty?(slots), do: :fresh, else: kept(state))

  defp preserved_type({:cooking, %{cooking: cooking, recipes: recipes}}, state) do
    if empty?(cooking.slots) and cooking.burn_left == 0 and cooking.progress == 0 and
         recipes == %{},
       do: :fresh,
       else: kept(state)
  end

  defp kept(state) do
    case Valimc.Blocks.BlockEntityTypes.type_id(state) do
      nil -> {:error, :no_block_entity}
      type -> {:ok, type}
    end
  end

  defp empty?(slots), do: Enum.all?(Tuple.to_list(slots), &is_nil/1)

  @doc "A full chunk's block entity as vanilla's full chunk saves it."
  def block_entity_tag(%{position: {x, y, z}} = entity) do
    with {:ok, id, fields} <- fields(entity) do
      # Components a template gave stay.
      {:ok,
       {:compound,
        %{"components" => {:compound, %{}}}
        |> Map.merge(fields)
        |> Map.merge(%{
          "id" => {:string, id},
          "x" => {:int, x},
          "y" => {:int, y},
          "z" => {:int, z}
        })}}
    end
  end

  # A structure template's block entity (VMC-025f5): its NBT, with the loot
  # table and seed that placement wrote.
  defp fields(%{kind: kind, nbt: nbt} = entity) when is_binary(kind) and is_binary(nbt) do
    {tag, _} = Valimc.Text.Snbt.parse_compound(Valimc.Text.Reader.new(nbt))
    {:compound, fields} = tag
    {:ok, kind, fields |> Map.drop(~w(id x y z)) |> Map.merge(loot(entity))}
  rescue
    error -> {:error, {:template_nbt, Exception.message(error)}}
  end

  # What decoration created, by its type.
  defp fields(%{kind: "minecraft:" <> _ = kind} = entity)
       when kind in ["minecraft:chest", "minecraft:trapped_chest", "minecraft:brushable_block"],
       do: {:ok, kind, loot(entity)}

  defp fields(%{kind: "minecraft:mob_spawner", spawner_entity: mob}) do
    {:ok, "minecraft:mob_spawner", spawner(mob)}
  end

  defp fields(%{kind: "minecraft:beehive", bees: bees}) do
    {:ok, "minecraft:beehive", %{"bees" => Valimc.Data.NBT.list(Enum.map(bees, &bee/1))}}
  end

  # An end gateway with its exit (VMC-026b, `TheEndGatewayBlockEntity.saveAdditional`).
  defp fields(%{kind: "minecraft:end_gateway", exit: exit}),
    do: {:ok, "minecraft:end_gateway", gateway(exit)}

  # A pending block entity: its block's new one.
  defp fields(%{kind: nil, state: state}) do
    case Valimc.Blocks.BlockEntityTypes.type_id(state) do
      nil -> {:error, :no_block_entity}
      type -> default(Valimc.Blocks.BlockEntityTypes.type_name(type))
    end
  end

  # A container a structure piece filled (a jungle temple's dispensers):
  # its loot table.
  defp fields(%{kind: "minecraft:" <> _ = kind, loot_table: table} = entity)
       when is_binary(table),
       do: {:ok, kind, loot(entity)}

  defp fields(entity), do: {:error, {:unsupported_block_entity, entity.kind}}

  defp gateway(nil), do: %{"Age" => {:long, 0}}

  defp gateway({{x, y, z}, exact}) do
    exit = %{
      "Age" => {:long, 0},
      "exit_portal" => {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>}
    }

    if exact, do: Map.put(exit, "ExactTeleport", {:byte, 1}), else: exit
  end

  # `RandomizableContainer.trySaveLootTable`: the table, and its seed unless 0.
  defp loot(%{loot_table: nil}), do: %{}

  defp loot(%{loot_table: table, loot_seed: 0}), do: %{"LootTable" => {:string, table}}

  defp loot(%{loot_table: table, loot_seed: seed}),
    do: %{"LootTable" => {:string, table}, "LootTableSeed" => {:long, seed}}

  # `BaseSpawner.save` with vanilla's defaults and the entity decoration set.
  defp spawner(mob) do
    data =
      if mob,
        do: %{"SpawnData" => {:compound, %{"entity" => {:compound, %{"id" => {:string, mob}}}}}},
        else: %{}

    Map.merge(data, %{
      "Delay" => {:short, 20},
      "MinSpawnDelay" => {:short, 200},
      "MaxSpawnDelay" => {:short, 800},
      "SpawnCount" => {:short, 4},
      "MaxNearbyEntities" => {:short, 6},
      "RequiredPlayerRange" => {:short, 16},
      "SpawnRange" => {:short, 4},
      "SpawnPotentials" => Valimc.Data.NBT.list([])
    })
  end

  # `BeehiveBlockEntity.Occupant.create(ticksInHive)`.
  defp bee(ticks) do
    {:compound,
     %{
       "entity_data" => {:compound, %{"id" => {:string, "minecraft:bee"}}},
       "ticks_in_hive" => {:int, ticks},
       "min_ticks_in_hive" => {:int, 600}
     }}
  end

  # New block entities of the types decoration leaves pending.
  defp default("minecraft:beehive" = id), do: {:ok, id, %{"bees" => Valimc.Data.NBT.list([])}}

  defp default(id) when id in ["minecraft:chest", "minecraft:trapped_chest"],
    do: {:ok, id, %{"Items" => Valimc.Data.NBT.list([])}}

  defp default("minecraft:brushable_block" = id), do: {:ok, id, %{}}
  defp default("minecraft:mob_spawner" = id), do: {:ok, id, spawner(nil)}
  defp default("minecraft:end_gateway" = id), do: {:ok, id, gateway(nil)}
  defp default("minecraft:end_portal" = id), do: {:ok, id, %{}}
  defp default("minecraft:creaking_heart" = id), do: {:ok, id, %{}}
  defp default("minecraft:potent_sulfur" = id), do: {:ok, id, %{"countdown" => {:int, -1}}}

  defp default("minecraft:sculk_catalyst" = id),
    do: {:ok, id, %{"cursors" => Valimc.Data.NBT.list([])}}

  defp default("minecraft:sculk_sensor" = id),
    do: {:ok, id, %{"last_vibration_frequency" => {:int, 0}, "listener" => listener()}}

  defp default("minecraft:sculk_shrieker" = id),
    do: {:ok, id, %{"warning_level" => {:int, 0}, "listener" => listener()}}

  defp default(id), do: {:error, {:unsupported_block_entity, id}}

  # A vibration listener that heard nothing (`VibrationSystem.Data`).
  defp listener,
    do:
      {:compound,
       %{
         "event_delay" => {:int, 0},
         "selector" => {:compound, %{"tick" => {:long, -1}}}
       }}
end
