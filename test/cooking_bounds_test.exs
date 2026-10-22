defmodule Valimc.CookingBoundsTest do
  # Vanilla cooking facts are compared by the cooking_* oracle stages; these are
  # the refusals for player-supplied slots, edits and item patches.
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, Inventory, Menu}
  alias Valimc.CookingBlocks
  alias Valimc.CookingFuel
  alias Valimc.Protocol.{Data, ItemStack}

  test "click sentinels, malformed edits and unsupported patches refuse whole" do
    for slot <- [-2, 39, 45, 1.5, nil],
        do: assert(Menu.address(Menu.cooking(nil), slot) == {:error, :invalid_menu_slot})

    for cooking <- [%Cooking{slots: {}}, %Cooking{burn_left: -1}, %Cooking{total: 201}, nil] do
      assert {:error, :invalid_cooking_properties} = Menu.properties(cooking)
      assert {:error, :invalid_menu_contents} = Menu.cooking_contents(cooking, %Inventory{})
    end

    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    state = %Cooking{slots: {ItemStack.new("raw_iron", 3), nil, nil}, progress: 49, total: 123}

    for slots <- [{ItemStack.new("coal", 99), nil, nil}, {}, {nil, :invalid, nil}],
        do: assert({:error, :invalid_cooking_edit} = Cooking.edit_slots(state, slots, block))

    coal = ItemStack.new("coal", 4)

    assert CookingFuel.resolve(%{coal | components: %{"minecraft:cooking_fuel" => 1}}, block) ==
             {:error, :unsupported_cooking_fuel}

    assert CookingFuel.resolve(coal, Data.block("stone")) ==
             {:error, :unsupported_furnace_context}
  end
end
