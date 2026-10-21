defmodule Valimc.PlayerCraftingInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack

  defp click(inv, action, slot, button \\ 0) do
    assert {:ok, next, []} = Inventory.plan_click(inv, action, slot, button)
    next
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
end
