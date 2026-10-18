defmodule Valimc.CookingTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    Cooking,
    CookingRecipes,
    GameMode,
    Inventory,
    PlayerAbilities,
    PlayerContainerIntent,
    PlayerContainerTransfers,
    PlayerHealth,
    PlayerSnapshot
  }

  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerRequest, Containers, ContainerTransfers}
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

  defp snapshot(inventory, mode) do
    player = %{
      x: 8.5,
      y: 64.0,
      z: 8.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: GameMode.new(mode),
      abilities: PlayerAbilities.for_mode(mode),
      health: %PlayerHealth{}
    }

    PlayerSnapshot.capture(player, inventory)
    |> Map.merge(%{
      transfer_sequence: 0,
      outbox: nil,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      last_death: nil,
      air_supply: 300,
      food: %Valimc.PlayerFood{},
      fire_ticks: -20,
      effects: %{},
      absorption: 0.0
    })
  end

  defp count(nil), do: 0
  defp count(stack), do: stack.count

  for kind <- [:furnace, :smoker, :blast_furnace] do
    input_name = if kind == :smoker, do: "cod", else: "raw_iron"

    test "#{kind} v2 request roundtrips canonical slots and rejects wrong formats and layout tags" do
      kind = unquote(kind)
      {containers, request} = fixture(kind, ItemStack.new("raw_iron", 3))
      assert {:ok, bytes} = ContainerRequest.encode(@key, request)
      assert <<"VMCCREQ", 2, 5023::32, _::binary>> = bytes
      assert {:ok, ^request} = ContainerRequest.decode(bytes, @key)
      assert ContainerRequest.matches_entry?(request, containers.entries[@position])
      <<prefix::binary-size(80), _kind, rest::binary>> = bytes

      for bad <- [
            prefix <> <<3>> <> rest,
            bytes <> <<0>>,
            binary_part(bytes, 0, byte_size(bytes) - 1)
          ] do
        assert {:error, :invalid_container_request} = ContainerRequest.decode(bad, @key)
      end

      assert {:error, :invalid_container_request} = ContainerRequest.decode(bytes, {1, 0})

      assert {:error, :invalid_container_request} =
               ContainerRequest.encode(@key, Map.put(request, :progress, 0))

      assert {:error, :invalid_container_request} =
               ContainerRequest.encode(@key, %{request | slots: Tuple.duplicate(nil, 9)})
    end

    test "#{kind} item edit and receipt persist together and a lost acknowledgment does not repeat it" do
      kind = unquote(kind)
      input = ItemStack.new(unquote(input_name), 3)
      {containers, request} = fixture(kind, input)

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
  end

  test "fuel deposits retain authoritative progress/heat and stale revisions reject with a durable outcome" do
    {containers, request} = fixture(:furnace, ItemStack.new("coal", 3))
    entry = containers.entries[@position]

    cooking = %Cooking{
      burn_left: 17,
      burn_total: 1600,
      progress: 49,
      total: 123,
      slots: {ItemStack.new("raw_iron", 3), ItemStack.new("coal", 2), nil}
    }

    {:ok, containers, entry} =
      Containers.replace_cooking(containers, @position, entry.revision, cooking, %{})

    request = %{request | revision: entry.revision, slots: cooking.slots, slot: 1}

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan(containers, @key, request, true)

    assert committed.entries[@position].cooking == %{
             cooking
             | slots: put_elem(cooking.slots, 1, ItemStack.new("coal", 5))
           }

    assert {:ok, %{result: :rejected, containers: rejected}} =
             ContainerTransfers.plan(containers, @key, %{request | revision: 1}, true)

    assert rejected.entries == containers.entries and rejected.sequence == containers.sequence

    assert {:ok, %{result: :already_rejected}} =
             ContainerTransfers.plan(rejected, @key, %{request | revision: 1}, true)
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

  for mode <- [:survival, :creative], applied <- [true, false] do
    test "v2 player prepare/restore/seal conserves original items in #{mode}, eligible=#{applied}" do
      mode = unquote(mode)
      applied = unquote(applied)
      input = ItemStack.new("raw_iron", 3)
      {containers, request} = fixture(:furnace, input)

      inventory = %{
        request.inventory
        | slots: %{5 => ItemStack.new("iron_helmet"), 45 => ItemStack.new("bucket", 2)}
      }

      request = %{request | inventory: inventory}
      snapshot = snapshot(inventory, mode)
      intent = %{kind: :container, key: @key, request: request}
      assert {:ok, pending} = PlayerContainerTransfers.prepare(@uuid, 0, snapshot, intent)
      assert pending.inventory == inventory and pending.transfer_sequence == 1
      assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
      assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)

      assert {:ok, key, request, _digest} =
               PlayerContainerIntent.request(@uuid, 1, restored.outbox)

      assert request.kind == :furnace and
               request.inventory.infinite_materials == unquote(mode == :creative)

      assert {:ok, %{containers: committed}} =
               ContainerTransfers.plan(containers, key, request, applied)

      assert {:ok, sealed} =
               PlayerContainerTransfers.resolve(@uuid, restored, committed.receipts[@uuid])

      assert count(sealed.inventory.carried) == unquote(if(applied, do: 0, else: 3))

      assert count(elem(committed.entries[@position].cooking.slots, 0)) ==
               unquote(if(applied, do: 3, else: 0))

      assert sealed.inventory.slots == inventory.slots and sealed.outbox == nil and
               sealed.transfer_sequence == 1

      assert sealed.health == restored.health and sealed.game_mode == restored.game_mode
      assert {:ok, _} = PlayerSnapshot.encode(@uuid, sealed)

      assert {:error, :invalid_container_plan} =
               PlayerContainerTransfers.resolve(@uuid, sealed, committed.receipts[@uuid])
    end
  end
end
