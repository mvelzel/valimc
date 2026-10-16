defmodule Valimc.PlayerDamageProtection do
  @moduledoc "Player-owned worn-enchantment defenses for implemented environmental and periodic damage."
  alias Valimc.{Inventory, PlayerArmor, PlayerResistance}
  alias Valimc.Physics.ArmorDamage
  alias Valimc.Protocol.ItemStack
  @float_max 3.4028234663852886e38
  @fire [:in_fire, :on_fire, :lava, :hot_floor, :campfire]
  @armored [:in_fire, :lava, :hot_floor, :campfire, :cactus, :sweet_berry_bush]
  @fire_facts_path Path.expand("../../priv/protocol/item_armor_wear.json", __DIR__)
  @external_resource @fire_facts_path
  @exhaustion :json.decode(File.read!(@fire_facts_path))["exhaustion"]

  def wears_armor?(source), do: source in @armored
  def exhaustion(source), do: Map.get(@exhaustion, Atom.to_string(source), 0.0)

  def points(%Inventory{}, :out_of_world), do: 0

  def points(%Inventory{slots: slots}, source)
      when source in [
             :fall,
             :stalagmite,
             :freeze,
             :drown,
             :starve,
             :cactus,
             :sweet_berry_bush,
             :magic,
             :indirect_magic,
             :wither
           ] or
             source in @fire do
    # Every pinned item has empty default enchantments. Native slot matching
    # applies both fall effects to all four player armor slots, including patched gear.
    feather = if source in [:fall, :stalagmite], do: 3, else: 0
    fire = if source in @fire, do: 2, else: 0

    Enum.reduce(5..8, 0, fn slot, total ->
      case slots[slot] do
        %ItemStack{components: components} ->
          enchantments = Map.get(components, "minecraft:enchantments", %{})

          total + Map.get(enchantments, "minecraft:protection", 0) +
            feather * Map.get(enchantments, "minecraft:feather_falling", 0) +
            fire * Map.get(enchantments, "minecraft:fire_protection", 0)

        nil ->
          total
      end
    end)
  end

  @doc "Apply armor, Resistance, then enchantments after cooldown selection; wear belongs to the owner."
  def damage(inventory, source, amount, effects \\ %{})

  def damage(%Inventory{}, :starve, amount, effects)
      when is_number(amount) and amount >= 0 and amount <= @float_max,
      do: PlayerResistance.reduce(amount, :starve, effects)

  def damage(%Inventory{} = inventory, source, amount, effects)
      when (source in [
              :fall,
              :stalagmite,
              :freeze,
              :drown,
              :out_of_world,
              :cactus,
              :sweet_berry_bush,
              :magic,
              :indirect_magic,
              :wither
            ] or
              source in @fire) and
             is_number(amount) and
             amount >= 0 and
             amount <= @float_max do
    armored =
      if source in @armored do
        attributes = PlayerArmor.attributes(inventory)
        {:ok, damage} = ArmorDamage.reduce(amount, attributes.armor, attributes.toughness)
        damage
      else
        f32(amount)
      end

    with {:ok, resisted} <- PlayerResistance.reduce(armored, source, effects) do
      fraction = f32(min(points(inventory, source), 20) / 25.0)
      {:ok, f32(resisted * f32(1.0 - fraction))}
    end
  end

  def damage(_, _, _, _), do: {:error, :invalid_damage_protection}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
