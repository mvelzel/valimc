defmodule Valimc.PlayerAbsorptionSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  @uuid <<97::128>>
  @pose %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
  @absorption Valimc.Protocol.EffectTypes.id("absorption")
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "v19 retains a spent pool alongside effects and unchanged pending transfer bytes" do
    base = %{pose: @pose, inventory: %Inventory{slots: %{36 => ItemStack.new("glass_bottle")}}}

    pending =
      Map.merge(base, %{
        transfer_sequence: 9,
        outbox: %{
          key: {0, 0},
          records: [%{uuid: <<98::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("egg", 3)}]
        }
      })

    for snapshot <- [base, pending],
        fire <- [nil, -20],
        effects <- [nil, %{@absorption => [{200, 1, false, true, true}]}] do
      snapshot = if fire == nil, do: snapshot, else: Map.put(snapshot, :fire_ticks, fire)
      snapshot = if effects == nil, do: snapshot, else: Map.put(snapshot, :effects, effects)
      {:ok, legacy} = PlayerSnapshot.encode(@uuid, snapshot)
      {:ok, old} = PlayerSnapshot.decode(legacy, @uuid)
      refute Map.has_key?(old, :absorption)

      for pool <- [0.0, 0.5, 3.25, 2048.0] do
        assert {:ok, <<"VMCPOSE", 19, _::binary>> = bytes} =
                 PlayerSnapshot.encode(@uuid, Map.put(snapshot, :absorption, pool))

        assert byte_size(bytes) == byte_size(legacy) + 5
        assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
        assert restored == Map.put(old, :absorption, pool)
        assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)

        assert PlayerSnapshot.transfer_request(@uuid, restored) ==
                 PlayerSnapshot.transfer_request(@uuid, old)
      end
    end
  end

  test "capture and checksummed malformed pools/wrappers remain bounded" do
    bare = PlayerSnapshot.capture(@pose, %Inventory{})
    refute Map.has_key?(bare, :absorption)
    snapshot = PlayerSnapshot.capture(Map.put(@pose, :absorption, 3.25), %Inventory{})
    assert snapshot.absorption == 3.25
    {:ok, bytes} = PlayerSnapshot.encode(@uuid, snapshot)
    <<header::binary-size(60), base, _pool::32, rest::binary>> = bytes
    body = binary_part(rest, 0, byte_size(rest) - 32)

    for bits <- [<<-1.0::float-32>>, <<2049.0::float-32>>, <<0x7FC00000::32>>, <<0x7F800000::32>>] do
      assert PlayerSnapshot.decode(seal(header <> <<base>> <> bits <> body), @uuid) ==
               {:error, :invalid_player_file}
    end

    for payload <- [
          header <> <<19, 3.25::float-32>> <> body,
          header <> <<base, 3.25::float-32>>,
          header <> <<base, 3.25::float-32>> <> body <> <<0>>
        ] do
      assert PlayerSnapshot.decode(seal(payload), @uuid) == {:error, :invalid_player_file}
    end

    for pool <- [-1.0, 2049.0, 0.1, nil] do
      assert PlayerSnapshot.encode(@uuid, %{snapshot | absorption: pool}) ==
               {:error, :invalid_absorption}
    end

    assert PlayerSnapshot.decode(bytes, <<99::128>>) == {:error, :invalid_player_file}
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
  end
end
