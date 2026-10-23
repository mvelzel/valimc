defmodule Valimc.Data.HostileFacts do
  @moduledoc """
  What the overworld hostiles read of vanilla beyond the AI and entity facts
  (VMC-043b), from `priv/registry/hostile_facts.json` (`HostileOracle
  facts`): the armour `populateDefaultEquipmentSlots` hands out by slot and
  material, the default equipment drop chance, the spawn equipment's
  enchanting (`mob_spawn_equipment`), each family type's baby dimensions,
  the villager type of each biome and the professions in registry order.
  """
  use Valimc.Data.Facts, "registry/hostile_facts.json"

  @armour Map.new(@facts["armour"], fn {slot, items} ->
            {String.to_atom(slot), List.to_tuple(items)}
          end)
  @drop_chance (fn bits ->
                  <<f::float-32>> = <<bits::signed-32>>
                  f
                end).(@facts["drop_chance"])
  @enchanting @facts["spawn_enchanting"]
  @babies Map.new(@facts["babies"], fn {type, dims} ->
            {type,
             List.to_tuple(
               Enum.map(dims, fn bits ->
                 <<f::float-32>> = <<bits::signed-32>>
                 f
               end)
             )}
          end)
  @villager_types @facts["villager_types"]
  @default_villager_type @facts["default_villager_type"]
  @professions List.to_tuple(@facts["professions"])
  @profession_ids @facts["professions"] |> Enum.with_index() |> Map.new()
  @type_ids @facts["villager_type_ids"] |> Enum.with_index() |> Map.new()

  @doc "`Mob.getEquipmentForSlot`: the armour of `slot` (head, chest, legs, feet) and material 0–5."
  def armour(slot, material), do: elem(@armour[slot], material)

  @doc "`DropChances.DEFAULT_EQUIPMENT_DROP_CHANCE`."
  def drop_chance, do: @drop_chance

  @doc "The spawn equipment's enchanting: `{min cost, max cost span, enchantment tag}`."
  def enchanting, do: {@enchanting["min_cost"], @enchanting["max_cost_span"], @enchanting["tag"]}

  @doc "A baby's `{width, height, eye height}` for a type that has one here, or nil."
  def baby(type), do: @babies[type]

  @doc "`VillagerType.byBiome`."
  def villager_type(biome), do: Map.get(@villager_types, biome, @default_villager_type)

  @doc "The villager professions in registry order (`Registry.getRandom` draws an index)."
  def professions, do: @professions

  @doc "A villager type's network id (its registry id)."
  def villager_type_id(type), do: Map.fetch!(@type_ids, type)

  @doc "A villager profession's network id (its registry id)."
  def profession_id(profession), do: Map.fetch!(@profession_ids, profession)
end
