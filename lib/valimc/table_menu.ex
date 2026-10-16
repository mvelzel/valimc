defmodule Valimc.TableMenu do
  @moduledoc "Native table slot addresses over player-owned inputs and storage."
  alias Valimc.Inventory

  def address(0), do: {:ok, 0}
  def address(slot) when slot in 1..9, do: {:ok, {:table, slot - 1}}
  def address(slot) when slot in 10..45, do: {:ok, slot - 1}
  def address(slot) when slot in [-1, -999], do: {:ok, slot}
  def address(_), do: {:error, :invalid_table_slot}

  def contents(%Inventory{table_inputs: cells} = inventory)
      when is_tuple(cells) and tuple_size(cells) == 9,
      do:
        [Inventory.crafting_result(inventory) | Tuple.to_list(cells)] ++
          Enum.map(9..44, &Inventory.get(inventory, &1))

  def plan_click(%Inventory{table_inputs: cells} = inventory, action, slot, button)
      when is_tuple(cells) and tuple_size(cells) == 9 do
    with {:ok, address} <- address(slot),
         do: Inventory.plan_click(inventory, action, address, button)
  end

  def plan_click(_, _, _, _), do: {:error, :table_not_open}
end
