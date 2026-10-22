defmodule Valimc.Player.Equipment do
  @moduledoc "Six-slot inventory observations for peer rendering, never inventory authority."
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.ItemStack

  def capture(inventory) do
    [
      {0, Inventory.held(inventory, :main)},
      {1, Inventory.held(inventory, :off)},
      {2, Inventory.get(inventory, 8)},
      {3, Inventory.get(inventory, 7)},
      {4, Inventory.get(inventory, 6)},
      {5, Inventory.get(inventory, 5)}
    ]
    |> Enum.reject(fn {_, stack} -> is_nil(stack) end)
    |> Map.new()
  end

  def changes(current, previous) when current == previous, do: []

  def changes(current, previous) do
    for slot <- 0..5, not same?(current[slot], previous[slot]), do: {slot, current[slot]}
  end

  defp same?(nil, nil), do: true

  defp same?(%ItemStack{count: count} = a, %ItemStack{count: count} = b),
    do: ItemStack.same_item?(a, b)

  defp same?(_, _), do: false
end
