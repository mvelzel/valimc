defmodule Valimc.PlayerSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.{ItemStack, Wire}
  defp pose, do: %{x: -3.25, y: 64.0, z: 17.75, yaw: 123.5, pitch: -25.0}
  defp uuid, do: <<27::128>>
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  defp legacy(id \\ uuid()) do
    p = pose()

    seal(
      <<"VMCPOSE", 1, id::binary-size(16), p.x::float-64, p.y::float-64, p.z::float-64,
        p.yaw::float-32, p.pitch::float-32>>
    )
  end

  defp inventory do
    patched = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"persist" => {:string, "unchanged"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    %Inventory{
      slots: %{
        1 => ItemStack.new("egg", 3),
        5 => ItemStack.new("diamond_helmet"),
        9 => patched,
        36 => ItemStack.new("stone", 23),
        38 => ItemStack.new("egg", 6),
        45 => ItemStack.new("shield")
      },
      selected: 2,
      carried: patched,
      state_id: 32767,
      infinite_materials: true,
      drag: %{type: 2, targets: MapSet.new([9, 10])}
    }
  end

  test "supported state preserves slots, selection and patches but not session authority" do
    original = inventory()
    snapshot = PlayerSnapshot.capture(pose(), original)
    assert {:ok, bytes} = PlayerSnapshot.encode(uuid(), snapshot)
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()

    assert {:ok, %{pose: restored_pose, inventory: restored}} =
             PlayerSnapshot.decode(bytes, uuid())

    assert restored_pose == pose()
    assert restored.slots == original.slots and restored.carried == original.carried
    assert restored.selected == 2
    assert restored.state_id == 0 and restored.drag == nil and not restored.infinite_materials

    assert {:ok, ^bytes} =
             PlayerSnapshot.encode(uuid(), PlayerSnapshot.capture(restored_pose, restored))
  end

  test "legacy poses migrate to empty inventory and version 2 on encoding" do
    assert byte_size(legacy()) == 88
    assert {:ok, snapshot} = PlayerSnapshot.decode(legacy(), uuid())
    assert snapshot.pose == pose() and snapshot.inventory == Inventory.new()
    assert {:ok, <<"VMCPOSE", 2, _::binary>>} = PlayerSnapshot.encode(uuid(), snapshot)
    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(legacy(<<0::128>>), uuid())
  end

  test "checksummed but malformed modern state is rejected with no partial recovery" do
    {:ok, bytes} = PlayerSnapshot.encode(uuid(), PlayerSnapshot.capture(pose(), inventory()))
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<prefix::binary-size(56), _data_version::32, _selected, stacks::binary>> = payload
    <<header::binary-size(7), _version, fields::binary>> = payload
    empty_slots = :binary.copy(<<0>>, 45)

    for corrupt <- [
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          payload <> <<0::256>>,
          seal(header <> <<3>> <> fields),
          seal(prefix <> <<5024::32, 2>> <> stacks),
          seal(prefix <> <<5023::32, 9>> <> stacks),
          seal(payload <> <<0>>),
          seal(prefix <> <<5023::32, 0>> <> binary_part(stacks, 0, 4)),
          seal(prefix <> <<5023::32, 0>> <> empty_slots <> Wire.varint(100)),
          seal(
            prefix <> <<5023::32, 0>> <> empty_slots <> <<1>> <> Wire.varint(99999) <> <<0, 0>>
          ),
          :binary.copy(<<0>>, PlayerSnapshot.max_bytes() + 1)
        ] do
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(corrupt, uuid())
    end

    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bytes, <<0::128>>)
  end

  test "write admission rejects invalid slots, virtual result, selection and aggregate bytes" do
    original = inventory()

    for bad <- [
          %{original | selected: 9},
          %{original | slots: %{46 => ItemStack.new("stone")}},
          %{original | slots: %{0 => ItemStack.new("stone")}},
          %{original | carried: ItemStack.new("egg", 17)},
          %{original | slots: %{9 => :invalid}},
          %{original | carried: ItemStack.new("air")}
        ] do
      assert {:error, _} = PlayerSnapshot.encode(uuid(), PlayerSnapshot.capture(pose(), bad))
    end

    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"large" => {:byte_array, :binary.copy(<<11>>, 60_000)}}}
        }
    }

    too_big = %Inventory{slots: Map.new(9..17, &{&1, large})}

    assert {:error, :inventory_byte_limit} =
             PlayerSnapshot.encode(uuid(), PlayerSnapshot.capture(pose(), too_big))

    legal = %{too_big | slots: Map.delete(too_big.slots, 17)}
    assert {:ok, bytes} = PlayerSnapshot.encode(uuid(), PlayerSnapshot.capture(pose(), legal))
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.inventory == legal
  end

  defp pending do
    %{
      pose: pose(),
      inventory: inventory(),
      transfer_sequence: 7,
      outbox: %{
        key: {0, 0},
        records: [%{uuid: <<14::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("stone", 3)}]
      }
    }
  end

  test "version 3 preserves source sequence and one canonical outbox across recovery" do
    state = pending()
    assert {:ok, <<"VMCPOSE", 3, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), state)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.transfer_sequence == 7 and restored.outbox == state.outbox
    assert restored.inventory.slots == state.inventory.slots
    assert not restored.inventory.infinite_materials and restored.inventory.drag == nil
    assert {:ok, {0, 0}, request, digest} = PlayerSnapshot.transfer_request(uuid(), restored)
    assert request.source == uuid() and request.sequence == 7
    assert request.records == state.outbox.records and byte_size(digest) == 32
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)
    cleared = %{restored | outbox: nil}
    assert {:ok, cleared_bytes} = PlayerSnapshot.encode(uuid(), cleared)
    assert {:ok, ^cleared} = PlayerSnapshot.decode(cleared_bytes, uuid())
    assert {:error, :no_pending_transfer} = PlayerSnapshot.transfer_request(uuid(), cleared)
  end

  test "outbox validation rejects unsupported, empty, wrong-region and excessive owned data" do
    state = pending()
    [record] = state.outbox.records

    for bad <- [
          %{state | transfer_sequence: 0},
          %{state | transfer_sequence: -1},
          %{state | transfer_sequence: 18_446_744_073_709_551_616},
          %{state | outbox: %{state.outbox | key: {1, 0}}},
          %{state | outbox: %{state.outbox | records: []}},
          %{state | outbox: %{state.outbox | records: [record, record]}},
          %{state | outbox: %{state.outbox | records: [%{record | stack: nil}]}},
          %{state | outbox: %{state.outbox | records: [%{record | uuid: <<0>>}]}},
          %{
            state
            | outbox: %{state.outbox | records: [%{record | stack: ItemStack.new("egg", 17)}]}
          },
          %{
            state
            | outbox: %{state.outbox | records: Enum.map(1..6, &%{record | uuid: <<&1::128>>})}
          }
        ],
        do: assert(match?({:error, _}, PlayerSnapshot.encode(uuid(), bad)))
  end

  test "checksummed invalid modern journal fields cannot partially restore inventory" do
    {:ok, bytes} = PlayerSnapshot.encode(uuid(), pending())
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _seq::64, length::32, rest::binary>> = payload
    <<outbox::binary-size(^length), inventory::binary>> = rest
    <<outbox_prefix::binary-size(8), _version, outbox_rest::binary>> = outbox
    invalid_outbox = outbox_prefix <> <<2>> <> outbox_rest

    for corrupt <- [
          seal(header <> <<0::64, length::32>> <> rest),
          seal(header <> <<7::64, 327_936::32>> <> rest),
          seal(header <> <<7::64, length + 1::32>> <> rest),
          seal(header <> <<7::64, length::32>> <> invalid_outbox <> inventory),
          seal(payload <> <<0>>),
          seal(header <> <<7::64, 0::32>> <> :binary.copy(<<0>>, 524_289)),
          :binary.copy(<<0>>, PlayerSnapshot.max_bytes() + 1)
        ],
        do: assert({:error, :invalid_player_file} == PlayerSnapshot.decode(corrupt, uuid()))
  end
end
