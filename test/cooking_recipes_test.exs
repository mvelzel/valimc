defmodule Valimc.CookingRecipesTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingRecipes
  alias Valimc.Physics.CookingItems
  alias Valimc.Protocol.{Data, ItemStack}

  test "input patches/count survive selection without leaking to result and failed output remains atomic" do
    furnace = Data.item_block(Data.item("furnace"))

    raw = %{
      ItemStack.new("raw_iron", 64)
      | components: %{"minecraft:custom_name" => {:string, "Raw"}}
    }

    assert {:ok, recipe} = CookingRecipes.find(raw, furnace)
    assert recipe.result == ItemStack.new("iron_ingot")

    assert CookingItems.finish({raw, nil, ItemStack.new("iron_ingot", 64)}, recipe.result) ==
             {:error, :output_full}

    assert {:ok, {%ItemStack{count: 63} = remaining, nil, _}} =
             CookingItems.finish({raw, nil, nil}, recipe.result)

    assert remaining.components == raw.components
    assert CookingRecipes.find(%{raw | count: 0}, furnace) == {:error, :invalid_cooking_input}
    assert CookingRecipes.find(raw, furnace, 1.5) == {:error, :unsupported_cooking_speed}
    assert CookingRecipes.find(raw, Data.block("stone")) == {:error, :unsupported_furnace_context}
  end
end
