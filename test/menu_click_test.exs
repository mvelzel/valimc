defmodule Valimc.MenuClickTest do
  # Vanilla's click results are compared by the chest_click, cooking_click,
  # table_menu_click and player_crafting stages; these are the refusals and the
  # menu descriptions they rely on.
  use ExUnit.Case, async: true
  alias Valimc.{CookingBlocks, Inventory, Menu, MenuClick}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.ContainerRequest

  defp furnace do
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    Menu.cooking(block)
  end

  test "each menu addresses only its own slots and contents" do
    assert Menu.address(Menu.chest(3), 26) == {:ok, {:container, 26}}
    assert Menu.address(Menu.chest(3), 27) == {:ok, 9}
    assert Menu.address(Menu.chest(3), 63) == {:error, :invalid_menu_slot}
    assert Menu.address(Menu.table(), 1) == {:ok, {:table, 0}}
    assert Menu.address(Menu.table(), 45) == {:ok, 44}
    assert Menu.address(furnace(), 2) == {:ok, {:cooking, 2}}
    assert Menu.address(furnace(), 39) == {:error, :invalid_menu_slot}

    for slot <- [-2, 46, 1.5, nil],
        do: assert(Menu.address(Menu.inventory(), slot) == {:error, :invalid_menu_slot})

    assert Menu.contents(Menu.chest(3), {}, %Inventory{}) == {:error, :invalid_menu_contents}

    assert MenuClick.plan(Menu.table(), nil, Inventory.new(), :pickup, 1, 0) ==
             {:error, :table_not_open}

    table_open = %Inventory{table_inputs: Tuple.duplicate(nil, 9)}

    assert MenuClick.plan(furnace(), {nil, nil, nil}, table_open, :pickup, 0, 0) ==
             {:error, :unsupported_click}
  end

  test "an item with its own click and a swap past a slot's limit are refused whole" do
    storage = Tuple.duplicate(ItemStack.new("bedrock", 64), 27)
    inventory = %Inventory{slots: %{36 => ItemStack.new("diamond", 3)}}
    bundle = put_elem(storage, 0, ItemStack.new("bundle"))

    assert MenuClick.plan(Menu.chest(3), bundle, inventory, :pickup, 0, 0) ==
             {:error, :unsupported_click}

    oversized = put_elem(storage, 0, ItemStack.new("diamond_sword", 2))

    assert MenuClick.plan(Menu.chest(3), oversized, inventory, :swap, 0, 0) ==
             {:error, :unsupported_click}

    # A shift-click into a full chest leaves both sides exact.
    assert {:ok, ^storage, next, []} =
             MenuClick.plan(Menu.chest(3), storage, inventory, :quick_move, 54, 0)

    assert next.slots == inventory.slots
  end

  test "a container request carries no drag and no gesture that drops into the world" do
    request = %{
      rows: 3,
      slots: Tuple.duplicate(nil, 27),
      inventory: %Inventory{carried: ItemStack.new("stone", 2)},
      action: :pickup,
      slot: -999,
      button: 0
    }

    assert ContainerRequest.plan(request) == {:error, :world_drop_required}

    assert ContainerRequest.plan(%{request | action: :throw}) ==
             {:error, :unsupported_container_click}

    dragging = %{
      request
      | inventory: %{request.inventory | drag: %{mode: 0, slots: MapSet.new()}}
    }

    assert ContainerRequest.plan(%{dragging | slot: 0}) == {:error, :unsupported_container_click}
  end
end
