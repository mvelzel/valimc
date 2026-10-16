defmodule Valimc.PlayerCraftingInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack

  defp click(inv, action, slot, button \\ 0) do
    assert {:ok, next, []} = Inventory.plan_click(inv, action, slot, button)
    next
  end

  test "grid clicks derive output without creating an owned result; both buttons craft once" do
    for creative <- [false, true], button <- [0, 1], slot <- 1..4 do
      inv = %Inventory{infinite_materials: creative, slots: %{36 => ItemStack.new("oak_log", 2)}}
      inv = inv |> click(:pickup, 36) |> click(:pickup, slot)
      assert inv.carried == nil and Inventory.get(inv, slot).count == 2
      assert Inventory.crafting_result(inv) == ItemStack.new("oak_planks", 4)
      assert hd(Inventory.display_contents(inv)) == ItemStack.new("oak_planks", 4)
      assert hd(Inventory.contents(inv)) == nil and Inventory.get(inv, 0) == nil
      next = click(inv, :pickup, 0, button)
      assert next.carried == ItemStack.new("oak_planks", 4)
      assert Inventory.get(next, slot) == ItemStack.new("oak_log")
      final = click(next, :pickup, 0, button)
      assert final.carried == ItemStack.new("oak_planks", 8)
      assert final.slots == %{} and Inventory.crafting_result(final) == nil
      assert click(final, :pickup, 0).carried == final.carried
    end
  end

  test "a complete result must fit the cursor with effective identity unchanged" do
    for button <- [0, 1], count <- 60..64 do
      inv = %Inventory{
        slots: %{1 => ItemStack.new("oak_log", 2)},
        carried: ItemStack.new("oak_planks", count)
      }

      next = click(inv, :pickup, 0, button)
      assert next.carried.count == if(count == 60, do: 64, else: count)
      assert next.slots[1].count == if(count == 60, do: 1, else: 2)
    end

    for cursor <- [
          ItemStack.new("stone"),
          %{
            ItemStack.new("oak_planks")
            | components: %{"minecraft:enchantment_glint_override" => true}
          }
        ] do
      inv = %Inventory{slots: %{1 => ItemStack.new("oak_log", 2)}, carried: cursor}
      assert click(inv, :pickup, 0).slots == inv.slots
      assert click(inv, :pickup, 0).carried == cursor
    end
  end

  test "mixed tags consume exactly one per occupied cell and preserve remaining input patches" do
    patched = %{
      ItemStack.new("oak_planks", 3)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    inv = %Inventory{slots: %{2 => patched, 4 => ItemStack.new("spruce_planks", 2)}}
    assert Inventory.crafting_result(inv) == ItemStack.new("stick", 4)
    next = click(inv, :pickup, 0)
    assert next.carried == ItemStack.new("stick", 4)
    assert next.slots == %{2 => %{patched | count: 2}, 4 => ItemStack.new("spruce_planks")}
    inv = %Inventory{slots: Map.new(1..4, &{&1, ItemStack.new("oak_planks")})}
    next = click(inv, :pickup, 0)
    assert next.carried == ItemStack.new("crafting_table") and next.slots == %{}
  end

  test "cleanup and persisted state contain physical inputs/output only" do
    inv = %Inventory{slots: %{1 => ItemStack.new("oak_log", 2)}} |> click(:pickup, 0)
    assert {:ok, closed, []} = Inventory.close(inv)
    assert closed.slots == %{36 => ItemStack.new("oak_planks", 4), 37 => ItemStack.new("oak_log")}
    assert {:ok, empty, drops} = Inventory.disconnect(inv)
    assert drops == [ItemStack.new("oak_planks", 4), ItemStack.new("oak_log")]
    assert empty.slots == %{} and empty.carried == nil
    assert {:ok, dead, death_drops, []} = Inventory.death_batch(inv)
    assert death_drops == drops and dead.slots == %{} and dead.carried == nil
    snapshot = %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: inv}
    assert {:ok, bytes} = PlayerSnapshot.encode(<<123::128>>, snapshot)
    assert {:ok, saved} = PlayerSnapshot.decode(bytes, <<123::128>>)
    assert saved.inventory.slots == inv.slots and saved.inventory.carried == inv.carried
    assert Inventory.get(saved.inventory, 0) == nil
    assert Inventory.crafting_result(saved.inventory) == ItemStack.new("oak_planks", 4)
    assert {:ok, after_cleanup, key, records} = Valimc.PlayerTransfers.plan_disconnect(snapshot)
    assert Enum.map(records, & &1.stack) == drops

    assert {:ok, _} =
             Valimc.PlayerTransfers.prepare(
               <<123::128>>,
               0,
               snapshot,
               after_cleanup,
               key,
               records
             )

    duplicate = %{hd(records) | uuid: <<99::128>>, stack: Inventory.crafting_result(inv)}

    assert {:error, :item_conservation_failed} =
             Valimc.PlayerTransfers.prepare(
               <<123::128>>,
               0,
               snapshot,
               after_cleanup,
               key,
               records ++ [duplicate]
             )
  end

  test "unsupported result gestures cannot convert ingredients or create ordinary drop plans" do
    inv = %Inventory{infinite_materials: true, slots: %{1 => ItemStack.new("oak_log", 2)}}

    for action <- [:throw, :quick_move, :swap, :clone], button <- [0, 1] do
      assert Inventory.plan_click(inv, action, 0, button) == {:error, :unsupported_click}
    end

    inv = %{inv | carried: ItemStack.new("oak_log")}
    assert click(inv, :pickup_all, 0).slots == inv.slots
    assert click(inv, :pickup_all, 0).carried == inv.carried

    assert {:ok, dragging} =
             Inventory.click(%{inv | carried: ItemStack.new("oak_planks")}, :quick_craft, -999, 0)

    interrupted = click(dragging, :pickup, 0)
    assert interrupted.drag == nil and interrupted.slots == inv.slots
    assert interrupted.carried == dragging.carried
  end

  test "grid transfer/drag use input slots, with armor returning to storage rather than equipping" do
    inv = %Inventory{slots: %{1 => ItemStack.new("iron_helmet")}}
    next = click(inv, :quick_move, 1)
    assert next.slots == %{9 => ItemStack.new("iron_helmet")}
    inv = %Inventory{slots: %{36 => ItemStack.new("oak_log", 2)}} |> click(:swap, 4)
    assert inv.slots == %{4 => ItemStack.new("oak_log", 2)}
    inv = %Inventory{carried: ItemStack.new("oak_planks", 4)}
    inv = click(inv, :quick_craft, -999, 0)
    inv = Enum.reduce(0..4, inv, &click(&2, :quick_craft, &1, 1))
    inv = click(inv, :quick_craft, -999, 2)
    assert inv.carried == nil and Inventory.get(inv, 0) == nil
    assert Inventory.crafting_result(inv) == ItemStack.new("crafting_table")
    expected = Enum.map(Inventory.display_contents(inv), &ItemStack.encode/1)
    assert Inventory.encoded_size(inv) == IO.iodata_length([ItemStack.encode(nil), expected])
  end
end
