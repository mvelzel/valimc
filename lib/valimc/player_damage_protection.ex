defmodule Valimc.PlayerDamageProtection do
  @moduledoc "Player-owned worn-enchantment defenses for fall, stalagmite and freezing."
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack
  @float_max 3.4028234663852886e38

  def points(%Inventory{slots: slots}, source) when source in [:fall, :stalagmite, :freeze] do
    # Every pinned item has empty default enchantments. Native slot matching
    # applies both fall effects to all four player armor slots, including patched gear.
    feather = if source == :freeze, do: 0, else: 3

    Enum.reduce(5..8, 0, fn slot, total ->
      case slots[slot] do
        %ItemStack{components: components} ->
          enchantments = Map.get(components, "minecraft:enchantments", %{})

          total + Map.get(enchantments, "minecraft:protection", 0) +
            feather * Map.get(enchantments, "minecraft:feather_falling", 0)

        nil ->
          total
      end
    end)
  end

  @doc "Apply native float32 protection after cooldown selection; these sources bypass armor/wear."
  def damage(%Inventory{} = inventory, source, amount)
      when source in [:fall, :stalagmite, :freeze] and is_number(amount) and amount >= 0 and
             amount <= @float_max do
    fraction = f32(min(points(inventory, source), 20) / 25.0)
    {:ok, f32(f32(amount) * f32(1.0 - fraction))}
  end

  def damage(_, _, _), do: {:error, :invalid_damage_protection}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
