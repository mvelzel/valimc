defmodule Valimc.CookingMenu do
  @moduledoc "Native furnace-family view addresses and progress; region state remains authoritative."
  alias Valimc.{Cooking, Inventory}

  def type(:furnace), do: {:ok, 14}
  def type(:smoker), do: {:ok, 22}
  def type(:blast_furnace), do: {:ok, 10}
  def type(_), do: {:error, :invalid_cooking_kind}

  def address(slot) when slot in 0..2, do: {:ok, {:cooking, slot}}
  def address(slot) when slot in 3..38, do: {:ok, slot + 6}
  def address(_), do: {:error, :invalid_cooking_slot}

  def contents(%Cooking{} = cooking, %Inventory{} = inventory) do
    if Cooking.valid?(cooking),
      do: {:ok, Tuple.to_list(cooking.slots) ++ Enum.map(9..44, &Inventory.get(inventory, &1))},
      else: {:error, :invalid_cooking_contents}
  end

  def contents(_, _), do: {:error, :invalid_cooking_contents}

  def properties(%Cooking{} = cooking) do
    if Cooking.valid?(cooking),
      do: {:ok, [cooking.burn_left, cooking.burn_total, cooking.progress, cooking.total]},
      else: {:error, :invalid_cooking_properties}
  end

  def properties(_), do: {:error, :invalid_cooking_properties}
end
