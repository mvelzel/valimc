defmodule Valimc.PlayerEffectSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerEffects, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  @uuid <<94::128>>
  @pose %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
  @effects %{11 => [{2, 2, false, true, true}, {-1, 0, true, false, true}]}
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "bounded canonical effect payload refuses duplicate IDs, chains, flags and truncation" do
    full_chain = Enum.map(255..0//-1, &{-1, &1, false, true, true})
    full = Map.new(0..39, &{&1, full_chain})
    assert {:ok, bytes} = PlayerEffects.encode(full)
    assert byte_size(bytes) == PlayerEffects.max_bytes()
    assert {:ok, ^full, <<7, 8>>} = PlayerEffects.take(bytes <> <<7, 8>>)
    assert {:ok, <<0>>} = PlayerEffects.encode(%{})

    for bytes <- [
          <<>>,
          <<41>>,
          <<1, 40, 1::16, 1::signed-32, 0, 6>>,
          <<1, 11, 0::16>>,
          <<1, 11, 257::16>>,
          <<1, 11, 1::16, -2::signed-32, 0, 6>>,
          <<1, 11, 1::16, 1::signed-32, 0, 8>>,
          <<1, 11, 2::16, 1::signed-32, 0, 6, 1::signed-32, 1, 6>>,
          <<2, 11, 1::16, 1::signed-32, 0, 6, 11, 1::16, 1::signed-32, 0, 6>>,
          binary_part(bytes, 0, byte_size(bytes) - 1)
        ] do
      assert PlayerEffects.take(bytes) == {:error, :invalid_player_effects}
    end
  end

  test "v18 wraps an ordinary pending death transfer without changing inventory or receipt request bytes" do
    bare = %{pose: @pose, inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}}

    pending =
      Map.merge(bare, %{
        transfer_sequence: 9,
        outbox: %{
          key: {0, 0},
          records: [
            %{uuid: <<95::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("egg", 3)}
          ]
        }
      })

    for snapshot <- [bare, pending],
        fire <- [nil, -20, 300],
        table <- [nil, {ItemStack.new("dirt"), nil, nil, nil, nil, nil, nil, nil, nil}] do
      snapshot = put_in(snapshot.inventory.table_inputs, table)
      snapshot = if fire == nil, do: snapshot, else: Map.put(snapshot, :fire_ticks, fire)
      {:ok, legacy} = PlayerSnapshot.encode(@uuid, snapshot)
      {:ok, old} = PlayerSnapshot.decode(legacy, @uuid)
      refute Map.has_key?(old, :effects)

      for effects <- [%{}, @effects] do
        assert {:ok, <<"VMCPOSE", 18, _::binary>> = bytes} =
                 PlayerSnapshot.encode(@uuid, Map.put(snapshot, :effects, effects))

        assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
        assert restored == Map.put(old, :effects, effects)
        assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)

        assert PlayerSnapshot.transfer_request(@uuid, restored) ==
                 PlayerSnapshot.transfer_request(@uuid, old)
      end
    end
  end

  test "capture, maximum payload and malformed wrappers retain snapshot boundaries" do
    snapshot = PlayerSnapshot.capture(Map.put(@pose, :effects, @effects), %Inventory{})
    assert snapshot.effects == @effects
    refute Map.has_key?(PlayerSnapshot.capture(@pose, %Inventory{}), :effects)
    {:ok, bytes} = PlayerSnapshot.encode(@uuid, snapshot)
    {:ok, effect_bytes} = PlayerEffects.encode(@effects)
    effect_size = byte_size(effect_bytes)
    body_size = byte_size(bytes) - 93 - effect_size

    <<header::binary-size(60), base, _effects::binary-size(^effect_size),
      body::binary-size(^body_size), _::binary-size(32)>> = bytes

    for payload <- [
          header <> <<18>> <> effect_bytes <> body,
          header <> <<base, 41>> <> body,
          header <> <<base>> <> effect_bytes,
          header <> <<base>> <> effect_bytes <> body <> <<0>>
        ] do
      assert PlayerSnapshot.decode(seal(payload), @uuid) == {:error, :invalid_player_file}
    end

    assert PlayerSnapshot.encode(@uuid, %{snapshot | effects: %{11 => []}}) ==
             {:error, :invalid_player_effects}

    assert PlayerSnapshot.decode(bytes, <<96::128>>) == {:error, :invalid_player_file}
    full_chain = Enum.map(255..0//-1, &{-1, &1, true, true, true})
    full = %{snapshot | effects: Map.new(0..39, &{&1, full_chain})}
    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, full)
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
    assert restored.effects == full.effects
  end
end
