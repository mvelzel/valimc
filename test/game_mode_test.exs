defmodule Valimc.GameModeTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerAbilities, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  @modes [:survival, :creative, :adventure, :spectator]
  defp pose, do: %{x: 0.5, y: 64.0, z: 0.5, yaw: 20.0, pitch: 5.0}

  defp snapshot(mode, flying) do
    PlayerState.capture(
      Map.merge(pose(), %{game_mode: mode, abilities: %PlayerAbilities{flying: flying}}),
      %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    )
  end

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

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
    assert {:ok, bytes} = PlayerState.encode(uuid, planned)
    assert {:ok, restored} = PlayerState.decode(bytes, uuid)
    assert restored.game_mode == mode and restored.flying and restored.outbox == planned.outbox
    authorized = %{before | inventory: %{before.inventory | infinite_materials: true}}

    assert {:ok, created} =
             PlayerTransfers.prepare_creative_drop(uuid, 1, authorized, {0, 0}, record)

    assert created.game_mode == mode
  end
end
