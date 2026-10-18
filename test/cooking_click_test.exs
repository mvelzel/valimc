defmodule Valimc.CookingClickTest do
  use ExUnit.Case, async: true
  alias Valimc.{CookingClick, Inventory}
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack

  defp plan(storage, inventory, action, slot, button \\ 0, kind \\ :furnace) do
    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    CookingClick.plan(block, storage, inventory, action, slot, button)
  end

  test "manual fuel placement caps an empty bucket at one and preserves its remaining cursor" do
    buckets = ItemStack.new("bucket", 15)
    inventory = %Inventory{carried: buckets}

    assert {:ok, {nil, bucket, nil}, after_inventory, 0} =
             plan({nil, nil, nil}, inventory, :pickup, 1)

    assert bucket.count == 1 and after_inventory.carried.count == 14
    stone = ItemStack.new("stone", 17)
    inventory = %Inventory{carried: stone}

    assert {:ok, {nil, nil, nil}, %{carried: ^stone}, 0} =
             plan({nil, nil, nil}, inventory, :pickup, 1)
  end

  test "a noninsertable output can only join a matching cursor when the whole output fits" do
    output = ItemStack.new("iron_ingot", 63)
    inventory = %Inventory{carried: ItemStack.new("iron_ingot", 2)}

    assert {:ok, {nil, nil, ^output}, %{carried: %{count: 2}}, 0} =
             plan({nil, nil, output}, inventory, :pickup, 2)

    inventory = %{inventory | carried: ItemStack.new("iron_ingot")}

    assert {:ok, {nil, nil, nil}, %{carried: %{count: 64}}, 63} =
             plan({nil, nil, output}, inventory, :pickup, 2, 1)

    inventory = %{inventory | carried: ItemStack.new("coal")}

    assert {:ok, {nil, nil, ^output}, %{carried: %{count: 1}}, 0} =
             plan({nil, nil, output}, inventory, :pickup, 2)
  end

  test "shift gives recipes priority over fuel and a full input does not redirect into fuel" do
    log = ItemStack.new("oak_log", 17)
    inventory = %Inventory{slots: %{9 => log}}

    assert {:ok, {^log, nil, nil}, %{slots: %{}}, 0} =
             plan({nil, nil, nil}, inventory, :quick_move, 3)

    full = ItemStack.new("oak_log", 64)

    assert {:ok, {^full, nil, nil}, %{slots: %{9 => ^log}}, 0} =
             plan({full, nil, nil}, inventory, :quick_move, 3)
  end

  test "shift withdraws output in reverse player order and other storage in forward order" do
    stack = ItemStack.new("coal", 7)

    for {storage, wire, target} <- [
          {{stack, nil, nil}, 0, 9},
          {{nil, stack, nil}, 1, 9},
          {{nil, nil, stack}, 2, 44}
        ] do
      assert {:ok, {nil, nil, nil}, inventory, taken} =
               plan(storage, %Inventory{}, :quick_move, wire)

      assert inventory.slots == %{target => stack}
      assert taken == if(wire == 2, do: 7, else: 0)
    end
  end

  test "empty buckets shift between player areas and fuel removal suppresses shift admission" do
    buckets = ItemStack.new("bucket", 15)

    assert {:ok, {nil, nil, nil}, %{slots: %{36 => ^buckets}}, 0} =
             plan({nil, nil, nil}, %Inventory{slots: %{9 => buckets}}, :quick_move, 3)

    removed = %{ItemStack.new("coal", 7) | removed: MapSet.new(["minecraft:cooking_fuel"])}

    assert {:ok, {nil, nil, nil}, %{slots: %{36 => ^removed}}, 0} =
             plan({nil, nil, nil}, %Inventory{slots: %{9 => removed}}, :quick_move, 3)

    assert {:ok, {nil, nil, nil}, %{carried: ^removed}, 0} =
             plan({nil, nil, nil}, %Inventory{carried: removed}, :pickup, 1)
  end

  test "number and offhand gestures never deposit into output or partially apply oversized swaps" do
    output = ItemStack.new("iron_ingot", 7)
    coal = ItemStack.new("coal", 17)
    inventory = %Inventory{slots: %{36 => coal, 45 => coal}}

    for button <- [0, 40] do
      assert {:ok, {nil, nil, ^output}, after_inventory, 0} =
               plan({nil, nil, output}, inventory, :swap, 2, button)

      assert after_inventory.slots == inventory.slots
    end

    inventory = %Inventory{slots: %{45 => ItemStack.new("bucket", 15)}}
    assert {:error, :unsupported_cooking_click} = plan({nil, nil, nil}, inventory, :swap, 1, 40)
    assert inventory.slots[45].count == 15

    assert {:ok, {nil, nil, nil}, %{slots: %{36 => ^output}}, 7} =
             plan({nil, nil, output}, %Inventory{}, :swap, 2)
  end

  test "patched identities stay distinct and hidden cells/cursor survive unrelated shift" do
    plain = ItemStack.new("coal", 63)

    named = %{
      ItemStack.new("coal", 7)
      | components: %{"minecraft:custom_name" => {:string, "Fuel"}}
    }

    inventory = %Inventory{
      slots: %{1 => named, 5 => named, 9 => plain, 45 => named},
      carried: named
    }

    assert {:ok, {nil, nil, nil}, after_inventory, 7} =
             plan({nil, nil, named}, inventory, :quick_move, 2)

    assert after_inventory.slots[44] == named and after_inventory.slots[9] == plain

    assert after_inventory.slots[1] == named and after_inventory.slots[5] == named and
             after_inventory.slots[45] == named

    assert after_inventory.carried == named and after_inventory.state_id == 1
  end

  test "unsupported gestures, active crafting and foreign contexts refuse without a partial plan" do
    for action <- [:quick_craft, :pickup_all, :clone, :throw],
        do:
          assert(
            {:error, :unsupported_cooking_click} = plan({nil, nil, nil}, %Inventory{}, action, 0)
          )

    assert {:error, :unsupported_cooking_click} =
             plan({nil, nil, nil}, %Inventory{table_inputs: Tuple.duplicate(nil, 9)}, :pickup, 0)

    assert {:error, :unsupported_cooking_click} = plan({}, %Inventory{}, :pickup, 0)

    assert {:error, :unsupported_cooking_click} =
             CookingClick.plan(0, {nil, nil, nil}, %Inventory{}, :pickup, 0, 0)
  end
end
