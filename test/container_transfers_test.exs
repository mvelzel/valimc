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
end
