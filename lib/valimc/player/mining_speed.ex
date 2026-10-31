defmodule Valimc.Player.MiningSpeed do
  @moduledoc """
  Stock player mining speed/harvest; the player owner supplies current gear,
  eye/ground contact and its effects (Haste and Conduit Power, Mining
  Fatigue). Enchantments act through their attributes (`attributes/1`).
  """
  alias Valimc.Menus.Inventory
  alias Valimc.Blocks.Mining
  alias Valimc.Blocks.MiningTools
  alias Valimc.Living.Armor

  @doc """
  The mining attributes the held tool's and the helmet's enchantments give
  (Efficiency's `mining_efficiency`, Aqua Affinity's `submerged_mining_speed`),
  through the enchantment engine (VMC-037q).
  """
  def attributes(inventory) do
    attributes =
      Armor.attributes(%{
        mainhand: Inventory.held(inventory, :main),
        head: Inventory.get(inventory, 5)
      })

    %{
      mining_efficiency: Armor.enchanted_value(attributes, "minecraft:mining_efficiency"),
      block_break_speed: 1.0,
      submerged_mining_speed:
        Armor.enchanted_value(attributes, "minecraft:submerged_mining_speed")
    }
  end

  @fatigue Valimc.Data.EffectTypes.id("mining_fatigue")
  @haste Valimc.Data.EffectTypes.id("haste")
  @conduit Valimc.Data.EffectTypes.id("conduit_power")

  def speed(inventory, state, water, on_ground, effects \\ %{})
      when is_boolean(water) and is_boolean(on_ground) do
    base = MiningTools.speed(Inventory.held(inventory, :main), state)
    attributes = attributes(inventory)
    speed = if base > 1, do: f32(base + f32(attributes.mining_efficiency)), else: base
    speed = dig_speed(speed, effects)
    speed = fatigue(speed, Valimc.Living.Attributes.amplifier(effects, @fatigue))
    speed = if water, do: f32(speed * f32(attributes.submerged_mining_speed)), else: speed
    if on_ground or speed == :infinity, do: speed, else: f32(speed / 5.0)
  end

  def harvest?(inventory, state),
    do:
      not Mining.requires_tool?(state) or
        MiningTools.correct_tool?(Inventory.held(inventory, :main), state)

  def rate(inventory, state, water, on_ground, effects \\ %{}),
    do:
      Mining.rate(
        state,
        speed(inventory, state, water, on_ground, effects),
        harvest?(inventory, state)
      )

  # Haste or Conduit Power (`MobEffectUtil.getDigSpeedAmplification`, the
  # larger amplifier): `1 + (level + 1) * 0.2` times the speed.
  defp dig_speed(speed, effects) do
    haste = Valimc.Living.Attributes.amplifier(effects, @haste)
    conduit = Valimc.Living.Attributes.amplifier(effects, @conduit)

    cond do
      haste == nil and conduit == nil -> speed
      speed == :infinity -> :infinity
      true -> f32(speed * f32(1.0 + f32((max(haste || 0, conduit || 0) + 1) * f32(0.2))))
    end
  end

  # Mining Fatigue: `0.3^(level + 1)` of the speed.
  defp fatigue(speed, nil), do: speed
  defp fatigue(:infinity, _level), do: :infinity
  defp fatigue(speed, level), do: f32(speed * f32(:math.pow(0.3, level + 1)))

  defp f32(value) do
    case <<value::float-32>> do
      <<0::1, 255::8, 0::23>> -> :infinity
      <<rounded::float-32>> -> rounded
    end
  end
end
