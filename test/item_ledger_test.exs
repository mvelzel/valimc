defmodule Valimc.ItemLedgerTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, ItemRecords}

  defp record(n, x \\ 0.5),
    do: %{uuid: <<n::128>>, x: x, y: 65.5, z: 0.5, stack: ItemStack.new("stone", 3)}

  defp receipt(n), do: %{sequence: n, digest: <<n::256>>}

  test "empty ledgers preserve exact legacy record bytes, checksums and player receipts" do
    for {records, receipts} <- [
          {[record(1)], %{}},
          {[record(1)], %{<<91::128>> => receipt(1)}},
          {[Map.put(record(1), :motion, %ItemMotionState{pickup_delay: 40})],
           %{<<91::128>> => receipt(1)}}
        ] do
      assert {:ok, expected} = ItemRecords.encode({0, 0}, records, receipts)
      assert {:ok, ^expected} = ItemLedger.encode({0, 0}, records, receipts)

      assert {:ok,
              %{
                records: ^records,
                receipts: ^receipts,
                ledger: %ItemLedger{sequence: 0, outgoing: nil, incoming: %{}, generations: %{}}
              }} = ItemLedger.decode(expected, {0, 0})
    end
  end
end
