defmodule Valimc.ItemPickupInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, Protocol.ItemStack}

  test "new pickups use the first hotbar vacancy and preserve cursor, grid and table ownership" do
    egg = ItemStack.new("egg", 3)

    original = %Inventory{
      selected: 4,
      slots: %{1 => egg, 5 => ItemStack.new("diamond_helmet")},
      carried: egg,
      table_inputs: {egg, nil, nil, nil, nil, nil, nil, nil, nil}
    }

    assert {:ok, next, nil, true} = Inventory.pickup_stack(original, ItemStack.new("stone", 7))
    assert next.slots == Map.put(original.slots, 36, ItemStack.new("stone", 7))
    assert next.carried == original.carried and next.table_inputs == original.table_inputs
    assert next.state_id == original.state_id + 1
    assert {:ok, ^original, nil, false} = Inventory.pickup_stack(original, nil)
  end

  test "selected hand, offhand and storage merge before vacancies; partial insertion has a false callback" do
    stone = ItemStack.new("stone", 64)

    slots =
      Map.new(9..44, &{&1, stone})
      |> Map.merge(%{
        40 => %{stone | count: 63},
        45 => %{stone | count: 63},
        36 => %{stone | count: 63}
      })

    original = %Inventory{selected: 4, slots: slots}

    assert {:ok, next, remainder, false} =
             Inventory.pickup_stack(original, ItemStack.new("stone", 7))

    assert remainder == ItemStack.new("stone", 4)
    assert Enum.all?([40, 45, 36], &(next.slots[&1].count == 64))
    assert {:ok, ^next, ^remainder, false} = Inventory.pickup_stack(next, remainder)
    creative = %{original | infinite_materials: true}
    assert {:ok, filled, nil, true} = Inventory.pickup_stack(creative, ItemStack.new("stone", 7))
    assert filled.slots == next.slots
    assert {:ok, ^filled, nil, true} = Inventory.pickup_stack(filled, ItemStack.new("stone", 7))
  end

  test "effective components merge while the surviving patch remains exact" do
    explicit = %{ItemStack.new("stone", 63) | components: %{"minecraft:max_stack_size" => 64}}
    original = %Inventory{selected: 3, slots: %{39 => explicit}}
    assert {:ok, next, nil, true} = Inventory.pickup_stack(original, ItemStack.new("stone", 2))
    assert next.slots[39] == %{explicit | count: 64}
    assert next.slots[36] == ItemStack.new("stone")

    named = %{
      ItemStack.new("stone")
      | components: %{"minecraft:custom_name" => {:string, "separate"}}
    }

    assert {:ok, separate, nil, true} = Inventory.pickup_stack(next, named)
    assert separate.slots[37] == named and separate.slots[39] == next.slots[39]
  end

  test "invalid stack and an oversized resulting inventory refuse atomically" do
    original = Inventory.new()

    assert {:error, :invalid_pickup_stack} =
             Inventory.pickup_stack(original, %{ItemStack.new("egg") | count: 99})

    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, 30000)}}}
        }
    }

    original = %{original | slots: Map.new(9..24, &{&1, large})}
    assert Inventory.encoded_size(original) <= 524_288

    incoming = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"bytes" => {:byte_array, :binary.copy(<<13>>, 60_000)}}}
        }
    }

    assert {:error, :inventory_byte_limit} = Inventory.pickup_stack(original, incoming)
  end
end
