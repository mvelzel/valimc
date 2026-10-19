defmodule Valimc.CookingMenuTest do
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, CookingMenu, Inventory}
  alias Valimc.Protocol.ItemStack

  test "three storage cells and player edges preserve hidden inventory without aliasing" do
    stack = ItemStack.new("coal", 7)
    cooking = %Cooking{slots: {stack, nil, stack}}
    inventory = %Inventory{slots: Map.new([1, 5, 8, 9, 35, 36, 44, 45], &{&1, stack})}
    {:ok, contents} = CookingMenu.contents(cooking, inventory)
    assert length(contents) == 39 and Enum.count(contents, &(&1 != nil)) == 6

    for {wire, address} <- [
          {0, {:cooking, 0}},
          {2, {:cooking, 2}},
          {3, 9},
          {29, 35},
          {30, 36},
          {38, 44}
        ],
        do: assert(CookingMenu.address(wire) == {:ok, address})

    assert cooking.slots == {stack, nil, stack} and inventory.slots[45] == stack
    for kind <- [:furnace, :smoker, :blast_furnace], do: assert({:ok, _} = CookingMenu.type(kind))
  end

  test "malformed progress and contents and external click sentinels refuse whole" do
    for cooking <- [
          %Cooking{slots: {}},
          %Cooking{burn_left: -1},
          %Cooking{total: 201},
          %Cooking{burn_total: 20_001},
          nil
        ] do
      assert {:error, :invalid_cooking_properties} = CookingMenu.properties(cooking)
      assert {:error, :invalid_cooking_contents} = CookingMenu.contents(cooking, %Inventory{})
    end

    for slot <- [-999, -1, 39, 45, 1.5, nil],
        do: assert(CookingMenu.address(slot) == {:error, :invalid_cooking_slot})

    assert {:error, :invalid_cooking_kind} = CookingMenu.type(:chest)
  end
end
