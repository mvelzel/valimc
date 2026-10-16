defmodule Valimc.Crafting2x2Test do
  use ExUnit.Case, async: true
  alias Valimc.Crafting
  alias Valimc.Protocol.ItemStack

  test "log tags match every player cell without carrying input count or components into the result" do
    for name <- ~w(oak_log stripped_oak_log oak_wood stripped_oak_wood), slot <- 0..3 do
      input = %{
        ItemStack.new(name, 17)
        | components: %{"minecraft:enchantment_glint_override" => true}
      }

      grid = List.replace_at([nil, nil, nil, nil], slot, input)
      assert Crafting.result(grid) == {:ok, ItemStack.new("oak_planks", 4)}
    end

    assert Crafting.result([ItemStack.new("bamboo_block"), nil, nil, nil]) ==
             {:ok, ItemStack.new("bamboo_planks", 2)}
  end

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

  test "asymmetric shears mirror and shapeless ingredients ignore slot order" do
    iron = ItemStack.new("iron_ingot")
    assert Crafting.result([nil, iron, iron, nil]) == {:ok, ItemStack.new("shears")}
    assert Crafting.result([iron, nil, nil, iron]) == {:ok, ItemStack.new("shears")}

    assert Crafting.result([iron, iron, nil, nil]) ==
             {:ok, ItemStack.new("heavy_weighted_pressure_plate")}

    assert Crafting.result([nil, ItemStack.new("flint"), iron, nil]) ==
             {:ok, ItemStack.new("flint_and_steel")}
  end

  test "special recipes and remainders never fall back to a plain output" do
    assert Crafting.result([ItemStack.new("paper"), ItemStack.new("gunpowder"), nil, nil]) ==
             :none

    assert Crafting.result([ItemStack.new("honey_bottle"), nil, nil, nil]) == :none

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
