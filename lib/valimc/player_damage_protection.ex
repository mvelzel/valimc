defmodule Valimc.PlayerDamageProtection do
  @moduledoc """
  Player-owned defenses: armor, Resistance and enchantment protection, in
  vanilla's order and decided by damage type tags and enchantment effects.
  """
  alias Valimc.{Inventory, PlayerArmor, PlayerResistance}
  alias Valimc.Physics.ArmorDamage
  alias Valimc.Protocol.ItemStack
  alias Valimc.Registry.{DamageTypes, EnchantmentEffects}
  @float_max 3.4028234663852886e38
  @fire_facts_path Path.expand("../../priv/protocol/item_armor_wear.json", __DIR__)
  @external_resource @fire_facts_path
  @exhaustion :json.decode(File.read!(@fire_facts_path))["exhaustion"]

  def wears_armor?(source), do: not DamageTypes.tag?(source, :bypasses_armor)
  def exhaustion(source), do: Map.get(@exhaustion, Atom.to_string(source), 0.0)

  @doc "Enchantment protection points of the worn and held equipment against `source`."
  def points(%Inventory{} = inventory, source),
    do: EnchantmentEffects.protection(equipment(inventory), source)

  @doc "Equipped stacks' enchantment levels by vanilla equipment slot."
  def equipment(%Inventory{slots: slots, selected: selected}) do
    for {slot, index} <- [
          mainhand: 36 + selected,
          offhand: 45,
          feet: 8,
          legs: 7,
          chest: 6,
          head: 5
        ],
        %ItemStack{components: components} <- [slots[index]],
        do: {slot, Map.get(components, "minecraft:enchantments", %{})}
  end

  @doc "Apply armor, Resistance, then enchantments after cooldown selection; wear belongs to the owner."
  def damage(inventory, source, amount, effects \\ %{})

  def damage(%Inventory{} = inventory, source, amount, effects)
      when is_atom(source) and is_number(amount) and amount >= 0 and amount <= @float_max do
    if DamageTypes.known?(source) do
      armored =
        if wears_armor?(source) do
          attributes = PlayerArmor.attributes(inventory)
          {:ok, damage} = ArmorDamage.reduce(amount, attributes.armor, attributes.toughness)
          damage
        else
          f32(amount)
        end

      # vanilla `getDamageAfterMagicAbsorb`: effects, then Resistance, then enchantments.
      if DamageTypes.tag?(source, :bypasses_effects) do
        {:ok, armored}
      else
        with {:ok, resisted} <- PlayerResistance.reduce(armored, source, effects) do
          if resisted <= 0 or DamageTypes.tag?(source, :bypasses_enchantments) do
            {:ok, resisted}
          else
            fraction = f32(min(points(inventory, source), 20) / 25.0)
            {:ok, f32(resisted * f32(1.0 - fraction))}
          end
        end
      end
    else
      {:error, :invalid_damage_protection}
    end
  end

  def damage(_, _, _, _), do: {:error, :invalid_damage_protection}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
