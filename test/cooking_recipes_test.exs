defmodule Valimc.CookingRecipesTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingRecipes
  alias Valimc.Physics.CookingItems
  alias Valimc.Protocol.{Data, ItemStack}

  test "selected stock recipes distinguish furnace, smoker and blast furnace with native speed contexts" do
    furnace = Data.item_block(Data.item("furnace"))
    smoker = Data.item_block(Data.item("smoker"))
    blast = Data.item_block(Data.item("blast_furnace"))
    ore = ItemStack.new("raw_iron", 3)
    assert {:ok, normal} = CookingRecipes.find(ore, furnace)

    assert normal.result == ItemStack.new("iron_ingot") and normal.base_ticks == 200 and
             normal.cook_ticks == 200

    assert normal.experience == 0.7 |> f32()
    assert {:ok, fast} = CookingRecipes.find(ore, blast, 2.0)
    assert fast.result == normal.result and fast.cook_ticks == 100
    assert :none = CookingRecipes.find(ore, smoker, 2.0)
    assert {:ok, fish} = CookingRecipes.find(ItemStack.new("cod"), smoker, 2.0)
    assert fish.result == ItemStack.new("cooked_cod") and fish.cook_ticks == 100
    assert :none = CookingRecipes.find(ItemStack.new("cod"), blast, 2.0)
    assert :none = CookingRecipes.find(nil, furnace)
    assert :none = CookingRecipes.find(ItemStack.new("diamond"), furnace)
  end

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

  defp f32(value) do
    <<result::float-32>> = <<value::float-32>>
    result
  end
end
