defmodule Valimc.ChestMenu do
  @moduledoc "Native generic chest view addresses; storage authority and transactions are separate."
  alias Valimc.Inventory

  def type(rows) when rows in 1..6, do: {:ok, rows - 1}
  def type(_), do: {:error, :invalid_chest_rows}

  def address(rows, slot) when rows in 1..6 and is_integer(slot) and slot >= 0 do
    cond do
      slot < rows * 9 -> {:ok, {:container, slot}}
      slot < rows * 9 + 36 -> {:ok, slot - rows * 9 + 9}
      true -> {:error, :invalid_chest_slot}
    end
  end

  def address(_, _), do: {:error, :invalid_chest_slot}

  def contents(rows, storage, %Inventory{} = inventory)
      when rows in 1..6 and is_tuple(storage) and tuple_size(storage) == rows * 9,
      do: {:ok, Tuple.to_list(storage) ++ Enum.map(9..44, &Inventory.get(inventory, &1))}

  def contents(_, _, _), do: {:error, :invalid_chest_contents}
end
