defmodule Valimc.CookingClickTest do
  use ExUnit.Case, async: true
  alias Valimc.{CookingClick, Inventory}
  alias Valimc.CookingBlocks

  defp plan(storage, inventory, action, slot, button \\ 0, kind \\ :furnace) do
    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    CookingClick.plan(block, storage, inventory, action, slot, button)
  end

  test "unsupported gestures, active crafting and foreign contexts refuse without a partial plan" do
    for action <- [:quick_craft, :pickup_all, :clone, :throw],
        do:
          assert(
            {:error, :unsupported_cooking_click} = plan({nil, nil, nil}, %Inventory{}, action, 0)
          )

    assert {:error, :unsupported_cooking_click} =
             plan({nil, nil, nil}, %Inventory{table_inputs: Tuple.duplicate(nil, 9)}, :pickup, 0)

    assert {:error, :unsupported_cooking_click} = plan({}, %Inventory{}, :pickup, 0)

    assert {:error, :unsupported_cooking_click} =
             CookingClick.plan(0, {nil, nil, nil}, %Inventory{}, :pickup, 0, 0)
  end
end
