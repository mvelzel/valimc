defmodule Valimc.CookingTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{Cooking, CookingRecipes, Inventory}

  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerTransfers}
  @key {0, 0}
  @position {1, 64, 1}
  @uuid <<61::128>>

  defp fixture(kind, carried \\ nil) do
    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, @key, @position, kind)

    request = %{
      source: @uuid,
      sequence: 1,
      permit: <<62::128>>,
      position: @position,
      revision: entry.revision,
      kind: kind,
      slots: entry.cooking.slots,
      inventory: %Inventory{carried: carried},
      action: :pickup,
      slot: 0,
      button: 0
    }

    {:ok, containers, _} = ContainerTransfers.reserve(containers, @uuid)
    {containers, request}
  end

  test "item edit and receipt persist together and a lost acknowledgment does not repeat it" do
    input = ItemStack.new("raw_iron", 3)
    {containers, request} = fixture(:furnace, input)

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan(containers, @key, request, true)

    entry = committed.entries[@position]

    assert entry.cooking.slots == {input, nil, nil} and entry.cooking.total == 200 and
             entry.revision == 2

    assert {:ok, bytes} = Containers.encode(@key, committed)
    assert {:ok, restored} = Containers.decode(bytes, @key)

    assert {:ok, %{result: :already_applied, containers: ^restored}} =
             ContainerTransfers.plan(restored, @key, request, false)

    assert {:error, :transfer_conflict} =
             ContainerTransfers.plan(restored, @key, %{request | button: 1}, true)

    assert {:ok, :applied} =
             ContainerTransfers.receipt_result(@key, request, restored.receipts[@uuid])
  end

  test "earned output cannot withdraw until a durable award is supported; other edits preserve all uses" do
    {containers, request} = fixture(:furnace)
    entry = containers.entries[@position]
    input = ItemStack.new("raw_iron")
    {:ok, block} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, recipe} = CookingRecipes.find(input, block)
    uses = %{recipe.key => 43}
    cooking = %Cooking{slots: {input, nil, recipe.result}, progress: 49, total: 123}

    {:ok, containers, entry} =
      Containers.replace_cooking(containers, @position, entry.revision, cooking, uses)

    request = %{request | revision: entry.revision, slots: cooking.slots, slot: 2}

    assert {:ok, %{result: :rejected, containers: rejected}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert rejected.entries == containers.entries
    request = %{request | slot: 1, inventory: %Inventory{carried: ItemStack.new("coal", 3)}}

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert committed.entries[@position].recipes == uses

    assert committed.entries[@position].cooking.progress == 49 and
             committed.entries[@position].cooking.total == 123
  end
end
