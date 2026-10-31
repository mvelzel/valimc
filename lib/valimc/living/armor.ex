defmodule Valimc.Living.Armor do
  @moduledoc """
  What a living entity's equipment does for it: armor, toughness and burning
  time attributes, the enchantments it carries per slot, armor wear when hit,
  and freeze-immune wearables (vanilla `LivingEntity.hurtArmor`, the armor item
  attribute modifiers, `EnchantmentHelper` slot visits).

  Equipment is a map of stacks by vanilla slot (`:head`, `:chest`, `:legs`,
  `:feet`, `:mainhand`, `:offhand`); `equipment/1` reads it from a player
  inventory and `put_equipment/2` writes worn armor back.
  """
  alias Valimc.Data.Float32
  use Valimc.Data.Facts, "protocol/item_armor_wear.json"
  alias Valimc.Living.Durability
  alias Valimc.Menus.Inventory
  alias Valimc.Living.{Attributes, DamageSource, Enchant, Weapons}
  alias Valimc.Protocol.ItemStack

  use Valimc.Data.Facts, file: "protocol/item_armor.json", as: :armor_facts

  @defaults Map.new(@armor_facts["defaults"], fn {id, slots} ->
              {String.to_integer(id),
               Map.new(slots, fn {slot, values} ->
                 {String.to_integer(slot), List.to_tuple(values)}
               end)}
            end)
  @armor_id Attributes.fetch("armor")["id"]
  @toughness_id Attributes.fetch("armor_toughness")["id"]
  @hurt MapSet.new(@facts["damage_on_hurt"])
  @fire_resistant MapSet.new(@facts["fire_resistant"])
  @explosion_resistant MapSet.new(@facts["explosion_resistant"])
  @break_events Map.new(@facts["break_events"], fn {slot, event} ->
                  {Map.fetch!(%{"5" => :head, "6" => :chest, "7" => :legs, "8" => :feet}, slot),
                   event}
                end)
  @freeze_immune Valimc.Protocol.Data.tags()["minecraft:item"][
                   "minecraft:freeze_immune_wearables"
                 ]
                 |> MapSet.new()

  # Inventory slots of the equipment, and the slots of the default attribute facts.
  @armor_slots [head: 5, chest: 6, legs: 7, feet: 8]
  @fact_slots [head: 5, chest: 6, legs: 7, feet: 8, mainhand: 36, offhand: 45]

  @doc "A player's equipment: its worn armor, selected hotbar slot and offhand."
  def equipment(%Inventory{slots: slots, selected: selected}) do
    Map.new(
      @armor_slots ++ [mainhand: 36 + selected, offhand: 45],
      fn {slot, index} -> {slot, slots[index]} end
    )
  end

  @doc "Write worn armor from `equipment` back into a player's inventory."
  def put_equipment(%Inventory{} = inventory, equipment) do
    slots =
      Enum.reduce(@armor_slots, inventory.slots, fn {slot, index}, slots ->
        case equipment[slot] do
          nil -> Map.delete(slots, index)
          stack -> Map.put(slots, index, stack)
        end
      end)

    %{inventory | slots: slots}
  end

  @doc "The entity event of armor breaking in `slot`."
  def break_event(slot), do: Map.fetch!(@break_events, slot)

  @doc """
  The equipment's attributes: armor and toughness from its stock modifiers,
  and `enchanted`, the modifiers its enchantments add by attribute
  (`EnchantmentHelper.forEachModifier` per slot, VMC-037q) with the values
  they give a player (burning time, oxygen bonus, mining efficiency, water
  movement efficiency...); `burning_time` is one of them.
  """
  def attributes(equipment) do
    {armor, toughness} =
      Enum.reduce(@fact_slots, {0.0, 0.0}, fn {slot, fact_slot}, {armor, toughness} ->
        case equipment[slot] do
          nil ->
            {armor, toughness}

          stack ->
            {a, t} =
              if MapSet.member?(stack.removed, "minecraft:attribute_modifiers"),
                do: {0.0, 0.0},
                else: @defaults |> Map.get(stack.item_id, %{}) |> Map.get(fact_slot, {0.0, 0.0})

            {armor + a, toughness + t}
        end
      end)

    enchanted = enchanted(equipment)

    %{
      armor: floor(min(30.0, max(0.0, armor))),
      toughness: min(20.0, max(0.0, toughness)),
      burning_time: enchanted_value(enchanted, "minecraft:burning_time"),
      enchanted: enchanted
    }
  end

  # The attributes enchantments modify on a player's equipment.
  @enchanted ~w(burning_time explosion_knockback_resistance mining_efficiency oxygen_bonus
                sneaking_speed submerged_mining_speed sweeping_damage_ratio
                water_movement_efficiency)
             |> Enum.map(&("minecraft:" <> &1))

  defp enchanted(equipment) do
    modifiers =
      for slot <- [:mainhand, :offhand, :feet, :legs, :chest, :head],
          %ItemStack{} = stack <- [equipment[slot]],
          # A stored level of zero is no enchantment here, as the
          # oracles' stacks hold it.
          levels = for({_, level} = entry <- Enchant.levels(stack), level > 0, do: entry),
          {attribute, id, amount, op} <- Enchant.modifiers(levels, slot),
          do: {attribute, {id, amount, op}}

    Map.new(@enchanted, fn name ->
      {name, for({^name, modifier} <- modifiers, do: modifier)}
    end)
  end

  @doc "A player's value of attribute `name` under the equipment's enchantments (`attributes/1`)."
  def enchanted_value(%{enchanted: enchanted}, name), do: enchanted_value(enchanted, name)

  def enchanted_value(enchanted, name),
    do: Attributes.value(name, Weapons.player_base(name), Map.get(enchanted, name, []))

  @doc "The protocol attributes of `attributes/1`: the enchanted ones with their modifiers."
  def protocol_attributes(%{armor: armor, toughness: toughness} = attributes) do
    [{@armor_id, armor * 1.0, []}, {@toughness_id, toughness * 1.0, []}] ++
      for name <- @enchanted do
        {Attributes.fetch(String.trim_leading(name, "minecraft:"))["id"],
         Weapons.player_base(name), attributes.enchanted[name]}
      end
  end

  @doc "Enchantment levels by slot in vanilla's slot order, for `EnchantmentEffects`."
  def enchantments(equipment) do
    for slot <- [:mainhand, :offhand, :feet, :legs, :chest, :head],
        %ItemStack{components: components} <- [equipment[slot]],
        do: {slot, Map.get(components, "minecraft:enchantments", %{})}
  end

  @doc "The `oxygen_bonus` attribute the equipment's enchantments give (Respiration)."
  def oxygen_bonus(equipment),
    do: enchanted_value(enchanted(equipment), "minecraft:oxygen_bonus")

  @doc "Whether worn armor includes a freeze-immune wearable."
  def freeze_immune?(equipment),
    do:
      Enum.any?(Keyword.keys(@armor_slots), fn slot ->
        case equipment[slot] do
          nil -> false
          stack -> MapSet.member?(@freeze_immune, stack.item_id)
        end
      end)

  @doc """
  Wear armor for an admitted hit (`Inventory.hurtArmor`): each piece loses a
  quarter of the raw damage, at least one point: `{:ok, equipment, broken}`
  with broken `{slot, stack}` in vanilla's feet-to-head order.
  """
  def wear(equipment, source, amount, infinite, random \\ &next_float/0)

  def wear(equipment, source, amount, infinite, random)
      when is_map(equipment) and is_number(amount) and amount >= 0 and
             amount <= 3.4028234663852886e38 and is_boolean(infinite) and
             is_function(random, 0) do
    if DamageSource.known?(source) do
      amount = Float32.round(amount)

      if infinite or amount == 0 or not DamageSource.wears_armor?(source) do
        {:ok, equipment, []}
      else
        cost = trunc(max(Float32.round(amount / 4.0), 1.0))

        {equipment, broken} =
          Enum.reduce([:feet, :legs, :chest, :head], {equipment, []}, fn slot,
                                                                         {equipment, broken} ->
            stack = equipment[slot]

            case wear_piece(stack, source, cost, random) do
              {^stack, nil} -> {equipment, broken}
              {next, nil} -> {Map.put(equipment, slot, next), broken}
              {next, event} -> {Map.put(equipment, slot, next), [{slot, event} | broken]}
            end
          end)

        {:ok, equipment, Enum.reverse(broken)}
      end
    else
      {:error, :invalid_armor_wear}
    end
  end

  def wear(_, _, _, _, _), do: {:error, :invalid_armor_wear}

  defp wear_piece(nil, _source, _cost, _random), do: {nil, nil}

  defp wear_piece(%ItemStack{} = stack, source, cost, random) do
    allowed =
      MapSet.member?(@hurt, stack.item_id) and
        not MapSet.member?(stack.removed, "minecraft:equippable") and
        not (DamageSource.is?(source, :is_fire) and
               MapSet.member?(@fire_resistant, stack.item_id) and
               not MapSet.member?(stack.removed, "minecraft:damage_resistant"))

    if allowed, do: Durability.hurt_and_break(stack, cost, false, random), else: {stack, nil}
  end

  @doc """
  Whether an explosion cannot hurt `stack` as an item entity (its
  `damage_resistant` component lists explosions: the nether star).
  """
  def resists_explosion?(%ItemStack{} = stack),
    do:
      MapSet.member?(@explosion_resistant, stack.item_id) and
        not MapSet.member?(stack.removed, "minecraft:damage_resistant")

  @doc """
  Whether fire cannot hurt `stack` as an item entity (its `damage_resistant`
  component lists fire: netherite), `ItemEntity.fireImmune`.
  """
  def resists_fire?(%ItemStack{} = stack),
    do:
      MapSet.member?(@fire_resistant, stack.item_id) and
        not MapSet.member?(stack.removed, "minecraft:damage_resistant")

  defp next_float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216
end
