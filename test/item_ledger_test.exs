defmodule Valimc.ItemLedgerTest do
  use ExUnit.Case, async: true
  import Bitwise
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

  test "invalid ownership, source sequences, batch bounds and overlapping authorities refuse" do
    base = %ItemLedger{sequence: 1, outgoing: intent()}
    shared = record(1, 128.5)

    bad = [
      %{base | sequence: 0},
      %{base | sequence: -1},
      %{base | sequence: 18_446_744_073_709_551_616},
      %{base | outgoing: intent(33)},
      %{base | outgoing: %{intent() | records: [], generations: %{}}},
      %{base | outgoing: %{intent() | destination: {0, 0}}},
      %{base | outgoing: %{intent() | generations: %{}}},
      %{base | outgoing: %{intent() | generations: %{<<2::128>> => 0}}},
      %{base | outgoing: %{intent() | records: [shared], generations: %{shared.uuid => 1}}},
      %{base | generations: %{<<1::128>> => 0}},
      %{base | generations: %{<<99::128>> => 1}},
      %{base | incoming: %{{0, 0} => receipt(1)}},
      %{base | incoming: %{{1, 0} => %{sequence: 0, digest: <<1::256>>}}},
      %{base | incoming: %{{1, 0} => %{sequence: 1, digest: <<0>>}}},
      Map.put(base, :unknown, true),
      %{},
      nil
    ]

    for ledger <- bad,
        do:
          assert(
            {:error, :invalid_item_ledger} = ItemLedger.encode({0, 0}, [record(1)], %{}, ledger)
          )
  end

  test "region receipts reach their cap and refuse one more without changing player encoding" do
    incoming = Map.new(1..4096, fn n -> {{n, 0}, receipt(n)} end)
    ledger = %ItemLedger{incoming: incoming}
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, [], %{}, ledger)
    assert {:ok, %{ledger: ^ledger}} = ItemLedger.decode(bytes, {0, 0})

    assert {:error, :invalid_item_ledger} =
             ItemLedger.encode({0, 0}, [], %{}, %{
               ledger
               | incoming: Map.put(incoming, {4097, 0}, receipt(1))
             })
  end

  test "valid outer checksums cannot hide reordered/duplicate metadata or damaged nested records" do
    ledger = %ItemLedger{sequence: 1, incoming: %{{-2, 0} => receipt(2), {-1, 0} => receipt(1)}}
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, [record(1)], %{}, ledger)
    <<_::binary-size(33), length::32, _::binary>> = bytes
    offset = 37 + length

    <<prefix::binary-size(^offset), a::binary-size(48), b::binary-size(48), tail::binary>> =
      payload(bytes)

    for changed <- [[prefix, b, a, tail], [prefix, a, a, tail]] do
      assert {:error, :invalid_item_ledger} =
               ItemLedger.decode(changed |> IO.iodata_to_binary() |> resign(), {0, 0})
    end

    <<before::binary-size(^offset - 1), byte, after_byte::binary>> = payload(bytes)
    damaged = resign(<<before::binary, bxor(byte, 1), after_byte::binary>>)
    assert {:error, :invalid_item_ledger} = ItemLedger.decode(damaged, {0, 0})
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, [], %{}, %ItemLedger{sequence: 1})
    <<prefix::binary-size(21), _::64, tail::binary>> = payload(bytes)

    assert {:error, :invalid_item_ledger} =
             ItemLedger.decode(resign(<<prefix::binary, 0::64, tail::binary>>), {0, 0})
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
