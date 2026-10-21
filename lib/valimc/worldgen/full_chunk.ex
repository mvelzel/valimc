defmodule Valimc.Worldgen.FullChunk do
  @moduledoc """
  Decorated chunks made full (VMC-025d3), as the live region stores them: the
  column image, block entities as the compounds vanilla's full chunk saves
  (`saveWithFullMetadata`; a created one with what decoration wrote into it, a
  pending one as its block's new block entity, which `LevelChunk` promotes it
  to), block ticks at delay 0 where the block still matches, and, until fluids
  exist (VMC-031), post-processing marks and fluid ticks.

  Block entities go through the import path (`Valimc.Anvil.BlockEntity`), so a
  generated dungeon chest is preserved with its loot table like an imported
  one.
  """
  require Logger
  alias Valimc.Anvil.BlockEntity
  alias Valimc.World.BlockEntities

  @doc """
  The region store's parts for `full` chunks (`worldgen_proto_full` maps),
  adding their block entities and ticks to the region's `entities` and `ticks`.
  """
  def parts(full, entities, ticks) do
    initial = %{columns: %{}, post_processing: %{}, block_entities: entities, ticks: ticks}

    Enum.reduce_while(full, {:ok, initial}, fn chunk, {:ok, acc} ->
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
                post_processing: pending,
                block_entities: entities,
                ticks: acc.ticks ++ for({p, state} <- chunk.block_ticks, do: {p, state, 0, 0})
            }}}

        error ->
          {:halt, error}
      end
    end)
  end

  # A pending block entity of a type not modelled here is left out (the client
  # makes its own); everything else must convert.
  defp block_entities(list, entities) do
    Enum.reduce_while(list, {:ok, entities}, fn entity, {:ok, acc} ->
      with {:ok, tag} <- block_entity_tag(entity),
           {:ok, position, {:preserved, type}} <- BlockEntity.convert(tag, entity.state),
           {:ok, nbt} <- BlockEntities.encode_nbt(tag) do
        {:cont, {:ok, Map.put(acc, position, {type, nbt})}}
      else
        {:error, {:unsupported_block_entity, id}} when entity.kind == nil ->
          Logger.warning("Generated block entity #{id} at #{inspect(entity.position)} left out")
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, {:generated_block_entity, entity.position, reason}}}

        other ->
          {:halt, {:error, {:generated_block_entity, entity.position, other}}}
      end
    end)
  end

  @doc "A full chunk's block entity as vanilla's full chunk saves it."
  def block_entity_tag(%{position: {x, y, z}} = entity) do
    with {:ok, id, fields} <- fields(entity) do
      {:ok,
       {:compound,
        Map.merge(fields, %{
          "components" => {:compound, %{}},
          "id" => {:string, id},
          "x" => {:int, x},
          "y" => {:int, y},
          "z" => {:int, z}
        })}}
    end
  end

  # What decoration created, by its type.
  defp fields(%{kind: "minecraft:" <> _ = kind} = entity)
       when kind in ["minecraft:chest", "minecraft:trapped_chest", "minecraft:brushable_block"],
       do: {:ok, kind, loot(entity)}

  defp fields(%{kind: "minecraft:mob_spawner", spawner_entity: mob}) do
    {:ok, "minecraft:mob_spawner", spawner(mob)}
  end

  defp fields(%{kind: "minecraft:beehive", bees: bees}) do
    {:ok, "minecraft:beehive", %{"bees" => Valimc.NBT.list(Enum.map(bees, &bee/1))}}
  end

  # An end gateway with its exit (VMC-026b, `TheEndGatewayBlockEntity.saveAdditional`).
  defp fields(%{kind: "minecraft:end_gateway", exit: exit}),
    do: {:ok, "minecraft:end_gateway", gateway(exit)}

  # A pending block entity: its block's new one.
  defp fields(%{kind: nil, state: state}) do
    case Valimc.Physics.BlockEntities.type_id(state) do
      nil -> {:error, :no_block_entity}
      type -> default(Valimc.Physics.BlockEntities.type_name(type))
    end
  end

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
      "SpawnPotentials" => Valimc.NBT.list([])
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
  defp default("minecraft:beehive" = id), do: {:ok, id, %{"bees" => Valimc.NBT.list([])}}

  defp default(id) when id in ["minecraft:chest", "minecraft:trapped_chest"],
    do: {:ok, id, %{"Items" => Valimc.NBT.list([])}}

  defp default("minecraft:brushable_block" = id), do: {:ok, id, %{}}
  defp default("minecraft:mob_spawner" = id), do: {:ok, id, spawner(nil)}
  defp default("minecraft:end_gateway" = id), do: {:ok, id, gateway(nil)}
  defp default("minecraft:end_portal" = id), do: {:ok, id, %{}}
  defp default("minecraft:creaking_heart" = id), do: {:ok, id, %{}}
  defp default("minecraft:potent_sulfur" = id), do: {:ok, id, %{"countdown" => {:int, -1}}}

  defp default("minecraft:sculk_catalyst" = id),
    do: {:ok, id, %{"cursors" => Valimc.NBT.list([])}}

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
