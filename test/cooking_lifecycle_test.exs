defmodule Valimc.CookingLifecycleTest do
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Cooking
  alias Valimc.Blocks.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerLifecycle, Containers}
  alias Valimc.Entity.{ContainerSpills, Store}

  test "items, remaining heat, progress and recipe uses independently block processor removal" do
    pos = {0, 64, 0}
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, {0, 0}, pos, :furnace)

    for cooking <- [
          %Cooking{slots: {ItemStack.new("raw_iron"), nil, nil}},
          %Cooking{burn_left: 1},
          %Cooking{progress: 1, total: 200}
        ] do
      {:ok, occupied, _} =
        Containers.replace_cooking(containers, pos, entry.revision, cooking, %{})

      assert {:error, :occupied_cooking_entry} =
               ContainerLifecycle.plan(occupied, {0, 0}, %{pos => block}, %{pos => 0})

      assert {:error, :occupied_cooking_entry} =
               ContainerSpills.add(Store.new(), {0, 0}, [
                 %{position: pos, entry: occupied.entries[pos]}
               ])
    end

    {:ok, recipe} = Valimc.Blocks.CookingRecipes.find(ItemStack.new("raw_iron"), block)

    {:ok, used, _} =
      Containers.replace_cooking(containers, pos, entry.revision, %Cooking{}, %{recipe.key => 1})

    assert {:error, :occupied_cooking_entry} =
             ContainerLifecycle.plan(used, {0, 0}, %{pos => block}, %{pos => 0})

    assert {:error, :missing_or_invalid_cooking_entry} =
             ContainerLifecycle.plan(%Containers{}, {0, 0}, %{pos => block}, %{pos => 0})
  end
end
