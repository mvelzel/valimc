defmodule Valimc.Crafting3x3Test do
  use ExUnit.Case, async: true
  alias Valimc.Crafting
  alias Valimc.Protocol.ItemStack

  defp grid(names),
    do:
      Enum.map(names, fn
        nil -> nil
        name -> ItemStack.new(name)
      end)

  test "table shapes accept mixed tags and preserve their empty cells" do
    assert Crafting.result(
             grid([
               "oak_planks",
               "spruce_planks",
               "birch_planks",
               nil,
               "stick",
               nil,
               nil,
               "stick",
               nil
             ])
           ) == {:ok, ItemStack.new("wooden_pickaxe")}

    assert Crafting.result(
             grid([
               "cobblestone",
               "cobbled_deepslate",
               "blackstone",
               nil,
               "stick",
               nil,
               nil,
               "stick",
               nil
             ])
           ) == {:ok, ItemStack.new("stone_pickaxe")}

    assert Crafting.result(
             grid([
               "iron_ingot",
               nil,
               "iron_ingot",
               "iron_ingot",
               "iron_ingot",
               "iron_ingot",
               "iron_ingot",
               "iron_ingot",
               "iron_ingot"
             ])
           ) == {:ok, ItemStack.new("iron_chestplate")}

    assert Crafting.result(
             grid([
               "oak_planks",
               "spruce_planks",
               "birch_planks",
               "stick",
               nil,
               nil,
               "stick",
               nil,
               nil
             ])
           ) == :none
  end

  test "nine-cell shapeless assignment preserves multiplicities, including mixed materials" do
    names = ["sand", "gravel", "red_dye", "gravel", "sand", "sand", "gravel", "sand", "gravel"]
    assert Crafting.result(grid(names)) == {:ok, ItemStack.new("red_concrete_powder", 8)}

    assert Crafting.result(grid(Enum.reverse(names))) ==
             {:ok, ItemStack.new("red_concrete_powder", 8)}

    assert Crafting.result(grid(List.replace_at(names, 1, "sand"))) == :none

    names = [
      "netherite_scrap",
      "gold_ingot",
      "gold_ingot",
      nil,
      "netherite_scrap",
      "gold_ingot",
      "netherite_scrap",
      "gold_ingot",
      "netherite_scrap"
    ]

    assert Crafting.result(grid(names)) == {:ok, ItemStack.new("netherite_ingot")}

    assert Crafting.result(grid(List.duplicate("iron_ingot", 9))) ==
             {:ok, ItemStack.new("iron_block")}
  end

  test "native special shadows stay excluded, cake selects and grid bounds remain explicit" do
    assert Crafting.result(grid([nil, "brick", nil, "brick", nil, "brick", nil, "brick", nil])) ==
             :none

    assert Crafting.result(
             grid(["paper", "gunpowder", "gunpowder", "gunpowder", nil, nil, nil, nil, nil])
           ) == :none

    assert Crafting.result(
             grid([
               "milk_bucket",
               "milk_bucket",
               "milk_bucket",
               "sugar",
               "egg",
               "sugar",
               "wheat",
               "wheat",
               "wheat"
             ])
           ) == {:ok, ItemStack.new("cake")}

    assert Crafting.result(List.duplicate(nil, 9)) == :none

    for count <- [0, 1, 8, 10],
        do:
          assert(Crafting.result(List.duplicate(nil, count)) == {:error, :invalid_crafting_grid})

    assert Crafting.result(grid(["oak_log", nil, nil, nil])) ==
             {:ok, ItemStack.new("oak_planks", 4)}
  end
end
