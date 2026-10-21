defmodule Valimc.PlayerEnchantmentImmunity do
  @moduledoc "Equipment immunity (frost walker against stepping burns) from enchantment effects; status and mode gates are separate."
  alias Valimc.{Inventory, PlayerDamageProtection}
  alias Valimc.Registry.EnchantmentEffects

  def immune?(%Inventory{} = inventory, source),
    do: EnchantmentEffects.immune?(PlayerDamageProtection.equipment(inventory), source)
end
