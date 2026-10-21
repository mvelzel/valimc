defmodule Valimc.PlayerPlacementTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    GameMode,
    Inventory,
    PlayerFood,
    PlayerPlacementIntent,
    PlayerPlacementTransfers,
    PlayerSnapshot
  }

  alias Valimc.Protocol.ItemStack
  @uuid <<83::128>>
  @max_sequence 18_446_744_073_709_551_615

  defp source(hand \\ :main, count \\ 2) do
    before = %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"receipt" => {:string, "exact"}}}
        }
    }

    slot = if hand == :main, do: 43, else: 45

    intent = %{
      kind: :placement,
      key: {0, 0},
      permit: <<84::128>>,
      slot: slot,
      before: before,
      after: if(count == 1, do: nil, else: %{before | count: count - 1}),
      request: %{
        hand: hand,
        position: {1, 64, 1},
        face: 1,
        cursor: {0.5, 0.5, 0.5},
        inside: false,
        border: false,
        sequence: 17
      },
      expected: %{{1, 64, 1} => 0},
      edits: %{{1, 64, 1} => 1}
    }

    state = %{
      pose: %{x: 1.5, y: 64.0, z: 1.5, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{
        selected: 7,
        state_id: 32767,
        drag: %{in_progress: true},
        carried: ItemStack.new("dirt", 3),
        slots: %{slot => before, 5 => ItemStack.new("iron_helmet")}
      },
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 7.0, hurt_ticks: 3, death_ticks: 0},
      last_death: nil,
      air_supply: 154,
      food: %PlayerFood{level: 18, saturation: 0.0, exhaustion: 2.5, timer: 79},
      transfer_sequence: 9,
      outbox: nil
    }

    {state, intent}
  end

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)
  defp persisted(state), do: %{state | inventory: %{state.inventory | state_id: 0, drag: nil}}

  test "table inputs survive typed placement consume/refund and v15 validation" do
    {state, intent} = source()
    cells = List.to_tuple([ItemStack.new("oak_planks", 3) | List.duplicate(nil, 8)])
    state = put_in(state.inventory.table_inputs, cells)
    assert {:ok, pending} = PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)
    assert pending.inventory.table_inputs == cells
    assert {:ok, <<"VMCPOSE", 15, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored == persisted(pending)
    burning = Map.put(pending, :fire_ticks, 300)
    assert {:ok, <<"VMCPOSE", 17, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, burning)
    assert {:ok, restored_fire} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored_fire == persisted(burning)
    assert {:ok, %{fire_ticks: 300}} = PlayerPlacementTransfers.resolve(restored_fire, :rejected)
    assert {:ok, refunded} = PlayerPlacementTransfers.resolve(restored, :rejected)

    assert refunded.inventory.table_inputs == cells and
             refunded.inventory.slots == state.inventory.slots

    assert {:error, :invalid_placement_snapshot} =
             PlayerSnapshot.encode(@uuid, put_in(pending.inventory.selected, 0))
  end

  test "both hands consume one exact item in the complete v14 journal, including depletion" do
    for {hand, count} <- [{:main, 2}, {:off, 1}] do
      {state, intent} = source(hand, count)
      assert {:ok, pending} = PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)
      assert pending.outbox == intent and pending.transfer_sequence == 10
      assert Inventory.get(pending.inventory, intent.slot) == intent.after
      assert pending.inventory.drag == nil and pending.inventory.state_id == 0

      assert Map.delete(pending.inventory.slots, intent.slot) ==
               Map.delete(state.inventory.slots, intent.slot)

      assert pending.inventory.carried == state.inventory.carried
      assert {:ok, <<"VMCPOSE", 14, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, pending)
      assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
      assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
      assert restored == persisted(pending)
      assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)
      assert {:error, :wrong_transfer_kind} = PlayerSnapshot.transfer_request(@uuid, restored)
    end
  end

  test "terminal resolution keeps consumption or refunds the exact stack without replaying the source" do
    for {hand, count, outcome} <- [{:main, 2, :applied}, {:off, 1, :rejected}] do
      {state, intent} = source(hand, count)
      {:ok, pending} = PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)

      later = %{
        pending
        | health: %{value: 0.0, hurt_ticks: 0, death_ticks: 7},
          air_supply: 37,
          food: %PlayerFood{level: 4, saturation: 0.0, exhaustion: 3.5, timer: 79}
      }

      assert {:ok, resolved} = PlayerPlacementTransfers.resolve(later, outcome)
      assert resolved.transfer_sequence == 10 and resolved.outbox == nil

      assert Inventory.get(resolved.inventory, intent.slot) ==
               if(outcome == :applied, do: intent.after, else: intent.before)

      assert resolved.health == later.health and resolved.food == later.food and
               resolved.air_supply == 37

      assert resolved.inventory.carried == state.inventory.carried

      assert {:error, :invalid_placement_plan} =
               PlayerPlacementTransfers.resolve(resolved, outcome)

      assert {:ok, <<"VMCPOSE", 12, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, resolved)
      assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
      assert restored == persisted(resolved)
    end
  end

  test "preparation refuses stale counters, changed sources, privileges, death and arbitrary consumption" do
    {state, intent} = source()

    for invalid <- [
          %{state | transfer_sequence: 8},
          %{state | outbox: intent},
          %{state | game_mode: GameMode.new(:creative)},
          %{state | game_mode: GameMode.new(:adventure)},
          %{state | health: %{value: 0.0, hurt_ticks: 0, death_ticks: 0}},
          %{state | inventory: %{state.inventory | selected: 0}},
          %{state | inventory: %{state.inventory | slots: %{43 => intent.after}}},
          %{state | inventory: %{state.inventory | infinite_materials: true}}
        ] do
      assert {:error, :invalid_placement_plan} =
               PlayerPlacementTransfers.prepare(@uuid, 9, invalid, intent)
    end

    for invalid <- [
          %{intent | before: nil},
          %{intent | after: nil},
          %{intent | after: intent.before},
          %{intent | slot: 45},
          %{intent | request: %{intent.request | hand: :off}},
          %{intent | edits: %{{1, 64, 1} => 15}}
        ] do
      assert {:error, :invalid_placement_plan} =
               PlayerPlacementTransfers.prepare(@uuid, 9, state, invalid)
    end

    assert {:error, :invalid_placement_plan} =
             PlayerPlacementTransfers.prepare(
               @uuid,
               @max_sequence,
               %{state | transfer_sequence: @max_sequence},
               intent
             )

    assert {:ok, pending} =
             PlayerPlacementTransfers.prepare(
               @uuid,
               @max_sequence - 1,
               %{state | transfer_sequence: @max_sequence - 1},
               intent
             )

    assert pending.transfer_sequence == @max_sequence
    {off_state, off_intent} = source(:off)

    assert {:ok, _} =
             PlayerPlacementTransfers.prepare(
               @uuid,
               9,
               %{off_state | inventory: %{off_state.inventory | selected: 0}},
               off_intent
             )
  end

  test "conflicting source inventory cannot be cleared or refunded" do
    {state, intent} = source()
    {:ok, pending} = PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)

    for inventory <- [
          %{pending.inventory | selected: 0},
          %{pending.inventory | slots: %{43 => intent.before}},
          %{pending.inventory | slots: %{43 => %{intent.after | components: %{}}}}
        ],
        result <- [:applied, :rejected] do
      altered = %{pending | inventory: inventory}

      assert {:error, :placement_source_conflict} =
               PlayerPlacementTransfers.resolve(altered, result)

      assert {:error, :invalid_placement_snapshot} = PlayerSnapshot.encode(@uuid, altered)
    end

    assert {:error, :invalid_placement_plan} =
             PlayerPlacementTransfers.resolve(pending, :already_applied)

    assert {:error, :invalid_placement_snapshot} =
             PlayerSnapshot.encode(@uuid, Map.delete(pending, :food))
  end

  test "valid outer checksums cannot change the typed operation, selected source or durable sequence" do
    {state, intent} = source()
    {:ok, pending} = PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)
    {:ok, bytes} = PlayerSnapshot.encode(@uuid, pending)
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<"VMCPOSE", 14, rest::binary>> = payload

    for version <- [3, 12, 13] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(seal(<<"VMCPOSE", version, rest::binary>>), @uuid)
    end

    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes, <<85::128>>)
    {:ok, intent_bytes} = PlayerPlacementIntent.encode(@uuid, 10, intent)
    {offset, _} = :binary.match(payload, "VMCPOUT")
    inventory_offset = offset + byte_size(intent_bytes)
    <<prefix::binary-size(^inventory_offset), _selected, stacks::binary>> = payload

    assert {:error, :invalid_player_file} =
             PlayerSnapshot.decode(seal(prefix <> <<0>> <> stacks), @uuid)

    sequence_offset = offset - 12
    <<header::binary-size(^sequence_offset), 10::64, tail::binary>> = payload

    assert {:error, :invalid_player_file} =
             PlayerSnapshot.decode(seal(header <> <<11::64>> <> tail), @uuid)

    for size <- 0..(byte_size(bytes) - 1) do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(binary_part(bytes, 0, size), @uuid)
    end

    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes <> <<0>>, @uuid)
  end
end
