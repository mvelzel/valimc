defmodule Valimc.Crafting2x2Test do
  use ExUnit.Case, async: true
  alias Valimc.Crafting
  alias Valimc.Protocol.ItemStack

  test "mixed planks respect shaped orientation and placement while table ingredients share a tag" do
    oak = ItemStack.new("oak_planks")
    spruce = ItemStack.new("spruce_planks")
    assert Crafting.result([oak, nil, spruce, nil]) == {:ok, ItemStack.new("stick", 4)}
    assert Crafting.result([nil, spruce, nil, oak]) == {:ok, ItemStack.new("stick", 4)}
    assert Crafting.result([oak, spruce, nil, nil]) == :none

    assert Crafting.result([
             oak,
             spruce,
             ItemStack.new("birch_planks"),
             ItemStack.new("cherry_planks")
           ]) == {:ok, ItemStack.new("crafting_table")}
  end

  test "special recipes stay excluded while bottled honey selects its remainder recipe" do
    assert Crafting.result([ItemStack.new("paper"), ItemStack.new("gunpowder"), nil, nil]) ==
             :none

    assert Crafting.result([ItemStack.new("honey_bottle"), nil, nil, nil]) ==
             {:ok, ItemStack.new("sugar", 3)}

    assert Crafting.result([
             ItemStack.new("bowl"),
             ItemStack.new("red_mushroom"),
             ItemStack.new("brown_mushroom"),
             ItemStack.new("dandelion")
           ]) == :none

    assert Crafting.result([
             ItemStack.new("bowl"),
             ItemStack.new("red_mushroom"),
             ItemStack.new("brown_mushroom"),
             nil
           ]) == {:ok, ItemStack.new("mushroom_stew")}

    assert Crafting.result([nil, nil, nil, nil]) == :none
  end

  test "malformed grids cannot produce a crafting result" do
    for grid <- [
          [],
          [nil, nil, nil],
          [nil, nil, nil, nil, nil],
          %{},
          [ItemStack.new("oak_log", 0), nil, nil, nil],
          [%ItemStack{item_id: -1}, nil, nil, nil],
          [:forged, nil, nil, nil]
        ] do
      assert Crafting.result(grid) == {:error, :invalid_crafting_grid}
    end
  end
end
