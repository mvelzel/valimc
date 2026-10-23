defmodule Valimc.AI.Pickup do
  @moduledoc """
  A mob picking up loot (VMC-043b, `Mob.aiStep`'s looting): while mob
  griefing is on, a living mob that can pick up loot takes the items beside
  it (its box widened a block sideways) it wants, in the section's order,
  as `Mob.pickUpItem` and `equipItemIfPossible` decide: an item goes to the
  slot it is worn in (else the main hand), only if it beats what is there
  (armour by defense then toughness, weapons by the family's preferred kind
  then damage, then by enchantments, wear and name), and what it replaces
  drops by its drop chance. A picked-up item always drops on death and the
  mob stays (`PersistenceRequired`).

  Effects: `{:pickup, item, count}` for the items it takes and `{:drop,
  stack}` for what it lets go. A family may take an item its own way
  (`pick_up/2`, a dolphin's into its mouth).
  """
  alias Valimc.AI.{Mobs, Self, World}
  alias Valimc.Data.{Float32, HostileFacts}
  alias Valimc.Entity.Mob
  alias Valimc.Living.Weapons
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @armour [:head, :chest, :legs, :feet]
  # `EnchantmentEffectComponents.PREVENT_ARMOR_CHANGE`: the curse of binding.
  @binding "minecraft:binding_curse"

  @doc "The mob's looting this tick."
  def tick(%Self{mob: %Mob{can_pick_up_loot: true} = mob, world: world} = self) do
    if world.mob_griefing and Mob.alive?(mob) do
      box = World.inflate(Self.box(self), 1.0, 0.0, 1.0)

      Enum.reduce(world.items, self, fn item, self ->
        if item.count > 0 and item.pickup_delay == 0 and
             World.intersects?(World.box(item), box) and wants?(self, item),
           do: Mobs.hook(self.type, :pick_up, [self, item], nil) || pick_up(self, item),
           else: self
      end)
    else
      self
    end
  end

  def tick(self), do: self

  defp wants?(self, item), do: Mobs.wants?(self, item.item)

  # `Mob.pickUpItem`.
  defp pick_up(self, item) do
    stack = %ItemStack{item_id: item.item, count: item.count, components: item.components}

    case equip(self, stack) do
      {0, self} ->
        self

      {count, self} ->
        self
        |> Self.effect({:pickup, World.ref(item), count})
        |> remove_item(item, count)
    end
  end

  # `equipItemIfPossible`: how many it took.
  defp equip(%Self{mob: mob} = self, stack) do
    slot = slot_for(stack)

    if equippable?(self.type, stack, slot) do
      current = mob.equipment[slot]
      replace = replace?(self, stack, current, slot)

      {slot, current, replace} =
        if slot in @armour and not replace do
          current = mob.equipment[:mainhand]
          {:mainhand, current, current == nil}
        else
          {slot, current, replace}
        end

      if replace and Mobs.can_hold?(self, stack.item_id) do
        chance = Mob.drop_chance(mob, slot)

        self =
          if current != nil do
            {f, self} = Self.float(self)

            if max(Float32.round(f - Float32.round(0.1)), 0.0) < chance,
              do: Self.effect(self, {:drop, current}),
              else: self
          else
            self
          end

        equipped = if slot in @armour, do: %{stack | count: 1}, else: stack
        self = equip_sound(self, equipped, slot)
        mob = %{self.mob | equipment: Map.put(self.mob.equipment, slot, equipped)}
        mob = %{Mob.put_drop_chance(mob, slot, 2.0) | persistent: true}
        {equipped.count, %{self | mob: mob}}
      else
        {0, self}
      end
    else
      {0, self}
    end
  end

  # `LivingEntity.onEquipItem`: an item worn where it belongs plays its
  # equip sound, seeded from the mob's random.
  defp equip_sound(self, stack, slot) do
    name = item_name(stack)

    case HostileFacts.equippable(name) do
      {^slot, _} ->
        {seed, self} = draw_long(self)
        source = Valimc.Protocol.CombatPackets.mob_sounds(self.type)["sound_source"]
        Self.effect(self, {:sound, HostileFacts.equip_sound(name), source, 1.0, 1.0, seed})

      _ ->
        self
    end
  end

  defp draw_long(%Self{mind: mind} = self) do
    {value, random} = Valimc.AI.Random.long(mind.random)
    {value, %{self | mind: %{mind | random: random}}}
  end

  # `getEquipmentSlotForItem`: where it is worn, else the main hand.
  defp slot_for(stack) do
    case HostileFacts.equippable(item_name(stack)) do
      {slot, _} -> slot
      nil -> :mainhand
    end
  end

  # `isEquippableInSlot`.
  defp equippable?(type, stack, slot) do
    case HostileFacts.equippable(item_name(stack)) do
      nil -> slot == :mainhand
      {^slot, nil} -> true
      {^slot, types} -> type in types
      _ -> false
    end
  end

  # `canReplaceCurrentItem`.
  defp replace?(_self, _new, nil, _slot), do: true

  defp replace?(self, new, current, slot) when slot in @armour do
    if Map.has_key?(enchantments(current), @binding) do
      false
    else
      defense =
        {value(self, new, "minecraft:armor", slot), value(self, current, "minecraft:armor", slot)}

      toughness =
        {value(self, new, "minecraft:armor_toughness", slot),
         value(self, current, "minecraft:armor_toughness", slot)}

      case {defense, toughness} do
        {{a, b}, _} when a != b -> a > b
        {_, {a, b}} when a != b -> a > b
        _ -> equal_better?(new, current)
      end
    end
  end

  defp replace?(self, new, current, :mainhand) do
    preferred = Mobs.preferred_weapons(self.type)
    new_preferred = preferred != nil and MapSet.member?(preferred, new.item_id)
    current_preferred = preferred != nil and MapSet.member?(preferred, current.item_id)

    cond do
      current_preferred and not new_preferred ->
        false

      new_preferred and not current_preferred ->
        true

      true ->
        a = value(self, new, "minecraft:attack_damage", :mainhand)
        b = value(self, current, "minecraft:attack_damage", :mainhand)
        if a != b, do: a > b, else: equal_better?(new, current)
    end
  end

  defp replace?(_self, _new, _current, _slot), do: false

  # `getApproximateAttributeWith`: the mob's base of the attribute (0
  # without it) through the item's modifiers in that slot.
  defp value(%Self{type: type, mob: mob}, stack, name, slot) do
    base =
      if Map.has_key?(Valimc.Data.EntityTypes.fetch(type).attributes, name),
        do: Mob.base(type, mob.attributes, name),
        else: 0.0

    Enum.reduce(Weapons.modifiers(stack, slot), base * 1.0, fn
      {^name, _, amount, 0}, acc -> acc + amount
      {^name, _, amount, 1}, acc -> acc + amount * base
      {^name, _, amount, 2}, acc -> acc + amount * acc
      _, acc -> acc
    end)
  end

  # `canReplaceEqualItem`: more enchantments, then less wear, then a name.
  defp equal_better?(new, current) do
    {a, b} = {map_size(enchantments(new)), map_size(enchantments(current))}
    {da, db} = {damage(new), damage(current)}

    cond do
      a != b ->
        a > b

      da != db ->
        da < db

      true ->
        Map.has_key?(new.components, "minecraft:custom_name") and
          not Map.has_key?(current.components, "minecraft:custom_name")
    end
  end

  defp enchantments(stack), do: Map.get(stack.components, "minecraft:enchantments", %{})
  defp damage(stack), do: Map.get(stack.components, "minecraft:damage", 0)

  defp item_name(stack), do: ItemTypes.item(stack.item_id)["name"]

  # The item has fewer for the mobs after this one.
  @doc "The world with `count` of `item` taken."
  def remove(self, item, count), do: remove_item(self, item, count)

  defp remove_item(%Self{world: world} = self, item, count) do
    items =
      for i <- world.items,
          do: if(i.uuid == item.uuid, do: %{i | count: i.count - count}, else: i)

    %{self | world: %{world | items: items}}
  end
end
