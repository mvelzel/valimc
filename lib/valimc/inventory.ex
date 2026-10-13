defmodule Valimc.Inventory do
  @moduledoc "Bounded player-menu state owned entirely by its connection process."
  defstruct slots: %{}, selected: 0, carried: nil, state_id: 0
  def new, do: %__MODULE__{}
  def get(inventory, slot), do: inventory.slots[slot]
  def contents(inventory), do: Enum.map(0..45, &get(inventory, &1))
  def advance(inventory), do: %{inventory | state_id: rem(inventory.state_id + 1, 32768)}
  def held(inventory, :main), do: get(inventory, 36 + inventory.selected)
  def held(inventory, :off), do: get(inventory, 45)

  def creative(inventory, slot, stack) when is_integer(slot) and slot in 1..45,
    do: {:ok, inventory |> put(slot, stack) |> advance()}

  def creative(_, _, _), do: {:error, :invalid_slot}

  def select(inventory, slot) when is_integer(slot) and slot in 0..8,
    do: {:ok, %{inventory | selected: slot}}

  def select(_, _), do: {:error, :invalid_selection}

  def swap_hands(inventory) do
    main = held(inventory, :main)
    off = held(inventory, :off)

    inventory
    |> put(36 + inventory.selected, off)
    |> put(45, main)
    |> advance()
  end

  defp put(inventory, slot, nil), do: %{inventory | slots: Map.delete(inventory.slots, slot)}

  defp put(inventory, slot, stack),
    do: %{inventory | slots: Map.put(inventory.slots, slot, stack)}
end
