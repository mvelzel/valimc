defmodule Valimc.CookingLifecycleTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.{CookingBlocks, Placement}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.{ContainerLifecycle, Containers, ContainerSpills, CookingEntry, Items}

  test "native facing candidates survive saved-intent validation and named stacks refuse before consumption" do
    for kind <- [:furnace, :smoker, :blast_furnace], yaw <- [0.0, 90.0, 180.0, 270.0] do
      item = Data.item(Atom.to_string(kind))
      request = %{position: {0, 64, 0}, face: 1, cursor: {0.5, 0.5, 0.5}, yaw: yaw}
      assert {:ok, candidate} = Placement.candidate(item, 0, 0, request)
      assert CookingBlocks.kind(candidate.state) == kind

      assert {:ok, ^candidate} =
               Placement.saved_candidate(item, 0, 0, Map.delete(request, :yaw), %{
                 {0, 64, 0} => candidate.state
               })

      named = %{
        ItemStack.new(Atom.to_string(kind))
        | components: %{"minecraft:custom_name" => {:string, "Named"}}
      }

      refute Placement.supported_stack?(named)
    end
  end

  test "empty processing replacement retires before creating and same-kind orientation retains metadata" do
    pos = {0, 64, 0}
    {:ok, first} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, turned} = CookingBlocks.placement(:furnace, 90.0)
    {:ok, other} = CookingBlocks.placement(:smoker, 180.0)
    receipts = %{<<1::128>> => %{sequence: 77, digest: <<2::256>>}}
    initial = %Containers{receipts: receipts}

    {:ok, %{containers: created, removed: []}} =
      ContainerLifecycle.plan(initial, {0, 0}, %{pos => 0}, %{pos => first})

    entry = created.entries[pos]
    assert CookingEntry.empty?(entry) and entry.kind == :furnace

    assert {:ok, %{containers: ^created, removed: []}} =
             ContainerLifecycle.plan(created, {0, 0}, %{pos => first}, %{pos => turned})

    {:ok, %{containers: replaced, removed: [removed]}} =
      ContainerLifecycle.plan(created, {0, 0}, %{pos => first}, %{pos => other})

    assert removed.entry == entry and replaced.entries[pos].kind == :smoker
    assert replaced.entries[pos].revision == 3 and replaced.receipts == receipts
    assert {:ok, %Items{}} = ContainerSpills.add(Items.new(), {0, 0}, [removed])
  end

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
               ContainerSpills.add(Items.new(), {0, 0}, [
                 %{position: pos, entry: occupied.entries[pos]}
               ])
    end

    {:ok, recipe} = Valimc.CookingRecipes.find(ItemStack.new("raw_iron"), block)

    {:ok, used, _} =
      Containers.replace_cooking(containers, pos, entry.revision, %Cooking{}, %{recipe.key => 1})

    assert {:error, :occupied_cooking_entry} =
             ContainerLifecycle.plan(used, {0, 0}, %{pos => block}, %{pos => 0})

    assert {:error, :missing_or_invalid_cooking_entry} =
             ContainerLifecycle.plan(%Containers{}, {0, 0}, %{pos => block}, %{pos => 0})
  end
end
