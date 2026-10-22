defmodule Valimc.PlayerAbilitiesTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerAbilities, Inventory, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  import Bitwise

  test "all client flags affect only permission-gated flight; malformed bodies reject" do
    for mode <- [:survival, :creative, :adventure, :spectator], flags <- 0..255 do
      original = PlayerAbilities.for_mode(mode)
      assert {:ok, result} = PlayerAbilities.request_flight(original, <<flags>>)
      assert result.flying == ((flags &&& 2) != 0 and original.may_fly)
      assert %{result | flying: original.flying} == original
    end

    for body <- [<<>>, <<2, 0>>, <<2, 0.05::float-32, 0.1::float-32>>] do
      assert {:error, :invalid_abilities_packet} =
               PlayerAbilities.request_flight(PlayerAbilities.for_mode(:creative), body)
    end
  end

  defp pose, do: %{x: 0.5, y: 70.0, z: 0.5, yaw: 20.0, pitch: 5.0}

  defp snapshot(flying),
    do:
      PlayerState.capture(
        Map.put(pose(), :abilities, %{PlayerAbilities.for_mode(:creative) | flying: flying}),
        Inventory.new(true)
      )

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "ordinary and creative transfer plans retain flight and their journals encode version 4" do
    uuid = <<24::128>>

    before = %{
      snapshot(true)
      | inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 2)}, infinite_materials: true}
    }

    next = %{before | inventory: %{before.inventory | slots: %{36 => ItemStack.new("stone")}}}
    record = %{uuid: <<25::128>>, x: 0.5, y: 71.0, z: 0.5, stack: ItemStack.new("stone")}
    assert {:ok, plan} = PlayerTransfers.prepare(uuid, 0, before, next, {0, 0}, [record])
    assert plan.flying and plan.transfer_sequence == 1
    assert {:ok, bytes} = PlayerState.encode(uuid, plan)
    assert {:ok, decoded} = PlayerState.decode(bytes, uuid)
    assert decoded.flying and decoded.outbox == plan.outbox
    assert {:ok, created} = PlayerTransfers.prepare_creative_drop(uuid, 1, before, {0, 0}, record)
    assert created.flying and created.transfer_sequence == 2
  end
end
