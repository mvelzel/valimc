defmodule Valimc.PlayerPickupTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{GameMode, Inventory, ItemMotionState, PlayerFood, PlayerPickupTransfers}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Entities, PickupTransfers}
  @uuid <<81::128>>

  defp source(mode) do
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

    {:ok, items} = Entities.restore({0, 0}, [record])
    items
  end

  defp persisted(state),
    do:
      PlayerState.new(%{
        state
        | inventory: %{state.inventory | state_id: 0, drag: nil, infinite_materials: false}
      })

  test "creative overflow permissions survive a pending pickup and an open table without trusting saved inventory flags" do
    {state, intent} = source(:creative)

    inventory = %Inventory{
      slots: Map.new(9..44, &{&1, ItemStack.new("egg", 16)}),
      table_inputs: {ItemStack.new("dirt"), nil, nil, nil, nil, nil, nil, nil, nil}
    }

    state = %{state | inventory: inventory}
    assert {:ok, pending} = PlayerPickupTransfers.prepare(@uuid, 9, state, intent)
    assert pending.inventory == inventory
    assert {:ok, bytes} = PlayerState.encode(@uuid, pending)
    burning = Map.put(pending, :fire_ticks, 300)
    assert {:ok, fire_bytes} = PlayerState.encode(@uuid, burning)

    assert {:ok, restored_fire} = PlayerState.decode(fire_bytes, @uuid)
    assert restored_fire == persisted(burning)
    assert {:ok, restored} = PlayerState.decode(bytes, @uuid)
    assert restored == persisted(pending)

    assert {:ok, withdrawn} =
             PickupTransfers.plan(world(intent), %{}, {0, 0}, intent.request, true)

    assert {:ok, resolved} =
             PlayerPickupTransfers.resolve(@uuid, restored, withdrawn.receipts[@uuid])

    assert resolved.inventory.slots == inventory.slots and
             resolved.inventory.table_inputs == inventory.table_inputs

    assert resolved.inventory.infinite_materials and Entities.records(withdrawn.items) == []
  end
end
