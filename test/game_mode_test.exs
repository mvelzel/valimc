defmodule Valimc.GameModeTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerAbilities, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.ItemStack
  @modes [:survival, :creative, :adventure, :spectator]
  defp pose, do: %{x: 0.5, y: 64.0, z: 0.5, yaw: 20.0, pitch: 5.0}

  defp snapshot(mode, flying) do
    PlayerSnapshot.capture(
      Map.merge(pose(), %{game_mode: mode, abilities: %PlayerAbilities{flying: flying}}),
      %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    )
  end

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "all forty mode/history/flight snapshots preserve inventory and the bounded journal" do
    uuid = <<31::128>>

    for current <- @modes, previous <- [nil | @modes], flying <- [false, true] do
      mode = %GameMode{current: current, previous: previous}
      original = snapshot(mode, flying)
      assert {:ok, <<"VMCPOSE", 5, _::binary>> = bytes} = PlayerSnapshot.encode(uuid, original)
      assert {:ok, result} = PlayerSnapshot.decode(bytes, uuid)
      assert result.game_mode == mode and result.flying == flying
      assert result.inventory == original.inventory and result.pose == original.pose
      assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid, result)
    end
  end

  test "checksummed invalid current/previous modes reject, and older flight-only records remain readable" do
    uuid = <<32::128>>
    {:ok, bytes} = PlayerSnapshot.encode(uuid, snapshot(%GameMode{}, true))
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _current, _previous, tail::binary>> = payload

    for fields <- [<<4, 255>>, <<255, 255>>, <<1, 4>>, <<1, 254>>] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(seal(header <> fields <> tail), uuid)
    end

    assert {:error, :invalid_player_state} =
             PlayerSnapshot.encode(uuid, snapshot(%GameMode{current: :unknown}, true))

    original = snapshot(%GameMode{}, true) |> Map.delete(:game_mode)
    assert {:ok, <<"VMCPOSE", 4, _::binary>> = old} = PlayerSnapshot.encode(uuid, original)
    assert {:ok, migrated} = PlayerSnapshot.decode(old, uuid)
    assert migrated.flying and not Map.has_key?(migrated, :game_mode)
    assert {:ok, ^old} = PlayerSnapshot.encode(uuid, migrated)
  end

  test "conserved and creative source journals preserve mode identity and previous history" do
    uuid = <<33::128>>
    mode = %GameMode{current: :creative, previous: :spectator}
    before = snapshot(mode, true)

    after_state = %{
      before
      | inventory: %{before.inventory | slots: %{36 => ItemStack.new("stone", 6)}}
    }

    record = %{uuid: <<34::128>>, x: 0.5, y: 65.0, z: 0.5, stack: ItemStack.new("stone")}

    assert {:ok, planned} =
             PlayerTransfers.prepare(uuid, 0, before, after_state, {0, 0}, [record])

    assert planned.game_mode == mode
    assert {:ok, bytes} = PlayerSnapshot.encode(uuid, planned)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid)
    assert restored.game_mode == mode and restored.flying and restored.outbox == planned.outbox
    authorized = %{before | inventory: %{before.inventory | infinite_materials: true}}

    assert {:ok, created} =
             PlayerTransfers.prepare_creative_drop(uuid, 1, authorized, {0, 0}, record)

    assert created.game_mode == mode
  end
end
