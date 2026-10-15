defmodule Valimc.PlayerAir do
  @moduledoc "Bounded player air primitives; the owner supplies fresh contact, ticks and random draws."
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack
  @maximum 300

  def maximum, do: @maximum
  def valid?(air), do: is_integer(air) and air in -20..@maximum

  # The pinned Respiration attribute effect applies to the head slot only.
  # Other native items/enchantments contribute no default oxygen modifier.
  def oxygen_bonus(%Inventory{slots: slots}) do
    case slots[5] do
      %ItemStack{components: components} ->
        components
        |> Map.get("minecraft:enchantments", %{})
        |> Map.get("minecraft:respiration", 0)

      nil ->
        0
    end
  end

  def decrease(air, oxygen, draw)
      when is_integer(air) and air in -20..@maximum and is_number(oxygen) and
             oxygen >= 0 and oxygen <= 1024 and is_number(draw) and draw >= 0 and draw < 1 do
    if oxygen > 0 and draw >= 1.0 / (oxygen + 1.0), do: air, else: air - 1
  end

  def increase(air) when is_integer(air) and air in -20..@maximum,
    do: min(@maximum, air + 4)

  def drowning?(air) when is_integer(air), do: air <= -20
end
