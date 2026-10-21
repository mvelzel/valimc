defmodule Valimc.Registry.EnchantmentEffects do
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
  use Valimc.Facts, "registry/enchantments.json"
  alias Valimc.Registry.DamageTypes

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
