defmodule Valimc.MiningRecordTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{ItemRecords, MiningRecord}
  alias Valimc.Protocol.{Data, ItemStack}

  defp fixture do
    source = <<1::128>>
    receipt = %{source => %{sequence: 1, digest: :crypto.hash(:sha256, "mining")}}
    record = %{uuid: <<2::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("stone", 3)}
    {:ok, items} = ItemRecords.encode({0, 0}, [record], receipt)
    {items, record, receipt}
  end

  defp resign(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "proposal keeps block changes and the exact conserved item/receipt ledger together" do
    {items, record, receipt} = fixture()
    edits = %{{0, 64, 0} => 0, {1, 64, 0} => Data.block("dirt")}
    assert {:ok, bytes} = MiningRecord.encode({0, 0}, edits, items)
    assert byte_size(bytes) <= MiningRecord.max_bytes()

    assert {:ok,
            %{
              edits: ^edits,
              item_bytes: ^items,
              ledger: %{records: [^record], receipts: ^receipt}
            }} = MiningRecord.decode(bytes, {0, 0})

    assert {:error, :invalid_mining_record} = MiningRecord.decode(bytes, {1, 0})

    for length <- [0, 7, 27, byte_size(bytes) - 1],
        do:
          assert(
            MiningRecord.decode(binary_part(bytes, 0, length), {0, 0}) ==
              {:error, :invalid_mining_record}
          )

    assert {:error, :invalid_mining_record} = MiningRecord.decode(bytes <> <<0>>, {0, 0})

    maximum = Map.new(0..4095, fn i -> {{rem(i, 128), 64, div(i, 128)}, 0} end)
    assert {:ok, max_bytes} = MiningRecord.encode({0, 0}, maximum, items)
    assert {:ok, %{edits: ^maximum}} = MiningRecord.decode(max_bytes, {0, 0})
  end

  test "valid checksums do not authorize duplicate edits, out-of-owner state or an invalid ledger" do
    {items, _, _} = fixture()
    header = <<"VMCMINE", 1, 5023::32, 0::signed-32, 0::signed-32>>
    row = <<0::signed-32, 64::signed-32, 0::signed-32, 0::16>>

    duplicate =
      <<header::binary, 2::16, byte_size(items)::32, row::binary, row::binary, items::binary>>

    assert {:error, :invalid_mining_record} = MiningRecord.decode(resign(duplicate), {0, 0})

    <<byte, rest::binary>> = items
    corrupt_items = <<Bitwise.bxor(byte, 1), rest::binary>>

    invalid_ledger =
      <<header::binary, 1::16, byte_size(items)::32, row::binary, corrupt_items::binary>>

    assert {:error, :invalid_mining_record} = MiningRecord.decode(resign(invalid_ledger), {0, 0})

    for {x, y, block} <- [{128, 64, 0}, {0, -65, 0}, {0, 64, Data.block_state_count()}] do
      invalid =
        <<header::binary, 1::16, byte_size(items)::32, x::signed-32, y::signed-32, 0::signed-32,
          block::16, items::binary>>

      assert {:error, :invalid_mining_record} = MiningRecord.decode(resign(invalid), {0, 0})

      assert {:error, :invalid_mining_record} =
               MiningRecord.encode({0, 0}, %{{x, y, 0} => block}, items)
    end

    assert {:error, :invalid_mining_record} =
             MiningRecord.encode({0, 0}, %{{0, 64, 0} => 0}, <<"invalid">>)

    assert {:error, :invalid_mining_record} = MiningRecord.encode({0, 0}, %{}, items)
    too_many = Map.new(0..4096, fn i -> {{rem(i, 128), 64, div(i, 128)}, 0} end)
    assert {:error, :invalid_mining_record} = MiningRecord.encode({0, 0}, too_many, items)
    {:ok, bytes} = MiningRecord.encode({0, 0}, %{{0, 64, 0} => 0}, items)
    <<prefix::binary-size(30), byte, rest::binary>> = bytes

    assert {:error, :invalid_mining_record} =
             MiningRecord.decode(<<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>, {0, 0})
  end
end
