defmodule Valimc.ChestMenuTest do
  use ExUnit.Case, async: true
  alias Valimc.{ChestMenu, Inventory}
  alias Valimc.Protocol.ItemStack

  test "single and double chest boundaries map to storage, main inventory and hotbar" do
    for {rows, count} <- [{3, 27}, {6, 54}] do
      assert {:ok, {:container, 0}} = ChestMenu.address(rows, 0)
      assert {:ok, {:container, last}} = ChestMenu.address(rows, count - 1)
      assert last == count - 1
      assert {:ok, 9} = ChestMenu.address(rows, count)
      assert {:ok, 35} = ChestMenu.address(rows, count + 26)
      assert {:ok, 36} = ChestMenu.address(rows, count + 27)
      assert {:ok, 44} = ChestMenu.address(rows, count + 35)
      assert {:error, :invalid_chest_slot} = ChestMenu.address(rows, count + 36)
      assert {:ok, type} = ChestMenu.type(rows)
      assert type == rows - 1
    end
  end

  test "view excludes player armor/offhand/crafting and keeps independent container storage" do
    item = ItemStack.new("diamond", 3)
    storage = put_elem(Tuple.duplicate(nil, 27), 26, item)
    inventory = %Inventory{slots: %{1 => item, 5 => item, 9 => item, 36 => item, 45 => item}}
    assert {:ok, view} = ChestMenu.contents(3, storage, inventory)
    assert length(view) == 63 and Enum.at(view, 26) == item and Enum.at(view, 27) == item
    assert Enum.at(view, 54) == item and Enum.count(view, &(&1 != nil)) == 3
    assert elem(storage, 26) == item and inventory.slots[45] == item
  end

  test "bad dimensions and special click sentinels do not become physical slot addresses" do
    for rows <- [0, 7, nil, 3.5],
        do: assert(ChestMenu.type(rows) == {:error, :invalid_chest_rows})

    for slot <- [-999, -1, nil, 1.5, 1000],
        do: assert(ChestMenu.address(3, slot) == {:error, :invalid_chest_slot})

    assert {:error, :invalid_chest_contents} = ChestMenu.contents(3, {}, %Inventory{})
  end

  test "offhand correction addresses the physical inventory independently of chest cells" do
    for stack <- [nil, ItemStack.new("oak_planks", 7)] do
      {id, body} = Valimc.Protocol.Packets.player_inventory_slot(40, stack)
      assert id == Valimc.Protocol.Data.id(:play, :clientbound, "set_player_inventory")
      {40, bytes} = Valimc.Protocol.Wire.take_varint(IO.iodata_to_binary(body))
      assert {:ok, ^stack, <<>>} = ItemStack.take(bytes)
    end
  end
end
