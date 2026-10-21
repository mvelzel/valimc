defmodule Valimc.Living.Damage do
  @moduledoc """
  Damage to a living entity after its hurt window (vanilla
  `LivingEntity.hurtServer` and `actuallyHurt`): invulnerability, enchantment
  and Fire Resistance immunity, armor wear, armor and toughness, Resistance,
  enchantment protection, absorption, then health. Every decision asks the
  damage source's tags. Pure: the owner commits, replicates and runs death.
  """
  alias Valimc.Living.{Armor, DamageSource, Health}
  alias Valimc.Protocol.EffectTypes
  alias Valimc.Registry.EnchantmentEffects
  @float_max 3.4028234663852886e38
  @resistance EffectTypes.id("resistance")
  @fire_resistance EffectTypes.id("fire_resistance")

  @doc """
  Resolve a selected hit (`Health.hurt_window/3`) of `source` on `living`
  (health, absorption and effects) wearing `equipment`. Options: `:effects`
  for the defenses (default the living's), `:invulnerable`, `:immune` (a
  caller's own immunity, such as a player's flight against falls), `:infinite`
  (no armor wear) and `:pending` (equipment cannot change now, so armored hits
  wait). Returns `:ignored`, `:immune`, `:deferred` or `{:ok, %{living,
  equipment, broken, exhaustion}}`; `exhaustion` is the food a player spends,
  or nil when no damage got through absorption.
  """
  def resolve(living, equipment, selected, source, opts \\ [])

  # `/kill` (vanilla `genericKill`): bypasses invulnerability, armour, effects
  # and absorption with Float.MAX_VALUE damage; exhaustion is zero.
  def resolve(living, equipment, selected, :generic_kill, _opts) do
    if living.health.value <= 0 or not selected.accepted do
      :ignored
    else
      {:ok, health} = Health.reduce(selected.state, @float_max)

      {:ok,
       %{
         living: Map.merge(living, %{health: health, absorption: 0.0}),
         equipment: equipment,
         broken: [],
         exhaustion: nil
       }}
    end
  end

  def resolve(living, equipment, selected, source, opts) do
    invulnerable = Keyword.get(opts, :invulnerable, false)

    cond do
      living.health.value <= 0 or not selected.accepted ->
        :ignored

      Keyword.get(opts, :immune, false) or
        (invulnerable and not DamageSource.is?(source, :bypasses_invulnerability)) or
        enchantment_immune?(equipment, source) or status_immune?(living.effects, source) ->
        :immune

      DamageSource.wears_armor?(source) and Keyword.get(opts, :pending, false) ->
        :deferred

      true ->
        {:ok, equipment, broken} =
          if DamageSource.wears_armor?(source),
            do:
              Armor.wear(equipment, source, selected.damage, Keyword.get(opts, :infinite, false)),
            else: {:ok, equipment, []}

        effects = Keyword.get(opts, :effects, living.effects)
        {:ok, damage} = protect(equipment, source, selected.damage, effects)

        {:ok, absorbed} =
          Health.spend_absorption(Map.get(living, :absorption, 0.0), damage)

        {:ok, health} = Health.reduce(selected.state, absorbed.damage)

        {:ok,
         %{
           living: Map.merge(living, %{health: health, absorption: absorbed.pool}),
           equipment: equipment,
           broken: broken,
           exhaustion: if(absorbed.damage > 0, do: DamageSource.exhaustion(source))
         }}
    end
  end

  @doc """
  Defenses after the hurt window, in vanilla's order: armor and toughness unless
  the source bypasses armor, then (`getDamageAfterMagicAbsorb`) Resistance and
  enchantment protection unless bypassed. Wear belongs to the caller.
  """
  def protect(equipment, source, amount, effects \\ %{})

  def protect(equipment, source, amount, effects)
      when is_map(equipment) and is_number(amount) and amount >= 0 and amount <= @float_max do
    if DamageSource.known?(source) do
      armored =
        if DamageSource.wears_armor?(source) do
          attributes = Armor.attributes(equipment)
          {:ok, damage} = armor_absorb(amount, attributes.armor, attributes.toughness)
          damage
        else
          f32(amount)
        end

      if DamageSource.is?(source, :bypasses_effects) do
        {:ok, armored}
      else
        with {:ok, resisted} <- resistance(armored, source, effects) do
          if resisted <= 0 or DamageSource.is?(source, :bypasses_enchantments) do
            {:ok, resisted}
          else
            fraction = f32(min(protection(equipment, source), 20) / 25.0)
            {:ok, f32(resisted * f32(1.0 - fraction))}
          end
        end
      end
    else
      {:error, :invalid_damage_protection}
    end
  end

  def protect(_, _, _, _), do: {:error, :invalid_damage_protection}

  @doc "Enchantment protection points of the equipment against `source`."
  def protection(equipment, source),
    do: EnchantmentEffects.protection(Armor.enchantments(equipment), DamageSource.type(source))

  @doc "Native armor and toughness reduction, without weapon-dependent effects."
  def armor_absorb(amount, armor, toughness)
      when is_number(amount) and amount >= 0 and amount <= @float_max and
             is_number(armor) and armor >= 0 and armor <= 30 and
             is_number(toughness) and toughness >= 0 and toughness <= 20 do
    amount = f32(amount)
    armor = f32(armor)
    divisor = f32(2.0 + f32(f32(toughness) / 4.0))
    effective = min(20.0, max(f32(armor * f32(0.2)), f32(armor - f32(amount / divisor))))
    {:ok, f32(amount * f32(1.0 - f32(effective / 25.0)))}
  end

  def armor_absorb(_, _, _), do: {:error, :invalid_armor_damage}

  @doc "Resistance's reduction by the active amplifier, before enchantments."
  def resistance(amount, source, effects)
      when is_number(amount) and amount >= 0 and amount <= @float_max do
    if DamageSource.known?(source) and Valimc.Living.Effects.valid?(effects) do
      amount = f32(amount)

      case effects[@resistance] do
        nil ->
          {:ok, amount}

        [{_, amplifier, _, _, _} | _] ->
          bypass =
            DamageSource.is?(source, :bypasses_effects) or
              DamageSource.is?(source, :bypasses_resistance)

          {:ok, if(bypass, do: amount, else: resist(amount, amplifier))}
      end
    else
      {:error, :invalid_resistance_damage}
    end
  end

  def resistance(_, _, _), do: {:error, :invalid_resistance_damage}

  defp resist(_amount, amplifier) when amplifier >= 4, do: 0.0

  defp resist(amount, amplifier) do
    factor = 25 - (amplifier + 1) * 5

    case <<amount * factor::float-32>> do
      <<0x7F800000::32>> ->
        # Native overflows to +infinity. Saturate its lethal magnitude for bounded
        # health arithmetic; finite native results keep their exact bits.
        @float_max

      <<product::float-32>> ->
        max(0.0, f32(product / 25.0))
    end
  end

  @doc """
  Fire Resistance immunity: vanilla's `hasEffect` tests map presence (a
  zero-duration entry counts until the effect clock removes it) for `is_fire`
  sources; amplifier and suppressed rungs do not matter.
  """
  def status_immune?(effects, source) when is_map(effects),
    do: Map.has_key?(effects, @fire_resistance) and DamageSource.is?(source, :is_fire)

  @doc "Whether equipment enchantments make the wearer immune to `source` (Frost Walker and hot floors)."
  def enchantment_immune?(equipment, source),
    do: EnchantmentEffects.immune?(Armor.enchantments(equipment), DamageSource.type(source))

  @doc "Below-world damage at height `y` in a dimension whose floor is `minimum`."
  def void(y, minimum)
      when is_number(y) and abs(y) <= 1_000_000 and is_integer(minimum) and
             abs(minimum) <= 1_000_000,
      do: if(y < minimum - 64, do: 4.0, else: 0.0)

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
