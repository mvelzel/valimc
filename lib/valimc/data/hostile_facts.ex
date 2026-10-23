defmodule Valimc.Data.HostileFacts do
  @moduledoc """
  What the overworld hostiles read of vanilla beyond the AI and entity facts
  (VMC-043b), from `priv/registry/hostile_facts.json` (`HostileOracle
  facts`): the armour `populateDefaultEquipmentSlots` hands out by slot and
  material, the default equipment drop chance, the spawn equipment's
  enchanting (`mob_spawn_equipment`), each family type's baby dimensions,
  the villager type of each biome and the professions in registry order,
  and when the day lets monsters burn.
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
  @burn @facts["monsters_burn"]
  @burn_period @burn["period"]
  @burn_frames Enum.map(@burn["keyframes"], &{&1["ticks"], &1["value"]})
  @equippable Map.new(@facts["equippable"], fn {item, [slot, types, _sound]} ->
                {item, {String.to_atom(slot), types}}
              end)
  @equip_sounds Map.new(@facts["equippable"], fn {item, [_, _, sound]} -> {item, sound} end)
  @sounds @facts["sounds"]
  @water_sensitive MapSet.new(@facts["water_sensitive"])
  @operations %{"add_value" => 0, "add_multiplied_base" => 1, "add_multiplied_total" => 2}
  @effect_modifiers Map.new(@facts["effect_modifiers"], fn {effect, rows} ->
                      {effect,
                       for [attribute, id, op, amounts] <- rows do
                         {attribute, id, Map.fetch!(@operations, op),
                          List.to_tuple(
                            Enum.map(amounts, fn hex ->
                              <<v::float-64>> = Base.decode16!(hex, case: :lower)
                              v
                            end)
                          )}
                       end}
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

  @doc """
  Whether monsters burn at `ticks` of the overworld clock (the day
  timeline's `monsters_burn`: each keyframe holds until the next, looping).
  """
  def monsters_burn?(ticks) do
    t = Integer.mod(ticks, @burn_period)
    {_, last} = List.last(@burn_frames)

    Enum.reduce(@burn_frames, last, fn {at, value}, held ->
      if t >= at, do: value, else: held
    end)
  end

  @doc """
  Where an equippable item is worn (`Equippable.slot`) and the types that may
  wear it (nil: any): `{slot, types}`, or nil for an item not worn.
  """
  def equippable(item), do: @equippable[item]

  @doc "The sound an equippable item plays when worn (`Equippable.equipSound`)."
  def equip_sound(item), do: @equip_sounds[item]

  @doc "A hostile's sound's id (nil for one these facts do not hold)."
  def sound_id(name), do: @sounds[name]

  @doc "`isSensitiveToWater`: whether water and rain hurt mobs of `type`."
  def water_sensitive?(type), do: MapSet.member?(@water_sensitive, type)

  @doc """
  The attribute modifiers effect `name` gives at `amplifier`
  (`MobEffect.createModifiers`): `[{attribute, id, amount, operation}]`;
  past the facts' four amplifiers the amount grows by the first's.
  """
  def effect_modifiers(name, amplifier) do
    for {attribute, id, op, amounts} <- Map.get(@effect_modifiers, name, []) do
      amount =
        if amplifier < tuple_size(amounts),
          do: elem(amounts, amplifier),
          else: elem(amounts, 0) * (amplifier + 1)

      {attribute, id, amount, op}
    end
  end

  @doc "`VillagerType.byBiome`."
  def villager_type(biome), do: Map.get(@villager_types, biome, @default_villager_type)

  @doc "The villager professions in registry order (`Registry.getRandom` draws an index)."
  def professions, do: @professions

  @doc "A villager type's network id (its registry id)."
  def villager_type_id(type), do: Map.fetch!(@type_ids, type)

  @doc "A villager profession's network id (its registry id)."
  def profession_id(profession), do: Map.fetch!(@profession_ids, profession)
end
