defmodule Valimc.PlayerFallProtection do
  @moduledoc "Player-owned worn-enchantment defenses for native fall and stalagmite sources."
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack
  @float_max 3.4028234663852886e38

  def points(%Inventory{slots: slots}) do
    # Every pinned item has empty default enchantments. Native slot matching
    # applies both effects to all four player armor slots, including patched gear.
    Enum.reduce(5..8, 0, fn slot, total ->
      case slots[slot] do
        %ItemStack{components: components} ->
          enchantments = Map.get(components, "minecraft:enchantments", %{})

          total + Map.get(enchantments, "minecraft:protection", 0) +
            3 * Map.get(enchantments, "minecraft:feather_falling", 0)

        nil ->
          total
      end
    end)
  end

  @doc "Apply native float32 protection after cooldown selection; landing bypasses ordinary armor/wear."
  def damage(%Inventory{} = inventory, amount)
      when is_number(amount) and amount >= 0 and amount <= @float_max do
    fraction = f32(min(points(inventory), 20) / 25.0)
    {:ok, f32(f32(amount) * f32(1.0 - fraction))}
  end

  def damage(_, _), do: {:error, :invalid_fall_protection}

  defp f32(number) do
    <<value::float-32>> = <<number::float-32>>
    value
  end
end
