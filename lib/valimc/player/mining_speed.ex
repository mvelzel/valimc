defmodule Valimc.Player.MiningSpeed do
  @moduledoc "Stock player mining speed/harvest; the player owner supplies current gear and eye/ground contact."
  alias Valimc.Menus.Inventory
  alias Valimc.Blocks.Mining
  alias Valimc.Blocks.MiningTools
  alias Valimc.Protocol.ItemStack

  def attributes(inventory) do
    efficiency = enchantment(Inventory.held(inventory, :main), "minecraft:efficiency")
    aqua = enchantment(Inventory.get(inventory, 5), "minecraft:aqua_affinity")

    %{
      mining_efficiency:
        if(efficiency > 0, do: min(1024.0, efficiency * efficiency + 1.0), else: 0.0),
      block_break_speed: 1.0,
      submerged_mining_speed: min(20.0, 0.2 * (1.0 + 4.0 * aqua))
    }
  end

  def speed(inventory, state, water, on_ground)
      when is_boolean(water) and is_boolean(on_ground) do
    base = MiningTools.speed(Inventory.held(inventory, :main), state)
    attributes = attributes(inventory)
    speed = if base > 1, do: f32(base + f32(attributes.mining_efficiency)), else: base
    speed = if water, do: f32(speed * f32(attributes.submerged_mining_speed)), else: speed
    if on_ground or speed == :infinity, do: speed, else: f32(speed / 5.0)
  end

  def harvest?(inventory, state),
    do:
      not Mining.requires_tool?(state) or
        MiningTools.correct_tool?(Inventory.held(inventory, :main), state)

  def rate(inventory, state, water, on_ground),
    do: Mining.rate(state, speed(inventory, state, water, on_ground), harvest?(inventory, state))

  defp enchantment(nil, _name), do: 0

  defp enchantment(%ItemStack{components: components}, name),
    do: components |> Map.get("minecraft:enchantments", %{}) |> Map.get(name, 0)

  defp f32(value) do
    case <<value::float-32>> do
      <<0::1, 255::8, 0::23>> -> :infinity
      <<rounded::float-32>> -> rounded
    end
  end
end
