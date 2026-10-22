defmodule Valimc.PlayerPlacementTransfersTest do
  use ExUnit.Case, async: true

  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerPlacementTransfers}
  alias Valimc.Player.State, as: PlayerState

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

  defp persisted(state),
    do:
      PlayerState.new(%{
        state
        | inventory: %{state.inventory | state_id: 0, drag: nil, infinite_materials: false}
      })

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

      assert {:ok, bytes} = PlayerState.encode(@uuid, resolved)
      assert {:ok, restored} = PlayerState.decode(bytes, @uuid)
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
end
