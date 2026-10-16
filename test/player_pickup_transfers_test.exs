defmodule Valimc.PlayerPickupTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    GameMode,
    Inventory,
    ItemMotionState,
    PlayerFood,
    PlayerPickupIntent,
    PlayerPickupTransfers,
    PlayerSnapshot
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Items, PickupTransfers}
  @uuid <<81::128>>

  defp source(mode \\ :survival) do
    stack = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    state = %{
      pose: %{x: 8.5, y: 64.0, z: 8.5, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{
        selected: 3,
        state_id: 17,
        carried: ItemStack.new("egg", 2),
        slots: %{5 => ItemStack.new("iron_helmet")}
      },
      game_mode: GameMode.new(mode),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 19.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 9,
      outbox: nil
    }

    request = %{
      source: @uuid,
      sequence: 10,
      permit: <<82::128>>,
      item_uuid: <<83::128>>,
      generation: 0,
      before: stack,
      remainder: nil
    }

    {state, %{kind: :pickup, key: {0, 0}, request: request}}
  end

  defp world(intent) do
    record = %{
      uuid: intent.request.item_uuid,
      x: 8.5,
      y: 64.0,
      z: 8.5,
      stack: intent.request.before,
      motion: %ItemMotionState{}
    }

    {:ok, items} = Items.restore({0, 0}, [record])
    items
  end

  defp persisted(state), do: %{state | inventory: %{state.inventory | state_id: 0, drag: nil}}

  test "saved intent retains original inventory; only matching applied proof grants once" do
    {state, intent} = source()
    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)
    assert pending.inventory == state.inventory and pending.transfer_sequence == 10
    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert <<"VMCPOSE", 16, _::binary>> = bytes
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored == persisted(pending)

    assert {:ok, %{result: :applied} = withdrawn} =
             PickupTransfers.plan(world(intent), %{}, {0, 0}, intent.request, true)

    assert Items.records(withdrawn.items) == []

    assert {:ok, received} =
             PlayerPickupTransfers.resolve(@uuid, restored, withdrawn.receipts[@uuid])

    assert received.inventory.slots[36] == intent.request.before

    assert received.inventory.carried == state.inventory.carried and
             received.inventory.slots[5] == state.inventory.slots[5]

    assert received.outbox == nil and received.transfer_sequence == 10
    assert {:error, _} = PlayerPickupTransfers.resolve(@uuid, received, withdrawn.receipts[@uuid])

    assert {:error, :transfer_conflict} =
             PlayerPickupTransfers.resolve(@uuid, restored, %{sequence: 10, digest: <<0::256>>})

    assert {:error, :stale_transfer} =
             PlayerPickupTransfers.resolve(@uuid, restored, %{sequence: 11, digest: <<0::256>>})

    for changed <- [
          put_in(restored.inventory.selected, 4),
          put_in(restored.inventory.carried, nil),
          put_in(restored.inventory.slots[36], intent.request.before),
          put_in(restored.inventory.table_inputs, {nil, nil, nil, nil, nil, nil, nil, nil, nil}),
          %{restored | game_mode: GameMode.new(:creative)}
        ] do
      assert {:error, :pickup_inventory_conflict} =
               PlayerPickupTransfers.resolve(@uuid, changed, withdrawn.receipts[@uuid])

      assert {:error, :invalid_pickup_snapshot} = PlayerSnapshot.encode(@uuid, changed)
    end
  end

  test "rejected proof clears the intent without inventory gain or sequence rewind" do
    {state, intent} = source()
    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)

    assert {:ok, rejected} =
             PickupTransfers.plan(world(intent), %{}, {0, 0}, intent.request, false)

    assert {:ok, resolved} =
             PlayerPickupTransfers.resolve(@uuid, pending, rejected.receipts[@uuid])

    assert resolved.inventory == state.inventory and resolved.outbox == nil and
             resolved.transfer_sequence == 10

    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, resolved)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored == persisted(resolved)
  end

  test "partial insertion and native false callback still grant exactly the withdrawn amount" do
    {state, intent} = source()
    stack = intent.request.before

    inventory = %Inventory{
      slots: Map.new(9..44, &{&1, %{stack | count: 64}}) |> Map.put(36, %{stack | count: 63})
    }

    state = %{state | inventory: inventory}
    intent = put_in(intent.request.remainder, %{stack | count: 6})
    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)
    assert {:ok, _next, false} = PlayerPickupIntent.inventory_result(pending.outbox, state)

    assert {:ok, withdrawn} =
             PickupTransfers.plan(world(intent), %{}, {0, 0}, intent.request, true)

    assert {:ok, resolved} =
             PlayerPickupTransfers.resolve(@uuid, pending, withdrawn.receipts[@uuid])

    assert resolved.inventory.slots[36].count == 64
    assert [saved] = Items.records(withdrawn.items)
    assert saved.stack.count == 6
  end

  test "creative overflow permissions survive v16 and a table wrapper without trusting saved inventory flags" do
    {state, intent} = source(:creative)

    inventory = %Inventory{
      slots: Map.new(9..44, &{&1, ItemStack.new("egg", 16)}),
      table_inputs: {ItemStack.new("dirt"), nil, nil, nil, nil, nil, nil, nil, nil}
    }

    state = %{state | inventory: inventory}
    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)
    assert pending.inventory == inventory
    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert <<"VMCPOSE", 15, _::binary-size(52), 16, _::binary>> = bytes
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored == persisted(pending)

    assert {:ok, withdrawn} =
             PickupTransfers.plan(world(intent), %{}, {0, 0}, intent.request, true)

    assert {:ok, resolved} =
             PlayerPickupTransfers.resolve(@uuid, restored, withdrawn.receipts[@uuid])

    assert resolved.inventory.slots == inventory.slots and
             resolved.inventory.table_inputs == inventory.table_inputs

    assert resolved.inventory.infinite_materials and Items.records(withdrawn.items) == []
  end

  test "wrong identity, pending work, mode, health, capacity and sequence limits refuse" do
    {state, intent} = source()

    for bad <- [
          %{state | outbox: intent},
          %{state | transfer_sequence: 8},
          %{state | game_mode: GameMode.new(:spectator)},
          put_in(state.health.value, 0.0),
          put_in(state.inventory.slots, Map.new(9..44, &{&1, ItemStack.new("egg", 16)}))
        ] do
      assert {:error, :invalid_pickup_plan} = PlayerPickupTransfers.prepare(@uuid, 9, bad, intent)
    end

    assert {:error, :invalid_pickup_plan} =
             PlayerPickupTransfers.prepare(<<7::128>>, 9, state, intent)

    assert {:error, :invalid_pickup_plan} =
             PlayerPickupTransfers.prepare(@uuid, 18_446_744_073_709_551_615, state, intent)

    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)
    assert {:ok, bytes} = PlayerPickupIntent.encode(@uuid, 10, pending.outbox)
    assert {:error, :invalid_pickup_intent} = PlayerPickupIntent.decode(@uuid, 11, bytes)
    assert {:error, :invalid_pickup_intent} = PlayerPickupIntent.decode(<<7::128>>, 10, bytes)
  end
end
