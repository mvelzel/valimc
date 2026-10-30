defmodule Valimc.Data.HostileFacts do
  @moduledoc """
  What the Elixir side reads of the overworld hostiles' facts (VMC-043b,
  `priv/registry/hostile_facts.json`, `HostileOracle facts`): the default
  equipment drop chance, where equippable items are worn, the attribute
  modifiers effects give, the villager types' and professions' network ids
  and when the day lets monsters burn. Native mobs read the whole file
  (`Valimc.Entity.MobFacts`).
  """
  use Valimc.Data.Facts, "registry/hostile_facts.json"

  @drop_chance (fn bits ->
                  <<f::float-32>> = <<bits::signed-32>>
                  f
                end).(@facts["drop_chance"])
  @burn @facts["monsters_burn"]
  @burn_period @burn["period"]
  @burn_frames Enum.map(@burn["keyframes"], &{&1["ticks"], &1["value"]})
  @equippable Map.new(@facts["equippable"], fn {item, [slot, types, _sound]} ->
                {item, {String.to_atom(slot), types}}
              end)
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
  @profession_ids @facts["professions"] |> Enum.with_index() |> Map.new()
  @type_ids @facts["villager_type_ids"] |> Enum.with_index() |> Map.new()

  @doc "`DropChances.DEFAULT_EQUIPMENT_DROP_CHANCE`."
  def drop_chance, do: @drop_chance

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

  @doc "A villager type's network id (its registry id)."
  def villager_type_id(type), do: Map.fetch!(@type_ids, type)

  @doc "A villager profession's network id (its registry id)."
  def profession_id(profession), do: Map.fetch!(@profession_ids, profession)
end
