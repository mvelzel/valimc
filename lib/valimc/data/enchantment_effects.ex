defmodule Valimc.Data.EnchantmentEffects do
  @moduledoc """
  Enchantment effects from the pinned data pack's definitions
  (`EnchantmentMetadata`): the equipment slot groups an enchantment acts in,
  and its damage protection and damage immunity, each conditioned on damage
  type tags. Only the forms the pinned definitions use are accepted, so a
  definition outside them fails the build instead of being ignored.

  Equipment is `[{slot, enchantments}]` with vanilla's slots (`:mainhand`,
  `:offhand`, `:feet`, `:legs`, `:chest`, `:head`) and the stack's
  enchantment levels by name. Vanilla visits every entry, so a level of zero
  still grants immunity.
  """
  use Valimc.Data.Facts, "registry/enchantments.json"
  alias Valimc.Data.DamageTypes

  @groups %{
    any: [:mainhand, :offhand, :feet, :legs, :chest, :head, :body, :saddle],
    hand: [:mainhand, :offhand],
    armor: [:feet, :legs, :chest, :head],
    mainhand: [:mainhand],
    offhand: [:offhand],
    feet: [:feet],
    legs: [:legs],
    chest: [:chest],
    head: [:head],
    body: [:body],
    saddle: [:saddle]
  }

  # Damage type tags the source must have (true) or lack (false).
  requirement = fn
    nil ->
      []

    %{"type" => "minecraft:damage_source_properties", "predicate" => %{"tags" => tags} = p}
    when map_size(p) == 1 ->
      Enum.map(tags, fn %{"id" => "#minecraft:" <> tag, "expected" => expected} ->
        {String.to_atom(tag), expected}
      end)

    other ->
      raise "Unsupported enchantment requirement #{inspect(other)}"
  end

  # vanilla `LevelBasedValue.Linear`: base + per level above the first.
  linear = fn
    %{"type" => "minecraft:linear", "base" => base, "per_level_above_first" => per} -> {base, per}
    other -> raise "Unsupported enchantment level value #{inspect(other)}"
  end

  @definitions @facts["enchantments"]
               |> Map.new(fn {name, definition} ->
                 effects = definition["effects"]

                 protection =
                   Enum.map(Map.get(effects, "minecraft:damage_protection", []), fn
                     %{"effect" => %{"type" => "minecraft:add", "value" => value}} = entry ->
                       {linear.(value), requirement.(entry["requirements"])}

                     other ->
                       raise "Unsupported damage protection #{inspect(other)}"
                   end)

                 immunity =
                   Enum.map(Map.get(effects, "minecraft:damage_immunity", []), fn
                     %{"effect" => effect} = entry when effect == %{} ->
                       requirement.(entry["requirements"])

                     other ->
                       raise "Unsupported damage immunity #{inspect(other)}"
                   end)

                 slots =
                   definition["slots"]
                   |> Enum.flat_map(&Map.fetch!(@groups, String.to_atom(&1)))
                   |> Enum.uniq()

                 {name, %{slots: slots, protection: protection, immunity: immunity}}
               end)
               |> Map.reject(fn {_, d} -> d.protection == [] and d.immunity == [] end)

  unless map_size(@definitions) == 6,
    do: raise("Damage effect enchantments changed: #{inspect(Map.keys(@definitions))}")

  # vanilla `LevelBasedValue.Fraction` of two linear values, as float32.
  fraction = fn
    %{"type" => "minecraft:fraction", "numerator" => n, "denominator" => d} ->
      {linear.(n), linear.(d)}

    other ->
      raise "Unsupported item damage chance #{inspect(other)}"
  end

  # An item tag the tool must be in (true) or not (false).
  match_tool = fn
    %{"type" => "minecraft:match_tool", "predicate" => %{"items" => "#minecraft:" <> tag} = p}
    when map_size(p) == 1 ->
      tag

    other ->
      raise "Unsupported item damage requirement #{inspect(other)}"
  end

  tool = fn
    %{"type" => "minecraft:inverted", "term" => term} -> {match_tool.(term), false}
    requirement -> {match_tool.(requirement), true}
  end

  # Item damage (vanilla `RemoveBinomial`): per enchantment, the removal chance by
  # the tool's item tag. Only Unbreaking has one in the pinned pack.
  @item_damage @facts["enchantments"]
               |> Enum.flat_map(fn {name, definition} ->
                 case Map.get(definition["effects"], "minecraft:item_damage") do
                   nil ->
                     []

                   effects ->
                     [
                       {name,
                        Enum.map(effects, fn
                          %{"effect" => %{"type" => "minecraft:remove_binomial", "chance" => c}} =
                              entry ->
                            {fraction.(c), tool.(entry["requirements"])}

                          other ->
                            raise "Unsupported item damage #{inspect(other)}"
                        end)}
                     ]
                 end
               end)
               |> Map.new()

  unless Map.keys(@item_damage) == ["minecraft:unbreaking"],
    do: raise("Item damage enchantments changed: #{inspect(Map.keys(@item_damage))}")

  @item_tags Map.new(Valimc.Protocol.Data.tags()["minecraft:item"], fn {"minecraft:" <> tag, ids} ->
               {tag, MapSet.new(ids)}
             end)

  @doc """
  The chance that each point of wear on item `item_id` with `enchantments`
  (levels by name) is removed (vanilla `EnchantmentHelper.processDurabilityChange`
  with `RemoveBinomial`), as float32; 0.0 without such an enchantment.
  """
  def item_damage_chance(enchantments, item_id) do
    Enum.reduce(enchantments, 0.0, fn {name, level}, chance ->
      case Map.get(@item_damage, name) do
        nil ->
          chance

        effects ->
          Enum.find_value(effects, chance, fn {{{nb, np}, {db, dp}}, {tag, expected}} ->
            if MapSet.member?(Map.fetch!(@item_tags, tag), item_id) == expected and level > 0,
              do: f32(f32(nb + f32(np * (level - 1))) / f32(db + f32(dp * (level - 1))))
          end)
      end
    end)
  end

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end

  @doc "Vanilla `EnchantmentHelper.getDamageProtection`: the protection points against `source`."
  def protection(equipment, source) do
    for {slot, enchantments} <- equipment,
        {name, level} <- enchantments,
        %{slots: slots, protection: effects} <- [Map.get(@definitions, name)],
        slot in slots,
        {{base, per}, requirement} <- effects,
        matches?(requirement, source),
        reduce: 0.0,
        do: (total -> total + base + per * (level - 1))
  end

  @doc "Vanilla `EnchantmentHelper.isImmuneToDamage`."
  def immune?(equipment, source) do
    Enum.any?(equipment, fn {slot, enchantments} ->
      Enum.any?(enchantments, fn {name, _level} ->
        case Map.get(@definitions, name) do
          %{slots: slots, immunity: effects} ->
            slot in slots and Enum.any?(effects, &matches?(&1, source))

          nil ->
            false
        end
      end)
    end)
  end

  defp matches?(requirement, source),
    do:
      Enum.all?(requirement, fn {tag, expected} -> DamageTypes.tag?(source, tag) == expected end)
end
