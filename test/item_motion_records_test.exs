defmodule Valimc.ItemMotionRecordsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, ItemMotionState, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemRecords, Items, ItemTransfers}
  @key {-1, -1}
  @source <<19::128>>
  @receipts %{@source => %{sequence: 1, digest: <<23::256>>}}

  defp record(n \\ 37),
    do: %{uuid: <<n::128>>, x: -0.5, y: 64.25, z: -128.0, stack: ItemStack.new("stone", 7)}

  defp moving(n \\ 37),
    do:
      Map.put(record(n), :motion, %ItemMotionState{
        velocity: {0.3, 0.1, -0.2},
        pickup_delay: 40
      })

  test "legacy v1/v2 bytes retain the pre-motion checkpoint hashes used by receipts" do
    for {receipts, hash} <- [
          {%{}, "b4265dc7cf297772bd43d2687007c71029e3d871e8ab190591427585572e1556"},
          {@receipts, "c82a4c3f3eccfae6fb5f6a8113faffc2d0fbe0f1dd40401c9d3552644e9d05ad"}
        ] do
      assert {:ok, bytes} = ItemRecords.encode(@key, [record()], receipts)
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
      assert ItemRecords.decode(bytes, @key) == {:ok, %{records: [record()], receipts: receipts}}
    end
  end

  test "mixed v3 records retain bounded motion and receipts through restore and stack replacement" do
    moving = moving()

    for {age, delay, ground, gravity} <- [
          {-32_768, 32_767, false, false},
          {-6000, 40, true, false},
          {5999, 0, false, true},
          {6000, 1, true, true}
        ] do
      motion = %{
        moving.motion
        | age: age,
          pickup_delay: delay,
          on_ground: ground,
          no_gravity: gravity
      }

      records = [record(1), %{moving | motion: motion}]

      assert {:ok, <<"VMCITEMS", 3, _::binary>> = bytes} =
               ItemRecords.encode(@key, records, @receipts)

      assert ItemRecords.decode(bytes, @key) == {:ok, %{records: records, receipts: @receipts}}
      assert {:ok, state} = Items.restore(@key, records)
      assert Items.records(state) == records
      assert {:ok, handle} = Items.find(state, moving.uuid)
      {epoch, id, revision} = handle

      assert {:ok, replaced, _} =
               Items.replace(state, epoch, id, revision, ItemStack.new("stone", 3))

      assert Enum.find(Items.records(replaced), &(&1.uuid == moving.uuid)).motion == motion
      assert {:ok, _} = ItemRecords.encode(@key, Items.records(replaced), @receipts)
    end
  end

  test "v3 player outboxes round-trip exact launch intent and its canonical digest" do
    snapshot = %{
      pose: %{x: -0.5, y: 63.0, z: -128.0, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{},
      transfer_sequence: 4,
      outbox: %{key: @key, records: [moving()]}
    }

    assert {:ok, bytes} = PlayerSnapshot.encode(@source, snapshot)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @source)
    assert restored.outbox == snapshot.outbox

    assert PlayerSnapshot.transfer_request(@source, restored) ==
             PlayerSnapshot.transfer_request(@source, snapshot)
  end

  test "removed moving records keep receipts so recovery cannot recreate them" do
    request = %{source: @source, sequence: 1, records: [moving()]}
    assert {:ok, items, receipts, :applied} = ItemTransfers.plan(Items.new(), %{}, @key, request)
    assert Items.records(items) == [moving()]
    assert {:ok, {epoch, id, revision}} = Items.find(items, moving().uuid)
    assert {:ok, empty} = Items.remove(items, epoch, id, revision)

    assert {:ok, <<"VMCITEMS", 2, _::binary>> = bytes} =
             ItemRecords.encode(@key, Items.records(empty), receipts)

    assert {:ok, %{records: [], receipts: recovered_receipts}} = ItemRecords.decode(bytes, @key)
    assert {:ok, recovered} = Items.restore(@key, [])

    assert {:ok, ^recovered, ^recovered_receipts, :already_applied} =
             ItemTransfers.plan(recovered, recovered_receipts, @key, request)

    forged = %{moving() | motion: %{moving().motion | velocity: {1, 0, 0}}}

    assert {:error, :transfer_conflict} =
             ItemTransfers.plan(recovered, recovered_receipts, @key, %{
               request
               | records: [forged]
             })
  end

  test "invalid motion cannot silently become a legacy stationary record" do
    for motion <- [
          nil,
          %{},
          %ItemMotionState{velocity: {65, 0, 0}},
          %ItemMotionState{velocity: [0, 0, 0]},
          %ItemMotionState{age: -32_769},
          %ItemMotionState{age: 6001},
          %ItemMotionState{pickup_delay: -1},
          %ItemMotionState{pickup_delay: 32_768},
          %ItemMotionState{on_ground: nil},
          %ItemMotionState{no_gravity: nil},
          Map.delete(%ItemMotionState{}, :age)
        ] do
      record = Map.put(record(), :motion, motion)
      refute ItemMotionState.valid?(motion)
      assert ItemRecords.encode(@key, [record]) == {:error, :invalid_item_records}
      assert Items.restore(@key, [record]) == {:error, :invalid_item_file}
      assert Items.create_record(Items.new(), @key, record) == {:error, :invalid_item}
    end
  end

  test "checksummed invalid motion flags, counters, floats and truncated frames fail closed" do
    prefix = <<37::128, -0.5::float-64, 64.25::float-64, -128.0::float-64>>
    stack = record().stack |> ItemStack.encode() |> IO.iodata_to_binary()

    seal = fn motion ->
      payload =
        <<"VMCITEMS", 3, 5023::32, -1::signed-32, -1::signed-32, 1::16, 0::16>> <>
          prefix <> motion <> stack

      payload <> :crypto.hash(:sha256, payload)
    end

    for motion <- [
          <<0>>,
          <<1>>,
          <<2>>,
          <<9, 0::192, 0::32>>,
          <<1, 65.0::float-64, 0::128, 0::32>>,
          <<1, 0::192, 6001::signed-16, 0::16>>,
          <<1, 0::192, 0::16, -1::signed-16>>,
          <<1, 0x7FF0000000000000::64, 0::128, 0::32>>
        ] do
      assert ItemRecords.decode(seal.(motion), @key) == {:error, :invalid_item_file}
    end
  end
end
