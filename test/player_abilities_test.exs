defmodule Valimc.PlayerAbilitiesTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerAbilities, PlayerSnapshot, Inventory, PlayerTransfers}
  alias Valimc.Protocol.{ItemStack, Packets}
  import Bitwise

  test "mode rules preserve speeds, preserve creative flight and force spectator flight" do
    initial = %PlayerAbilities{flying: true, flying_speed: 0.2, walking_speed: 0.3}
    assert PlayerAbilities.for_mode(:creative, initial).flying
    refute PlayerAbilities.for_mode(:creative).flying
    assert PlayerAbilities.for_mode(:spectator).flying

    for mode <- [:survival, :creative, :adventure, :spectator] do
      a = PlayerAbilities.for_mode(mode, initial)
      assert a.flying_speed == 0.2 and a.walking_speed == 0.3
      assert a.may_build == mode in [:survival, :creative]
      assert a.infinite_materials == (mode == :creative)
      assert a.invulnerable == mode in [:creative, :spectator]
      assert a.may_fly == mode in [:creative, :spectator]
      if mode in [:survival, :adventure], do: refute(a.flying)
    end
  end

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

  test "the ability packet represents current flight and omits the local build permission" do
    creative = PlayerAbilities.for_mode(:creative)
    assert elem(Packets.abilities(creative), 1) == <<13, 0.05::float-32, 0.1::float-32>>

    assert elem(Packets.abilities(%{creative | flying: true}), 1) ==
             <<15, 0.05::float-32, 0.1::float-32>>

    assert Packets.abilities(creative) == Packets.abilities(%{creative | may_build: false})
  end

  defp pose, do: %{x: 0.5, y: 70.0, z: 0.5, yaw: 20.0, pitch: 5.0}

  defp snapshot(flying),
    do:
      PlayerSnapshot.capture(
        Map.put(pose(), :abilities, %{PlayerAbilities.for_mode(:creative) | flying: flying}),
        Inventory.new(true)
      )

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "version 4 stores only flight, reads old states and rejects checksum-valid malformed flight/journals" do
    uuid = <<23::128>>

    for flying <- [false, true] do
      assert {:ok, <<"VMCPOSE", 4, _::binary>> = bytes} =
               PlayerSnapshot.encode(uuid, snapshot(flying))

      assert {:ok, result} = PlayerSnapshot.decode(bytes, uuid)
      assert result.flying == flying and result.pose == pose()
      refute result.inventory.infinite_materials
      assert result.transfer_sequence == 0 and result.outbox == nil
      assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid, result)
    end

    old = PlayerSnapshot.capture(pose(), Inventory.new())
    assert {:ok, <<"VMCPOSE", 2, _::binary>> = bytes} = PlayerSnapshot.encode(uuid, old)
    assert {:ok, migrated} = PlayerSnapshot.decode(bytes, uuid)
    refute Map.has_key?(migrated, :flying)
    assert {:error, :invalid_flight_state} = PlayerSnapshot.encode(uuid, Map.put(old, :flying, 1))
    assert {:ok, bytes} = PlayerSnapshot.encode(uuid, snapshot(true))
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _flight, _sequence::64, _length::32, inventory::binary>> = payload

    for bad <- [
          <<header::binary, 2, 0::64, 0::32, inventory::binary>>,
          <<header::binary, 1, 0::64, 1::32, 0, inventory::binary>>,
          <<header::binary, 1, 1::64, 999_999::32, inventory::binary>>,
          binary_part(payload, 0, 72),
          payload <> <<0>>
        ] do
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(seal(bad), uuid)
    end
  end

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
    assert {:ok, bytes} = PlayerSnapshot.encode(uuid, plan)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, uuid)
    assert decoded.flying and decoded.outbox == plan.outbox
    assert {:ok, created} = PlayerTransfers.prepare_creative_drop(uuid, 1, before, {0, 0}, record)
    assert created.flying and created.transfer_sequence == 2
  end
end
