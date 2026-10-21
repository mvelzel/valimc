defmodule Valimc.ContainerClickTest do
  use ExUnit.Case, async: true
  alias Valimc.{ContainerClick, Inventory}
  alias Valimc.Protocol.ItemStack

  test "packed storage leaves the source exact; unsupported gestures, overrides and drag refuse whole" do
    storage = Tuple.duplicate(ItemStack.new("bedrock", 64), 27)
    inventory = %Inventory{slots: %{36 => ItemStack.new("diamond", 3)}}
    assert {:ok, ^storage, next} = ContainerClick.plan(3, storage, inventory, :quick_move, 54, 0)
    assert next.slots == inventory.slots

    for {action, wire, button} <- [
          {:throw, 0, 0},
          {:clone, 0, 2},
          {:quick_craft, 0, 0},
          {:pickup_all, 0, 0},
          {:pickup, -999, 0},
          {:pickup, 63, 0}
        ] do
      assert {:error, _} = ContainerClick.plan(3, storage, inventory, action, wire, button)
    end

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(
               3,
               storage,
               %{inventory | drag: %{mode: 0, slots: MapSet.new()}},
               :pickup,
               0,
               0
             )

    bundle = put_elem(storage, 0, ItemStack.new("bundle"))

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(3, bundle, inventory, :pickup, 0, 0)

    oversized = put_elem(storage, 0, ItemStack.new("diamond_sword", 2))

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(3, oversized, inventory, :swap, 0, 0)
  end
end
