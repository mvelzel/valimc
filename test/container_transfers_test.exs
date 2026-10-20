defmodule Valimc.ContainerTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerRequest, Containers, ContainerTransfers}
  @key {0, 0}
  @position {1, 64, 1}

  defp fixture(cursor \\ ItemStack.new("diamond", 3)) do
    {:ok, containers, entry} = Containers.create(%Containers{}, @key, @position, 3)

    request = %{
      source: <<1::128>>,
      sequence: 7,
      permit: <<9::128>>,
      position: @position,
      revision: entry.revision,
      rows: 3,
      slots: entry.slots,
      inventory: %Inventory{carried: cursor},
      action: :pickup,
      slot: 0,
      button: 0
    }

    {containers, request}
  end

  defp reserve(containers, source) do
    assert {:ok, next, _} = ContainerTransfers.reserve(containers, source)
    next
  end

  test "typed request binds action, exact patched inventory, container and permit; counters stay ephemeral" do
    {_, request} = fixture()
    sword = %{ItemStack.new("diamond_sword") | components: %{"minecraft:damage" => 7}}

    inventory = %{
      request.inventory
      | slots: %{1 => sword, 45 => ItemStack.new("egg", 16)},
        selected: 8
    }

    request = %{request | inventory: inventory}
    assert {:ok, bytes} = ContainerRequest.encode(@key, request)
    assert byte_size(bytes) <= ContainerRequest.max_bytes()
    assert {:ok, ^request} = ContainerRequest.decode(bytes, @key)
    assert {:ok, digest} = ContainerRequest.digest(@key, request)

    for changed <- [
          %{request | permit: <<10::128>>},
          %{request | sequence: 8},
          %{request | button: 1},
          %{request | inventory: %{inventory | selected: 0}}
        ] do
      assert {:ok, different} = ContainerRequest.digest(@key, changed)
      assert different != digest
    end

    assert {:ok, ^digest} =
             ContainerRequest.digest(@key, %{request | inventory: %{inventory | state_id: 123}})

    assert {:error, :invalid_container_request} = ContainerRequest.decode(bytes, {1, 0})
    assert {:error, :invalid_container_request} = ContainerRequest.decode(bytes <> <<0>>, @key)

    assert {:error, :invalid_container_request} =
             ContainerRequest.decode(binary_part(bytes, 0, byte_size(bytes) - 1), @key)
  end

  test "unsupported or noncanonical requests cannot become durable action identities" do
    {_, request} = fixture()

    for bad <- [
          %{request | action: :throw},
          %{request | slot: -999},
          %{request | revision: 0},
          %{request | position: {128, 64, 0}},
          %{request | source: <<0>>},
          %{request | inventory: %{request.inventory | table_inputs: Tuple.duplicate(nil, 9)}},
          %{request | inventory: %{request.inventory | carried: ItemStack.new("air")}},
          Map.put(request, :prediction, :forged)
        ] do
      assert {:error, :invalid_container_request} = ContainerRequest.encode(@key, bad)
    end
  end

  test "applied decision persists contents and receipt together; retry after lost acknowledgment never repeats" do
    {containers, request} = fixture()

    assert {:error, :missing_container_receipt_slot} =
             ContainerTransfers.plan(containers, @key, request, true)

    containers = reserve(containers, request.source)

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert committed.entries[@position].slots |> elem(0) == ItemStack.new("diamond", 3)
    assert committed.entries[@position].revision == 2
    assert request.inventory.carried == ItemStack.new("diamond", 3)
    assert {:ok, _, player_after} = ContainerRequest.plan(request)
    assert player_after.carried == nil
    assert {:ok, bytes} = Containers.encode(@key, committed)
    assert {:ok, restored} = Containers.decode(bytes, @key)

    assert {:ok, :applied} =
             ContainerTransfers.receipt_result(@key, request, restored.receipts[request.source])

    assert {:ok, %{result: :already_applied, containers: ^restored}} =
             ContainerTransfers.plan(restored, @key, request, false)

    assert {:error, :transfer_conflict} =
             ContainerTransfers.plan(restored, @key, %{request | button: 1}, true)

    assert {:error, :stale_transfer} =
             ContainerTransfers.plan(restored, @key, %{request | sequence: 6}, true)
  end

  test "competing stale deposit rejects durably, then a fresh view can conserve both players' items" do
    {containers, first} = fixture()

    second = %{
      first
      | source: <<2::128>>,
        sequence: 9,
        inventory: %Inventory{carried: ItemStack.new("diamond", 5)}
    }

    containers = containers |> reserve(first.source) |> reserve(second.source)

    {:ok, %{containers: deposited, result: :applied}} =
      ContainerTransfers.plan(containers, @key, first, true)

    assert {:ok, %{containers: rejected, result: :rejected}} =
             ContainerTransfers.plan(deposited, @key, second, true)

    assert rejected.entries == deposited.entries and rejected.sequence == deposited.sequence
    assert {:ok, bytes} = Containers.encode(@key, rejected)
    {:ok, restored} = Containers.decode(bytes, @key)

    assert {:ok, %{containers: ^restored, result: :already_rejected}} =
             ContainerTransfers.plan(restored, @key, second, true)

    assert {:ok, :rejected} =
             ContainerTransfers.receipt_result(@key, second, restored.receipts[second.source])

    fresh = %{
      second
      | sequence: 10,
        revision: deposited.entries[@position].revision,
        slots: deposited.entries[@position].slots
    }

    assert {:ok, %{containers: combined, result: :applied}} =
             ContainerTransfers.plan(restored, @key, fresh, true)

    assert elem(combined.entries[@position].slots, 0) == ItemStack.new("diamond", 8)
    assert {:ok, _, player_after} = ContainerRequest.plan(fresh)
    assert player_after.carried == nil
  end

  test "withdrawal and expired-grant rejection recover independently of later eligibility" do
    {containers, deposit} = fixture()
    containers = reserve(containers, deposit.source)
    {:ok, %{containers: filled}} = ContainerTransfers.plan(containers, @key, deposit, true)
    entry = filled.entries[@position]

    withdrawal = %{
      deposit
      | sequence: 8,
        revision: entry.revision,
        slots: entry.slots,
        inventory: %Inventory{}
    }

    assert {:ok, %{containers: rejected, result: :rejected}} =
             ContainerTransfers.plan(filled, @key, withdrawal, false)

    assert rejected.entries == filled.entries

    assert {:ok, %{containers: ^rejected, result: :already_rejected}} =
             ContainerTransfers.plan(rejected, @key, withdrawal, true)

    withdrawal = %{withdrawal | sequence: 9}

    assert {:ok, %{containers: emptied, result: :applied}} =
             ContainerTransfers.plan(rejected, @key, withdrawal, true)

    assert elem(emptied.entries[@position].slots, 0) == nil
    assert {:ok, _, player_after} = ContainerRequest.plan(withdrawal)
    assert player_after.carried == ItemStack.new("diamond", 3)
    assert {:ok, bytes} = Containers.encode(@key, emptied)
    {:ok, restored} = Containers.decode(bytes, @key)

    assert {:ok, %{result: :already_applied}} =
             ContainerTransfers.plan(restored, @key, withdrawal, false)
  end

  test "player-local clicks retain container revision and receipt capacity is reserved before grants" do
    {containers, request} = fixture(nil)
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 4)}}
    request = %{request | inventory: inventory, slot: 54}
    containers = reserve(containers, request.source)

    assert {:ok, %{containers: committed, result: :applied}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert committed.entries == containers.entries and committed.sequence == containers.sequence
    assert {:ok, _, player_after} = ContainerRequest.plan(request)
    assert player_after.carried == ItemStack.new("stone", 4) and player_after.slots == %{}

    receipts =
      Map.new(
        1..Valimc.Txn.Receipts.max_sources(),
        &{<<&1::128>>, %{sequence: 0, digest: <<0::256>>}}
      )

    full = %{containers | receipts: receipts}
    assert {:error, :transfer_source_limit} = ContainerTransfers.reserve(full, <<10_000::128>>)
    assert {:ok, ^full, :existing} = ContainerTransfers.reserve(full, <<1::128>>)
    assert {:ok, bytes} = Containers.encode(@key, full)
    assert {:ok, ^full} = Containers.decode(bytes, @key)
  end

  test "an exchange exceeding the file budget records rejection in the already reserved receipt" do
    item = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"payload" => {:string, String.duplicate("x", 30_000)}}}
        }
    }

    slots = List.to_tuple(List.duplicate(item, 17) ++ List.duplicate(nil, 10))

    containers =
      Enum.reduce(0..15, %Containers{}, fn x, state ->
        {:ok, state, entry} = Containers.create(state, @key, {x, 64, 0}, 3)
        {:ok, state, _} = Containers.replace(state, {x, 64, 0}, entry.revision, slots)
        state
      end)

    {:ok, containers, filler} = Containers.create(containers, @key, {16, 64, 0}, 3)
    filler_slots = List.to_tuple(List.duplicate(item, 7) ++ List.duplicate(nil, 20))

    {:ok, containers, _} =
      Containers.replace(containers, {16, 64, 0}, filler.revision, filler_slots)

    position = {17, 64, 0}
    {:ok, containers, entry} = Containers.create(containers, @key, position, 3)
    containers = reserve(containers, <<1::128>>)
    assert {:ok, _bytes} = Containers.encode(@key, containers)

    incoming = %{
      ItemStack.new("stone", 64)
      | components: %{
          "minecraft:custom_data" =>
            {:compound,
             %{
               "first" => {:string, String.duplicate("y", 20_000)},
               "second" => {:string, String.duplicate("y", 20_000)}
             }}
        }
    }

    request = %{
      source: <<1::128>>,
      sequence: 1,
      permit: <<4::128>>,
      position: position,
      revision: entry.revision,
      rows: 3,
      slots: entry.slots,
      inventory: %Inventory{slots: %{36 => incoming}},
      action: :quick_move,
      slot: 54,
      button: 0
    }

    assert {:ok, _} = ContainerRequest.encode(@key, request)

    assert {:ok, %{containers: rejected, result: :rejected}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert rejected.entries == containers.entries and rejected.sequence == containers.sequence

    assert {:ok, :rejected} =
             ContainerTransfers.receipt_result(@key, request, rejected.receipts[request.source])

    assert {:ok, _} = Containers.encode(@key, rejected)
  end

  test "receipt snapshots reject duplicate sources and invalid reservations despite valid checksums" do
    containers = reserve(%Containers{}, <<1::128>>)
    {:ok, bytes} = Containers.encode(@key, containers)
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), _::binary-size(32)>> = bytes
    <<header::binary-size(31), 1::16, receipt::binary-size(56)>> = payload
    duplicate = <<header::binary, 2::16, receipt::binary, receipt::binary>>
    duplicate = duplicate <> :crypto.hash(:sha256, duplicate)
    assert {:error, :invalid_container_snapshot} = Containers.decode(duplicate, @key)
    invalid = <<header::binary, 1::16, 1::128, 0::64, 1::256>>
    invalid = invalid <> :crypto.hash(:sha256, invalid)
    assert {:error, :invalid_container_snapshot} = Containers.decode(invalid, @key)
  end
end
