defmodule Valimc.PlayerEnchantmentImmunity do
  @moduledoc "Stock equipment immunity from validated owned inventory; status and mode gates are separate."
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  def immune?(%Inventory{slots: slots}, source)
      when source in [:hot_floor, :campfire, :sulfur_cube_hot] do
    case slots[8] do
      %ItemStack{components: components} ->
        # Native immunity tests entry presence, including explicitly encoded level zero.
        # Supported-item tags constrain enchanting, not a patched equipped stack.
        components
        |> Map.get("minecraft:enchantments", %{})
        |> Map.has_key?("minecraft:frost_walker")

      nil ->
        false
    end
  end

  def immune?(%Inventory{}, _source), do: false
end
