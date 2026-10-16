defmodule Valimc.PlayerBurningSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack
  @uuid <<91::128>>
  @pose %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  defp snapshots do
    bare = %{pose: @pose, inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}}

    pending =
      Map.merge(bare, %{
        transfer_sequence: 9,
        outbox: %{
          key: {0, 0},
          records: [%{uuid: <<92::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("egg", 3)}]
        }
      })

    fields = [
      %{flying: false},
      %{game_mode: Valimc.GameMode.new(:survival)},
      %{fall_distance: 3.25},
      %{frozen_ticks: 77},
      %{velocity: {0.1, -1.0, 0.0}},
      %{health: %{value: 7.0, hurt_ticks: 3, death_ticks: 0}},
      %{last_death: {1, 64, 1}},
      %{air_supply: -19},
      %{food: %Valimc.PlayerFood{level: 18, saturation: 0.0, exhaustion: 2.5, timer: 79}}
    ]

    [bare, pending | Enum.scan(fields, pending, &Map.merge(&2, &1))]
  end

  test "signed fire state wraps every ordinary journal and table without changing their bytes or requests" do
    for snapshot <- snapshots(),
        table <- [nil, {ItemStack.new("dirt", 2), nil, nil, nil, nil, nil, nil, nil, nil}] do
      snapshot = put_in(snapshot.inventory.table_inputs, table)
      {:ok, old} = PlayerSnapshot.encode(@uuid, snapshot)
      {:ok, legacy} = PlayerSnapshot.decode(old, @uuid)
      refute Map.has_key?(legacy, :fire_ticks)
      body_size = byte_size(old) - 92

      <<"VMCPOSE", base, old_header::binary-size(52), old_body::binary-size(^body_size),
        _::binary-size(32)>> = old

      for ticks <- [-2_147_483_648, -20, 0, 1, 300, 2_147_483_647] do
        assert {:ok,
                <<"VMCPOSE", 17, header::binary-size(52), ^base, ^ticks::signed-32,
                  body::binary-size(^body_size), _::binary-size(32)>> = bytes} =
                 PlayerSnapshot.encode(@uuid, Map.put(snapshot, :fire_ticks, ticks))

        assert header == old_header and body == old_body
        assert byte_size(bytes) == byte_size(old) + 5
        assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid)
        assert restored == Map.put(legacy, :fire_ticks, ticks)
        assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)

        assert PlayerSnapshot.transfer_request(@uuid, restored) ==
                 PlayerSnapshot.transfer_request(@uuid, legacy)
      end
    end
  end

  test "capture preserves optional fire state; malformed, recursive and truncated wrappers refuse" do
    snapshot = PlayerSnapshot.capture(Map.put(@pose, :fire_ticks, 300), %Inventory{})
    assert snapshot.fire_ticks == 300
    refute Map.has_key?(PlayerSnapshot.capture(@pose, %Inventory{}), :fire_ticks)
    {:ok, bytes} = PlayerSnapshot.encode(@uuid, snapshot)
    body_size = byte_size(bytes) - 97

    <<header::binary-size(60), _base, _ticks::signed-32, body::binary-size(^body_size),
      _::binary-size(32)>> = bytes

    for ticks <- [-2_147_483_649, 2_147_483_648, 1.0, nil] do
      assert {:error, :invalid_fire_ticks} =
               PlayerSnapshot.encode(@uuid, %{snapshot | fire_ticks: ticks})
    end

    for payload <- [
          header <> <<1, 300::signed-32>> <> body,
          header <> <<17, 300::signed-32>> <> body,
          header <> <<15, 300::signed-32, 17>> <> body,
          header <> <<2, 300::signed-32>>,
          header <> <<2, 300::signed-32>> <> body <> <<0>>,
          header <> <<2, 0, 0, 1>>
        ] do
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(seal(payload), @uuid)
    end

    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes, <<93::128>>)
    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes <> <<0>>, @uuid)
  end
end
