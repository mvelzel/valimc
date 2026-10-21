defmodule Valimc.PlayerCraftingTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerCraftingTransfers, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.ItemStack
  @uuid <<31::128>>
  defp snapshot(inv),
    do: %{pose: %{x: 7.5, y: 64.0, z: 3.5, yaw: 0.0, pitch: 0.0}, inventory: inv}

  defp plan(inv, gesture) do
    {action, button} = gesture
    {:ok, next, stacks} = Inventory.plan_click(inv, action, 0, button)

    records =
      Enum.with_index(stacks, 1)
      |> Enum.map(fn {stack, n} ->
        %{uuid: <<n::128>>, x: 7.5, y: 65.31999999284744, z: 3.5, stack: stack}
      end)

    {snapshot(inv), snapshot(next), records}
  end

  test "single result drop authorizes exact recipe conversion, never ordinary conservation" do
    inv = %Inventory{slots: %{1 => ItemStack.new("oak_log", 2)}}
    {before, after_snapshot, records} = plan(inv, {:throw, 0})
    assert Enum.map(records, & &1.stack) == [ItemStack.new("oak_planks", 4)]

    assert PlayerTransfers.prepare(@uuid, 3, before, after_snapshot, {0, 0}, records) ==
             {:error, :item_conservation_failed}

    assert {:ok, pending} =
             PlayerCraftingTransfers.prepare(
               @uuid,
               3,
               before,
               after_snapshot,
               {0, 0},
               records,
               {:throw, 0}
             )

    assert pending.inventory.slots == %{1 => ItemStack.new("oak_log")}
    assert pending.transfer_sequence == 4 and pending.outbox.records == records
    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, @uuid)
    assert decoded.outbox == pending.outbox and decoded.inventory.slots == pending.inventory.slots
    assert {:ok, {0, 0}, request, _} = PlayerSnapshot.transfer_request(@uuid, decoded)
    assert request.records == records and request.sequence == 4
  end

  test "forged output, ingredients, metadata, positions, gestures and source bounds refuse" do
    inv = %Inventory{slots: %{1 => ItemStack.new("oak_log", 2)}}
    {before, after_snapshot, [record] = records} = plan(inv, {:throw, 0})

    attempts = [
      {before, %{after_snapshot | inventory: inv}, {0, 0}, records, {:throw, 0}},
      {before, put_in(after_snapshot.pose.yaw, 1.0), {0, 0}, records, {:throw, 0}},
      {before, after_snapshot, {1, 0}, records, {:throw, 0}},
      {before, after_snapshot, {0, 0}, [%{record | x: 8.5}], {:throw, 0}},
      {before, after_snapshot, {0, 0}, [%{record | stack: ItemStack.new("diamond", 4)}],
       {:throw, 0}},
      {before, after_snapshot, {0, 0}, records ++ [%{record | uuid: <<2::128>>}], {:throw, 0}},
      {before, after_snapshot, {0, 0}, records, {:throw, 1}},
      {before, after_snapshot, {0, 0}, records, {:pickup, 0}},
      {before, after_snapshot, {0, 0}, records, {:quick_move, 0}},
      {snapshot(%Inventory{}), after_snapshot, {0, 0}, records, {:throw, 0}}
    ]

    for {source, target, key, rows, gesture} <- attempts,
        do:
          assert(
            PlayerCraftingTransfers.prepare(@uuid, 0, source, target, key, rows, gesture) ==
              {:error, :invalid_crafting_transfer}
          )

    for sequence <- [-1, 18_446_744_073_709_551_615],
        do:
          assert(
            PlayerCraftingTransfers.prepare(
              @uuid,
              sequence,
              before,
              after_snapshot,
              {0, 0},
              records,
              {:throw, 0}
            ) == {:error, :transfer_sequence_exhausted}
          )
  end
end
