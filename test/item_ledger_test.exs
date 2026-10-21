defmodule Valimc.ItemLedgerTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, ItemRecords}

  defp record(n, x \\ 0.5),
    do: %{uuid: <<n::128>>, x: x, y: 65.5, z: 0.5, stack: ItemStack.new("stone", 3)}

  defp receipt(n), do: %{sequence: n, digest: <<n::256>>}

  defp intent(n \\ 1) do
    records =
      for id <- 2..(n + 1),
          do: Map.put(record(id, 128.5), :motion, %ItemMotionState{velocity: {0.3, -0.2, 0.1}})

    %{destination: {1, 0}, records: records, generations: Map.new(records, &{&1.uuid, 1})}
  end

  defp resign(payload), do: payload <> :crypto.hash(:sha256, payload)
  defp payload(bytes), do: binary_part(bytes, 0, byte_size(bytes) - 32)

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

  test "a full outgoing cohort and both receipt kinds roundtrip; clearance retains source sequence" do
    owned = [record(1)]
    receipts = %{<<91::128>> => receipt(3)}

    ledger = %ItemLedger{
      sequence: 7,
      outgoing: intent(32),
      incoming: %{{-1, 0} => receipt(2)},
      generations: %{<<1::128>> => 6}
    }

    assert {:ok, bytes} = ItemLedger.encode({0, 0}, owned, receipts, ledger)

    assert {:ok, %{records: ^owned, receipts: ^receipts, ledger: ^ledger}} =
             ItemLedger.decode(bytes, {0, 0})

    assert {:error, :invalid_item_ledger} = ItemLedger.decode(bytes, {1, 0})
    cleared = %{ledger | outgoing: nil}

    assert {:ok, <<"VMCLEDGR", _::binary>> = bytes} =
             ItemLedger.encode({0, 0}, owned, receipts, cleared)

    assert {:ok, %{ledger: ^cleared}} = ItemLedger.decode(bytes, {0, 0})
  end

  test "truncation, trailing bytes, wrong versions and oversized files fail closed" do
    assert {:ok, bytes} =
             ItemLedger.encode({0, 0}, [record(1)], %{}, %ItemLedger{
               sequence: 1,
               outgoing: intent()
             })

    for n <- [0, 7, 8, 21, 36, byte_size(bytes) - 1],
        do:
          assert(
            {:error, :invalid_item_ledger} = ItemLedger.decode(binary_part(bytes, 0, n), {0, 0})
          )

    assert {:error, :invalid_item_ledger} =
             ItemLedger.decode(resign(payload(bytes) <> <<0>>), {0, 0})

    <<magic::binary-size(8), _, rest::binary>> = payload(bytes)

    assert {:error, :invalid_item_ledger} =
             ItemLedger.decode(resign(<<magic::binary, 2, rest::binary>>), {0, 0})

    assert {:error, :invalid_item_ledger} =
             ItemLedger.decode(:binary.copy(<<0>>, ItemLedger.max_bytes() + 1), {0, 0})
  end
end
