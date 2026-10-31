defmodule Valimc.CookingLifecycleTest do
  @moduledoc """
  Removing an occupied furnace (VMC-032c5): its entry retires like a chest's,
  and the spill scatters its three slots and pays out each stored recipe's
  experience as orbs at the block's centre (`preRemoveSideEffects`).
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Cooking
  alias Valimc.Blocks.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerLifecycle, Containers}
  alias Valimc.World.ContainerSpills
  alias Valimc.Entity.Store

  defp records(store, kind),
    do: for({_, %{kind: ^kind} = entry} <- store.entries, do: entry)

  test "an occupied processor retires; its slots spill and its stored recipes pay out as orbs" do
    pos = {0, 64, 0}
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, {0, 0}, pos, :furnace)

    {:ok, iron} = Valimc.Blocks.CookingRecipes.find(ItemStack.new("raw_iron"), block)
    {:ok, gold} = Valimc.Blocks.CookingRecipes.find(ItemStack.new("raw_gold"), block)

    {:ok, xp_iron} = Valimc.Blocks.CookingRecipes.experience(iron.key)
    {:ok, xp_gold} = Valimc.Blocks.CookingRecipes.experience(gold.key)

    slots =
      {ItemStack.new("raw_iron", 5), ItemStack.new("coal", 3), ItemStack.new("iron_ingot", 9)}

    for {cooking, recipes, items, orbs} <- [
          {%Cooking{slots: slots}, %{}, 17, 0},
          {%Cooking{burn_left: 1}, %{}, 0, 0},
          {%Cooking{progress: 1, total: 200}, %{}, 0, 0},
          {%Cooking{slots: slots, burn_left: 40, burn_total: 1600, progress: 50, total: 200},
           %{iron.key => 10, gold.key => 3}, 17, floor(10 * xp_iron) + floor(3 * xp_gold)}
        ] do
      {:ok, occupied, _} =
        Containers.replace_cooking(containers, pos, entry.revision, cooking, recipes)

      held = occupied.entries[pos]

      assert {:ok, %{containers: next, removed: [%{position: ^pos, entry: ^held}] = removed}} =
               ContainerLifecycle.plan(occupied, {0, 0}, %{pos => block}, %{pos => 0})

      assert next.entries == %{}
      assert {:ok, store} = ContainerSpills.add(Store.new(), {0, 0}, removed)
      assert Enum.sum(for item <- records(store, :item), do: item.stack.count) == items

      orb_records = records(store, :orb)
      total = Enum.sum(for orb <- orb_records, do: orb.value * orb.count)
      # Each recipe's fraction adds at most one point.
      assert total >= orbs and total <= orbs + map_size(recipes)

      assert Enum.all?(
               orb_records,
               &({&1.entity.x, &1.entity.y, &1.entity.z} == {0.5, 64.5, 0.5})
             )

      # Creative removal spills the same way.
      assert {:ok, creative} = ContainerSpills.add(Store.new(), {0, 0}, removed, :creative)
      assert length(records(creative, :item)) == length(records(store, :item))
    end

    # A same-kind change (lit) keeps the occupied entry.
    {:ok, occupied, _} =
      Containers.replace_cooking(containers, pos, entry.revision, %Cooking{slots: slots}, %{})

    lit = Valimc.Data.Blocks.state("furnace", %{"facing" => "north", "lit" => "true"})

    assert {:ok, %{containers: ^occupied, removed: []}} =
             ContainerLifecycle.plan(occupied, {0, 0}, %{pos => block}, %{pos => lit})

    assert {:error, :missing_or_invalid_cooking_entry} =
             ContainerLifecycle.plan(%Containers{}, {0, 0}, %{pos => block}, %{pos => 0})
  end
end
