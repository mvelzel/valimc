defmodule Valimc.World.ContainerSpillsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerSpills, Items}

  defp removed(stack) do
    {:ok, state, entry} = Containers.create(%Containers{}, {0, 0}, {4, 64, 4}, 3)

    {:ok, _, entry} =
      Containers.replace(state, {4, 64, 4}, entry.revision, put_elem(entry.slots, 26, stack))

    [%{position: {4, 64, 4}, entry: entry}]
  end

  test "stored component patches survive quantity-conserving native piles and zero-delay motion" do
    stack = %{
      ItemStack.new("oak_planks", 99)
      | components: %{
          "minecraft:custom_name" => {:string, "Stored"},
          "minecraft:max_stack_size" => 99
        }
    }

    items = Items.new()
    assert {:ok, next} = ContainerSpills.add(items, {0, 0}, removed(stack))
    records = Items.records(next)
    assert length(records) in 4..10
    assert Enum.sum(Enum.map(records, & &1.stack.count)) == 99
    assert items.entries == %{}

    assert Enum.all?(records, fn record ->
             record.stack.components == stack.components and record.stack.removed == stack.removed and
               record.stack.count in 1..30 and record.x >= 4.125 and record.x < 4.875 and
               record.y >= 64 and record.y < 64.75 and record.z >= 4.125 and record.z < 4.875 and
               record.motion.pickup_delay == 0 and record.motion.age == 0 and
               Valimc.ItemMotionState.valid?(record.motion)
           end)

    assert length(Enum.uniq(Enum.map(records, & &1.uuid))) == length(records)
    assert length(Enum.uniq(Enum.map(records, &{&1.x, &1.y, &1.z}))) == 1
  end

  test "item capacity refuses the complete spill without altering the original ledger" do
    records =
      for n <- 1..255,
          do: %{uuid: <<n::128>>, x: 8.5, y: 64.0, z: 8.5, stack: ItemStack.new("stone")}

    {:ok, items} = Items.restore({0, 0}, records)

    assert {:error, :item_count_limit} =
             ContainerSpills.add(items, {0, 0}, removed(ItemStack.new("oak_planks", 64)))

    assert length(Items.records(items)) == 255
    assert {:ok, ^items} = ContainerSpills.add(items, {0, 0}, removed(nil))
  end
end
