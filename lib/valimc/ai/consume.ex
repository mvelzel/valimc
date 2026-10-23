defmodule Valimc.AI.Consume do
  @moduledoc """
  A mob drinking (VMC-044a4: a wandering trader's potion and milk): the
  `Consumable` of the item it uses. Every fourth tick after the first
  fifth of its use it plays its consume sound (`onUseTick`,
  `emitParticlesAndSounds`, whose volume and pitch draw on the mob's random
  whatever the item); when its use is up it is consumed (`finishUsingItem`):
  the sound again, a potion's effects added (`PotionContents.onConsume`) or
  milk's clearing them, and its remainder (a glass bottle, a bucket) in
  the hand. A family may play its own consume sound (`consume_sound/2`,
  `OverrideConsumeSound`). Eating, with its item particles, is not
  modelled for mobs yet.
  """
  alias Valimc.AI.Self
  alias Valimc.Data.Float32
  alias Valimc.Living.{Effects, FoodItems}
  alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}

  @doc """
  One tick of using `stack` in `slot` after `used` ticks of use (the count
  already advanced): its sound, and its consumption when its use is up.
  """
  def tick(%Self{} = self, slot, %ItemStack{} = stack, used) do
    props = FoodItems.properties(stack)

    case props.consumable do
      %{"ticks" => duration, "animation" => "drink"} = consumable when duration > 0 ->
        remaining = duration - used

        self =
          if emits?(duration, remaining), do: sound(self, consumable, stack), else: self

        if remaining - 1 == 0, do: finish(self, slot, stack, props), else: self

      _ ->
        self
    end
  end

  # `shouldEmitParticlesAndSounds`.
  defp emits?(duration, remaining) do
    used = duration - remaining
    used > trunc(Float32.round(duration * Float32.round(0.21875))) and rem(remaining, 4) == 0
  end

  # `emitParticlesAndSounds`: an eat's volume and pitch, then a drink's, of
  # which a drink plays its own (0.5, 0.9 to 1.0).
  defp sound(self, consumable, stack) do
    {_, self} = Self.boolean(self)
    {_, self} = Self.float(self)
    {_, self} = Self.float(self)
    {c, self} = Self.float(self)
    range = Float32.round(Float32.round(1.0) - Float32.round(0.9))
    pitch = Float32.round(Float32.round(c * range) + Float32.round(0.9))

    name =
      Valimc.AI.Mobs.hook(self.type, :consume_sound, [self, stack], nil) ||
        consumable["sound"]

    Self.sound(self, name, 0.5, pitch)
  end

  # `Consumable.onConsume` and the use remainder in its hand
  # (`completeUsingItem`), then `stopUsingItem`.
  defp finish(self, slot, stack, props) do
    self = sound(self, props.consumable, stack)
    living = self.mob.living

    effects =
      case Map.fetch(stack.components, "minecraft:potion_contents") do
        {:ok, contents} ->
          add(living.effects, PotionContents.effects(contents))

        :error ->
          if props.consumable["effects"] > 0 and props.other_listeners == [],
            do: %{},
            else: add(living.effects, default_effects(stack))
      end

    mob = %{self.mob | living: %{living | effects: effects}}
    equipment = Map.put(mob.equipment, slot, props.remainder)
    self = %{self | mob: %{mob | equipment: equipment}}
    Self.stop_using(self)
  end

  defp default_effects(stack) do
    case ItemTypes.defaults(stack.item_id).values["minecraft:potion_contents"] do
      nil ->
        []

      bytes ->
        {contents, <<>>} = PotionContents.take(bytes)
        PotionContents.effects(contents)
    end
  end

  defp add(effects, list) do
    Enum.reduce(list, effects, fn {id, [rung | _]}, effects ->
      case Effects.add(effects, id, [rung]) do
        {:ok, effects, _} -> effects
        _ -> effects
      end
    end)
  end
end
