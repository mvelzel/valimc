defmodule Valimc.Anvil.BlockEntity do
  @moduledoc """
  Vanilla block entities (a chunk's `block_entities` compounds) as ValiMC holds
  them (VMC-021e1).

  ValiMC owns single chests and the furnace family (`Valimc.World.Containers`).
  A chest or furnace whose compound holds only what ValiMC models (`Items`, and
  for furnaces the cooking times, speed and `RecipesUsed`) becomes an owned
  container. Every other block entity is preserved as its compound
  (`Valimc.World.BlockEntities`): it renders through vanilla's update tag, stays
  for export, and its block refuses interactions ValiMC cannot perform. That
  includes chests and furnaces with a custom name, lock, unrolled loot table or
  items with components ValiMC cannot hold ("locked" containers).

  As vanilla's `LevelChunk` does, a compound whose `id` is not the type the block
  at its position creates is dropped.
  """
  alias Valimc.Cooking
  alias Valimc.Physics.{BlockEntities, CookingBlocks}
  alias Valimc.Protocol.{ItemData, ItemStack}
  alias Valimc.World.CookingEntry

  @chest_fields ~w(id x y z keepPacked Items)
  @cooking_fields @chest_fields ++
                    ~w(cooking_time_spent cooking_total_time lit_time_remaining lit_total_time speed_multiplier RecipesUsed)
  @metadata ~w(id x y z keepPacked)

  @doc """
  A block entity's position as vanilla's `BlockEntity.getPosFromTag` reads it
  (missing coordinates are 0; one filed in another chunk moves to the same
  offset in this chunk), with the compound's coordinates set to it.
  """
  def position({:compound, fields}, {cx, cz}) do
    [x, y, z] =
      for key <- ["x", "y", "z"] do
        case fields[key] do
          {:int, value} -> value
          _ -> 0
        end
      end

    {x, z} =
      if Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz,
        do: {x, z},
        else: {cx * 16 + Integer.mod(x, 16), cz * 16 + Integer.mod(z, 16)}

    fields = Map.merge(fields, %{"x" => {:int, x}, "y" => {:int, y}, "z" => {:int, z}})
    {{x, y, z}, {:compound, fields}}
  end

  @doc """
  `{:ok, position, held}` for a block entity compound at a block state, where
  `held` is `{:chest, slots}`, `{:cooking, entry}` or `{:preserved, type_id}`;
  `{:drop, reason}` when vanilla would not load it.
  """
  def convert({:compound, fields} = tag, state) do
    with {:int, x} <- fields["x"],
         {:int, y} <- fields["y"],
         {:int, z} <- fields["z"],
         {:string, name} <- fields["id"] do
      type = BlockEntities.type_id(state)

      cond do
        type == nil -> {:drop, :no_block_entity}
        BlockEntities.type_named(qualified(name)) != type -> {:drop, :wrong_type}
        true -> {:ok, {x, y, z}, held(tag, state, type)}
      end
    else
      _ -> {:drop, :invalid_block_entity}
    end
  end

  def convert(_, _), do: {:drop, :invalid_block_entity}

  defp held({:compound, fields}, state, type) do
    owned =
      case Valimc.Block.block_entity(state) do
        :chest -> chest(fields)
        nil -> :error
        kind -> cooking(fields, kind, CookingBlocks.kind(state))
      end

    case owned do
      {:ok, held} -> held
      :error -> {:preserved, type}
    end
  end

  defp chest(fields) do
    with true <- only?(fields, @chest_fields),
         {:ok, slots} <- items(fields["Items"], 27) do
      {:ok, {:chest, slots}}
    else
      _ -> :error
    end
  end

  defp cooking(fields, kind, kind), do: cooking(fields, kind)
  defp cooking(_, _, _), do: :error

  defp cooking(fields, kind) do
    with true <- only?(fields, @cooking_fields),
         {:ok, slots} <- items(fields["Items"], 3),
         {:ok, recipes} <- recipes(fields["RecipesUsed"]) do
      cooking = %Cooking{
        slots: slots,
        burn_left: int(fields["lit_time_remaining"]),
        burn_total: int(fields["lit_total_time"]),
        progress: int(fields["cooking_time_spent"]),
        total: int(fields["cooking_total_time"]),
        speed:
          case fields["speed_multiplier"] do
            {:float, <<speed::float-32>>} -> speed
            nil -> 1.0
          end
      }

      entry = %{kind: kind, revision: 1, cooking: cooking, recipes: recipes}

      case CookingEntry.encode(entry) do
        {:ok, _} -> {:ok, {:cooking, Map.delete(entry, :revision)}}
        _ -> :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp int(nil), do: 0
  defp int({type, value}) when type in [:byte, :short, :int], do: value

  # Vanilla writes `components` on every block entity, empty when it has none.
  defp only?(fields, allowed),
    do: Enum.all?(Map.keys(without_empty_components(fields)), &(&1 in allowed))

  defp without_empty_components(%{"components" => {:compound, c}} = fields) when map_size(c) == 0,
    do: Map.delete(fields, "components")

  defp without_empty_components(fields), do: fields

  # ContainerHelper.loadAllItems: slots outside the container are ignored; a
  # later entry for a slot replaces an earlier one.
  defp items(nil, size), do: {:ok, Tuple.duplicate(nil, size)}

  defp items({:list, {:end, []}}, size), do: {:ok, Tuple.duplicate(nil, size)}

  defp items({:list, {:compound, entries}}, size) do
    Enum.reduce_while(entries, {:ok, Tuple.duplicate(nil, size)}, fn entry, {:ok, slots} ->
      case entry do
        %{"Slot" => {:byte, slot}} when slot >= 0 and slot < size ->
          case ItemData.stack({:compound, Map.delete(entry, "Slot")}) do
            {:ok, stack} -> {:cont, {:ok, put_elem(slots, slot, stack)}}
            _ -> {:halt, :error}
          end

        %{"Slot" => {:byte, _}} ->
          {:cont, {:ok, slots}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp items(_, _), do: :error

  defp recipes(nil), do: {:ok, %{}}

  defp recipes({:compound, used}) do
    if Enum.all?(used, &match?({_, {:int, n}} when n > 0, &1)),
      do: {:ok, Map.new(used, fn {key, {:int, n}} -> {qualified(key), n} end)},
      else: :error
  end

  defp recipes(_), do: :error

  @doc """
  The tag vanilla's `getUpdateTag` sends for a preserved block entity (chunk
  packets and block entity updates), derived from its stored compound as each
  type's override builds it: nothing by default, the custom data
  (`saveCustomOnly`), custom data and components (`saveWithoutMetadata`), or a
  type's own fields. `ExtractUpdateTags` in the oracle checks every type.
  """
  def update_tag("minecraft:" <> type, {:compound, fields}) do
    custom = Map.drop(fields, ["components" | @metadata])

    case type do
      "banner" ->
        {:compound, Map.drop(fields, @metadata)}

      type
      when type in ~w(beacon conduit creaking_heart decorated_pot jigsaw sign hanging_sign skull structure_block test_block test_instance_block end_gateway) ->
        {:compound, custom}

      "mob_spawner" ->
        {:compound, Map.delete(custom, "SpawnPotentials")}

      type when type in ~w(campfire shelf) ->
        items = Map.get(fields, "Items", {:list, {:end, []}})

        {:compound,
         if(type == "shelf",
           do: %{
             "Items" => items,
             "align_items_to_bottom" => Map.get(fields, "align_items_to_bottom", {:byte, 0})
           },
           else: %{"Items" => items}
         )}

      "brushable_block" ->
        {:compound, Map.take(fields, ["hit_direction", "item"])}

      "trial_spawner" ->
        {:compound, Map.take(fields, ["spawn_data"])}

      "vault" ->
        {:compound, Map.take(fields, ["shared_data"])}

      _ ->
        {:compound, %{}}
    end
  end

  @doc "Removing the block would lose data its compound holds (custom fields or components)."
  def holds_data?({:compound, fields}),
    do: map_size(Map.drop(without_empty_components(fields), @metadata)) > 0

  @doc "An owned chest's or furnace's compound for a world file (export)."
  def container_tag({x, y, z}, type, %{slots: slots}) do
    {:compound,
     %{
       "id" => {:string, type},
       "x" => {:int, x},
       "y" => {:int, y},
       "z" => {:int, z},
       "keepPacked" => {:byte, 0},
       "Items" => slot_list(slots)
     }}
  end

  def container_tag({x, y, z}, type, %{cooking: cooking, recipes: recipes}) do
    {:compound,
     %{
       "id" => {:string, type},
       "x" => {:int, x},
       "y" => {:int, y},
       "z" => {:int, z},
       "keepPacked" => {:byte, 0},
       "Items" => slot_list(cooking.slots),
       "cooking_time_spent" => {:int, cooking.progress},
       "cooking_total_time" => {:int, cooking.total},
       "lit_time_remaining" => {:int, cooking.burn_left},
       "lit_total_time" => {:int, cooking.burn_total},
       "speed_multiplier" => {:float, <<cooking.speed::float-32>>},
       "RecipesUsed" => {:compound, Map.new(recipes, fn {key, n} -> {key, {:int, n}} end)}
     }}
  end

  defp slot_list(slots) do
    slots
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _} ->
        []

      {%ItemStack{} = stack, slot} ->
        {:compound, item} = ItemData.tag(stack)
        [{:compound, Map.put(item, "Slot", {:byte, slot})}]
    end)
    |> Valimc.NBT.list()
  end

  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: if(String.contains?(name, ":"), do: name, else: "minecraft:" <> name)
end
