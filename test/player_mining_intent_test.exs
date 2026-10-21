defmodule Valimc.PlayerMiningIntentTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerMiningIntent, PlayerSnapshot}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.MiningTransfers
  @uuid <<51::128>>

  defp intent do
    before = %{
      ItemStack.new("iron_pickaxe")
      | components: %{
          "minecraft:damage" => 249,
          "minecraft:custom_data" => {:compound, %{"proof" => {:string, "refund"}}}
        }
    }

    %{
      kind: :mining,
      key: {0, 0},
      permit: <<73::128>>,
      target: {1, 63, 1},
      slot: 43,
      before: before,
      after: nil,
      expected: %{{1, 63, 1} => Data.block("stone")},
      records: [
        %{uuid: <<11::128>>, x: 1.5, y: 63.5, z: 1.5, stack: ItemStack.new("cobblestone")}
      ]
    }
  end

  defp snapshot(intent) do
    %{
      pose: %{x: 1.5, y: 64.0, z: 1.5, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{selected: 7, slots: %{5 => ItemStack.new("iron_helmet")}},
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
      outbox: intent
    }
  end

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "typed intent roundtrips stable drops and exact refund with the complete v13 player journal" do
    intent = intent()
    assert {:ok, encoded} = PlayerMiningIntent.encode(@uuid, 9, intent)
    assert {:ok, ^intent} = PlayerMiningIntent.decode(@uuid, 9, encoded)
    assert byte_size(encoded) <= PlayerMiningIntent.max_bytes()
    assert {:ok, {0, 0}, request, digest} = PlayerMiningIntent.request(@uuid, 9, intent)
    assert {:ok, ^digest} = MiningTransfers.digest({0, 0}, request)
    assert request.source == @uuid and request.sequence == 9
    assert request.permit == intent.permit and request.records == intent.records

    state = snapshot(intent)
    assert {:ok, <<"VMCPOSE", 13, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, state)
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored == state
    assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)
    assert {:error, :wrong_transfer_kind} = PlayerSnapshot.transfer_request(@uuid, restored)

    # Existing ordinary transfers keep the old codec and digest domain.
    ordinary = %{state | outbox: Map.take(intent, [:key, :records])}
    assert {:ok, <<"VMCPOSE", 12, _::binary>> = old} = PlayerSnapshot.encode(@uuid, ordinary)
    assert {:ok, ordinary} = PlayerSnapshot.decode(old, @uuid)
    assert {:ok, _, _, ordinary_digest} = PlayerSnapshot.transfer_request(@uuid, ordinary)
    refute ordinary_digest == digest
    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes, <<52::128>>)
  end

  test "bounds, target binding, canonical body and selected-hand mismatch fail closed" do
    intent = intent()
    expected = Map.new(0..127, fn x -> {{x, 63, 1}, Data.block("stone")} end)
    assert {:ok, bytes} = PlayerMiningIntent.encode(@uuid, 9, %{intent | expected: expected})
    assert {:ok, %{expected: ^expected}} = PlayerMiningIntent.decode(@uuid, 9, bytes)

    for invalid <- [
          %{intent | expected: Map.put(expected, {128, 63, 1}, Data.block("stone"))},
          %{intent | expected: %{}},
          %{intent | target: {2, 63, 1}},
          %{intent | expected: %{{513, 63, 1} => 1}},
          %{intent | slot: 45},
          %{intent | permit: <<1>>},
          %{intent | records: intent.records ++ intent.records},
          %{intent | before: ItemStack.new("air")}
        ] do
      assert {:error, :invalid_mining_intent} = PlayerMiningIntent.encode(@uuid, 9, invalid)
    end

    assert {:error, :invalid_mining_intent} = PlayerMiningIntent.encode(@uuid, 0, intent)
    assert {:ok, bytes} = PlayerMiningIntent.encode(@uuid, 9, intent)
    <<prefix::binary-size(53), length::32, rest::binary>> = bytes

    for invalid <- [
          binary_part(bytes, 0, byte_size(bytes) - 1),
          bytes <> <<0>>,
          prefix <> <<length + 1::32>> <> rest
        ] do
      assert {:error, :invalid_mining_intent} = PlayerMiningIntent.decode(@uuid, 9, invalid)
    end

    state = snapshot(intent)

    assert {:error, :invalid_mining_snapshot} =
             PlayerSnapshot.encode(@uuid, %{state | inventory: %{state.inventory | selected: 0}})

    assert {:error, :invalid_mining_snapshot} =
             PlayerSnapshot.encode(@uuid, %{
               state
               | inventory: %{state.inventory | slots: %{43 => intent.before}}
             })

    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, state)

    payload_size = byte_size(bytes) - 40

    <<"VMCPOSE", 13, payload::binary-size(^payload_size), _checksum::binary-size(32)>> =
      bytes

    # A valid outer checksum cannot turn the typed intent into an ordinary v12 outbox.
    assert {:error, :invalid_player_file} =
             PlayerSnapshot.decode(seal(<<"VMCPOSE", 12, payload::binary>>), @uuid)

    {:ok, intent_bytes} = PlayerMiningIntent.encode(@uuid, 9, intent)
    {start, _} = :binary.match(bytes, "VMCMOUT")
    inventory_start = start + byte_size(intent_bytes)
    rest_size = byte_size(bytes) - inventory_start - 33

    <<prefix::binary-size(^inventory_start), _selected, inventory_rest::binary-size(^rest_size),
      _checksum::binary-size(32)>> = bytes

    assert {:error, :invalid_player_file} =
             PlayerSnapshot.decode(seal(<<prefix::binary, 0, inventory_rest::binary>>), @uuid)
  end
end
