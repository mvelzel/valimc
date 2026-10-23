defmodule Valimc.AI.Spawn do
  @moduledoc """
  `Mob.finalizeSpawn` (VMC-043b): what a mob decides as it enters the
  world, after it was made for a reason (`:natural`, `:spawner`,
  `:command`, `:chunk_generation`, `:jockey`, `:reinforcement`,
  `:conversion`). A mob that still has to decide carries the reason in
  `Mob.finalize`; its first tick runs this before anything else
  (`Valimc.AI.think/2`), with the section's world, so every way a mob
  appears finalizes alike.

  The level's random (`World.random`) draws what vanilla draws from
  `level.getRandom()`; the mob's own (its mind's) what vanilla draws from
  `this.random`. Every mob gets its follow range bonus and handedness; a
  family adds its own (`Valimc.AI.Mobs.finalizer/1`), which may reach the
  shared equipment rules here: armour (`populateDefaultEquipmentSlots`)
  and spawn enchantments (`populateDefaultEquipmentEnchantments`, the
  native loot engine's `selectEnchantment`). Mobs it makes (a chicken
  jockey's chicken) leave as `{:spawn, record}` effects.
  """
  alias Valimc.AI.{Mobs, Random, Self, World}
  alias Valimc.Data.{Float32, HostileFacts}
  alias Valimc.Entity.Mob
  alias Valimc.Living.LocalDifficulty
  alias Valimc.Protocol.ItemStack

  @bonus "minecraft:random_spawn_bonus"
  @follow "minecraft:follow_range"

  @doc """
  Run the pending `finalizeSpawn` of `self` (its `mob.finalize`), if any,
  and its family's; clears it.
  """
  def finalize(%Self{mob: %Mob{finalize: nil}} = self), do: self

  def finalize(%Self{mob: %Mob{finalize: reason} = mob} = self) do
    self = %{self | mob: %{mob | finalize: nil}}

    case Mobs.finalizer(self.type) do
      nil -> mob(self, reason)
      module -> module.finalize(self, reason)
    end
  end

  @doc """
  `Mob.finalizeSpawn`'s own part: a follow range bonus (a triangle of two
  doubles) unless it has one, and left-handedness one time in twenty.
  """
  def mob(%Self{} = self, _reason) do
    self =
      if has_modifier?(self.mob, @follow, @bonus) do
        self
      else
        {a, self} = level_double(self)
        {b, self} = level_double(self)
        add_modifier(self, @follow, {@bonus, 0.11485000000000001 * (a - b), 1})
      end

    {f, self} = level_float(self)
    %{self | mob: %{self.mob | left_handed: f < Float32.round(0.05)}}
  end

  @doc "The local difficulty at the mob (`getCurrentDifficultyAt`)."
  def local(%Self{world: %World{local: nil} = world}),
    do: LocalDifficulty.at(world.difficulty, world.day)

  def local(%Self{world: %World{local: local}}), do: local

  @doc "`getSpecialMultiplier` of the mob's local difficulty."
  def special(self), do: LocalDifficulty.special(local(self))

  @doc """
  `Mob.populateDefaultEquipmentSlots`: by chance (scaled by the special
  multiplier) a material, upgraded three times by chance, then a piece for
  each armour slot from the head down until a draw stops it (each after the
  first; more often on hard); an occupied slot keeps its item.
  """
  def armour(%Self{} = self) do
    {f, self} = level_float(self)

    if f < Float32.round(Float32.round(0.15) * special(self)) do
      {material, self} = level_int(self, 3)

      {material, self} =
        Enum.reduce(1..3, {material, self}, fn _, {material, self} ->
          {f, self} = level_float(self)
          {if(f < Float32.round(0.1087), do: material + 1, else: material), self}
        end)

      partial = Float32.round(if self.world.difficulty == :hard, do: 0.1, else: 0.25)

      Enum.reduce_while([:head, :chest, :legs, :feet], {true, self}, fn slot, {first, self} ->
        {stop, self} =
          if first do
            {false, self}
          else
            {f, self} = level_float(self)
            {f < partial, self}
          end

        if stop do
          {:halt, {false, self}}
        else
          self =
            if self.mob.equipment[slot],
              do: self,
              else: equip(self, slot, ItemStack.new(HostileFacts.armour(slot, material)))

          {:cont, {false, self}}
        end
      end)
      |> elem(1)
    else
      self
    end
  end

  @doc """
  `Mob.populateDefaultEquipmentEnchantments`: the main hand's item a
  quarter of the time and each armour piece half of it (scaled by the
  special multiplier), feet first, enchanted by cost
  (`EnchantmentsByCostWithDifficulty`).
  """
  def enchant_equipment(%Self{} = self) do
    special = special(self)

    [mainhand: 0.25, feet: 0.5, legs: 0.5, chest: 0.5, head: 0.5]
    |> Enum.reduce(self, fn {slot, chance}, self ->
      case self.mob.equipment[slot] do
        nil ->
          self

        stack ->
          {f, self} = level_float(self)

          if f < Float32.round(Float32.round(chance) * special) do
            {stack, self} = enchant(self, stack, special)
            equip(self, slot, stack)
          else
            self
          end
      end
    end)
  end

  # The level random's draws happen in the native enchanting.
  defp enchant(%Self{world: world} = self, stack, special) do
    {min, span, tag} = HostileFacts.enchanting()
    current = Map.get(stack.components, "minecraft:enchantments", %{}) |> Enum.to_list()

    {:ok, {enchantments, random}} =
      Valimc.Native.loot_enchant(
        Valimc.Blocks.Loot.registry(),
        Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
        current,
        min,
        span,
        special * 1.0,
        tag,
        world.random
      )

    {put_enchantments(stack, enchantments), %{self | world: %{world | random: random}}}
  end

  defp put_enchantments(stack, []), do: stack

  defp put_enchantments(stack, enchantments),
    do: %{
      stack
      | components: Map.put(stack.components, "minecraft:enchantments", Map.new(enchantments))
    }

  @doc "`setItemSlot` (the mob's equipment)."
  def equip(%Self{mob: mob} = self, slot, nil),
    do: %{self | mob: %{mob | equipment: Map.delete(mob.equipment, slot)}}

  def equip(%Self{mob: mob} = self, slot, stack),
    do: %{self | mob: %{mob | equipment: Map.put(mob.equipment, slot, stack)}}

  ## Attributes

  @doc "Whether the mob's attribute `name` has modifier `id`."
  def has_modifier?(%Mob{attributes: attributes}, name, id),
    do: Enum.any?(get_in(attributes, [name, :modifiers]) || [], &(elem(&1, 0) == id))

  @doc "`addOrReplacePermanentModifier`: `{id, amount, operation}` on attribute `name`."
  def add_modifier(%Self{mob: mob} = self, name, {id, _, _} = modifier) do
    entry = Map.get(mob.attributes, name, %{base: nil, modifiers: []})
    modifiers = Enum.reject(entry.modifiers, &(elem(&1, 0) == id)) ++ [modifier]

    %{
      self
      | mob: %{mob | attributes: Map.put(mob.attributes, name, %{entry | modifiers: modifiers})}
    }
  end

  @doc "`setBaseValue` of attribute `name`."
  def set_base(%Self{mob: mob} = self, name, base) do
    entry = Map.get(mob.attributes, name, %{base: nil, modifiers: []})
    %{self | mob: %{mob | attributes: Map.put(mob.attributes, name, %{entry | base: base * 1.0})}}
  end

  ## The level's random

  @doc "`level.getRandom().nextFloat()`."
  def level_float(self), do: level_draw(self, &Random.float/1)
  @doc "`level.getRandom().nextDouble()`."
  def level_double(self), do: level_draw(self, &Random.double/1)
  @doc "`level.getRandom().nextInt(bound)`."
  def level_int(self, bound), do: level_draw(self, &Random.int(&1, bound))

  defp level_draw(%Self{world: world} = self, fun) do
    {value, random} = fun.(world.random)
    {value, %{self | world: %{world | random: random}}}
  end

  @doc """
  Whether vanilla's `SpecialDates.isHalloween` holds on `date` (October 20 to
  November 3).
  """
  def halloween?(%Date{month: 10, day: day}), do: day >= 20
  def halloween?(%Date{month: 11, day: day}), do: day <= 3
  def halloween?(_date), do: false

  @doc "Whether no block collision meets `box` (`noCollision` without entities)."
  def fits?(%World{} = world, box), do: World.fits?(world, box)
end
