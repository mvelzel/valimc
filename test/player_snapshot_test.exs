defmodule Valimc.PlayerSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot}
  alias Valimc.Protocol.{ItemStack, Wire}
  defp pose, do: %{x: -3.25, y: 64.0, z: 17.75, yaw: 123.5, pitch: -25.0}
  defp uuid, do: <<27::128>>
  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "food clock and float state share the inventory journal; v11 remains readable" do
    legacy = %{
      pose: pose(),
      inventory: %Inventory{},
      game_mode: Valimc.GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %Valimc.PlayerHealth{},
      last_death: nil,
      air_supply: 17
    }

    food = %Valimc.PlayerFood{level: 18, saturation: 20.5, exhaustion: 39.5, timer: 79}
    snapshot = Map.put(legacy, :food, food)
    assert {:ok, <<"VMCPOSE", 12, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), snapshot)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.food == food and restored.air_supply == 17
    assert restored.transfer_sequence == 0 and restored.outbox == nil
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)
    assert {:ok, <<"VMCPOSE", 11, _::binary>> = old} = PlayerSnapshot.encode(uuid(), legacy)
    assert byte_size(bytes) == byte_size(old) + 11
    assert {:ok, decoded} = PlayerSnapshot.decode(old, uuid())
    assert Valimc.PlayerFood.state(decoded) == %Valimc.PlayerFood{}

    for invalid <- [
          %{food | level: 21},
          %{food | saturation: 21.5},
          %{food | exhaustion: -1.0},
          %{food | timer: 81},
          nil
        ] do
      assert {:error, :invalid_food} = PlayerSnapshot.encode(uuid(), %{snapshot | food: invalid})
    end

    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _food::binary-size(11), rest::binary>> = payload

    for invalid <- [
          <<21, 5.0::float-32, 0.0::float-32, 0::16>>,
          <<20, 0x7FC00000::32, 0.0::float-32, 0::16>>,
          <<20, 5.0::float-32, -1.0::float-32, 0::16>>,
          <<20, 5.0::float-32, 0.0::float-32, 81::16>>
        ] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(seal(header <> invalid <> rest), uuid())
    end
  end

  test "air shares the health/inventory journal checksum; v10 remains readable" do
    snapshot = %{
      pose: pose(),
      inventory: %Inventory{},
      game_mode: Valimc.GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %Valimc.PlayerHealth{},
      last_death: nil,
      air_supply: -19
    }

    assert {:ok, <<"VMCPOSE", 11, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), snapshot)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.air_supply == -19 and restored.health.value == 20.0
    assert restored.transfer_sequence == 0 and restored.outbox == nil
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)
    legacy = Map.delete(snapshot, :air_supply)
    assert {:ok, <<"VMCPOSE", 10, _::binary>> = old} = PlayerSnapshot.encode(uuid(), legacy)
    assert byte_size(bytes) == byte_size(old) + 2
    assert {:ok, decoded} = PlayerSnapshot.decode(old, uuid())
    assert Map.get(decoded, :air_supply, Valimc.PlayerAir.maximum()) == 300

    for air <- [-21, 301, 0.5, nil] do
      assert {:error, :invalid_air_supply} =
               PlayerSnapshot.encode(uuid(), %{snapshot | air_supply: air})
    end

    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _air::signed-16, rest::binary>> = payload

    for air <- [-21, 301] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(seal(header <> <<air::signed-16>> <> rest), uuid())
    end
  end

  test "health and saved hurt timers share the velocity/inventory/outbox checksum" do
    state =
      Map.merge(pending(), %{
        game_mode: Valimc.GameMode.new(:survival),
        flying: false,
        fall_distance: 3.25,
        frozen_ticks: 88,
        velocity: {0.3, -1.2, 12.0},
        health: %{value: 7.25, hurt_ticks: 7, death_ticks: 11}
      })

    assert {:ok, <<"VMCPOSE", 9, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), state)
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.health == state.health
    assert restored.velocity == state.velocity and restored.outbox == state.outbox
    assert restored.transfer_sequence == 7 and restored.inventory.slots == state.inventory.slots
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)
    assert {:ok, {0, 0}, request, _} = PlayerSnapshot.transfer_request(uuid(), restored)
    assert request.sequence == 7 and request.records == state.outbox.records

    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<header::binary-size(60), _health::binary-size(8), rest::binary>> = payload

    for health <- [
          state.health |> Map.put(:value, -1.0),
          %{state.health | value: 1025.0},
          %{state.health | hurt_ticks: 32768},
          %{state.health | death_ticks: -1}
        ] do
      assert {:error, :invalid_health} = PlayerSnapshot.encode(uuid(), %{state | health: health})
    end

    for fields <- [
          <<-1.0::float-32, 7::16, 11::16>>,
          <<1025.0::float-32, 7::16, 11::16>>,
          <<0x7FC00000::32, 7::16, 11::16>>,
          <<0x7F800000::32, 7::16, 11::16>>,
          <<7.25::float-32, 32768::16, 11::16>>,
          <<7.25::float-32, 7::16, 65535::16>>
        ] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(seal(header <> fields <> rest), uuid())
    end

    player =
      Map.merge(pose(), %{
        game_mode: state.game_mode,
        abilities: Valimc.PlayerAbilities.for_mode(:survival),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
        health: %Valimc.PlayerHealth{value: 7.25, hurt_ticks: 7, cooldown: 17, last_hurt: 5.0}
      })

    assert PlayerSnapshot.capture(player, %Inventory{}).health == %{
             value: 7.25,
             hurt_ticks: 7,
             death_ticks: 0
           }
  end

  test "freeze state shares the bounded checksummed player snapshot" do
    player =
      Map.merge(pose(), %{
        game_mode: Valimc.GameMode.new(:creative),
        abilities: Valimc.PlayerAbilities.for_mode(:creative),
        motion: %Valimc.PlayerMotion{fall_distance: 3.25},
        environment: %Valimc.PlayerEnvironment{frozen_ticks: 88}
      })

    original = PlayerSnapshot.capture(player, %Inventory{}) |> Map.delete(:velocity)
    assert {:ok, <<"VMCPOSE", 7, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), original)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, uuid())
    assert decoded.frozen_ticks == 88 and decoded.fall_distance == 3.25
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), _::binary-size(32)>> = bytes
    <<header::binary-size(60), _frozen::32, rest::binary>> = payload

    for value <- [141, 0xFFFFFFFF] do
      invalid = seal(<<header::binary, value::32, rest::binary>>)
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(invalid, uuid())

      assert {:error, :invalid_frozen_ticks} =
               PlayerSnapshot.encode(uuid(), %{original | frozen_ticks: value})
    end
  end

  test "fall distance persists with inventory/journal state and rejects invalid sealed values" do
    player =
      Map.merge(pose(), %{
        game_mode: Valimc.GameMode.new(:creative),
        abilities: Valimc.PlayerAbilities.for_mode(:creative),
        motion: %Valimc.PlayerMotion{fall_distance: 3.25}
      })

    original = PlayerSnapshot.capture(player, %Inventory{}) |> Map.delete(:velocity)
    assert {:ok, <<"VMCPOSE", 6, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), original)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, uuid())
    assert decoded.fall_distance == 3.25
    assert decoded.game_mode == original.game_mode
    assert decoded.transfer_sequence == 0 and decoded.outbox == nil

    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), _::binary-size(32)>> = bytes
    <<header::binary-size(60), _distance::binary-size(8), rest::binary>> = payload

    for distance <- [-1.0, 60_000_001.0] do
      invalid = seal(<<header::binary, distance::float-64, rest::binary>>)
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(invalid, uuid())

      assert {:error, :invalid_fall_distance} =
               PlayerSnapshot.encode(uuid(), %{original | fall_distance: distance})
    end

    nan = seal(<<header::binary, 0x7FF8000000000000::64, rest::binary>>)
    assert {:error, :invalid_player_file} = PlayerSnapshot.decode(nan, uuid())
  end

  defp legacy(id \\ uuid()) do
    p = pose()

    seal(
      <<"VMCPOSE", 1, id::binary-size(16), p.x::float-64, p.y::float-64, p.z::float-64,
        p.yaw::float-32, p.pitch::float-32>>
    )
  end

  test "velocity is atomic with fall, freeze and the pending transfer journal" do
    state =
      Map.merge(pending(), %{
        game_mode: Valimc.GameMode.new(:creative),
        flying: false,
        fall_distance: 3.25,
        frozen_ticks: 88,
        velocity: {0.3, -1.2, 12.0}
      })

    assert {:ok, <<"VMCPOSE", 8, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), state)
    assert byte_size(bytes) <= PlayerSnapshot.max_bytes()
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, uuid())
    assert restored.pose == state.pose and restored.velocity == state.velocity
    assert restored.fall_distance == 3.25 and restored.frozen_ticks == 88
    assert restored.outbox == state.outbox and restored.transfer_sequence == 7
    assert restored.inventory.slots == state.inventory.slots
    assert {:ok, {0, 0}, request, _} = PlayerSnapshot.transfer_request(uuid(), restored)
    assert request.records == state.outbox.records and request.sequence == 7
    assert {:ok, ^bytes} = PlayerSnapshot.encode(uuid(), restored)
    size = byte_size(bytes) - 32
    <<payload::binary-size(^size), _::binary-size(32)>> = bytes
    <<header::binary-size(60), _velocity::binary-size(24), rest::binary>> = payload

    for component <- [65.0, -65.0] do
      assert {:error, :invalid_velocity} =
               PlayerSnapshot.encode(uuid(), %{state | velocity: {component, 0.0, 0.0}})

      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(
                 seal(
                   <<header::binary, component::float-64, 0.0::float-64, 0.0::float-64,
                     rest::binary>>
                 ),
                 uuid()
               )
    end

    for component <- [0x7FF8000000000000, 0x7FF0000000000000, 0xFFF0000000000000] do
      assert {:error, :invalid_player_file} =
               PlayerSnapshot.decode(
                 seal(
                   <<header::binary, component::64, 0.0::float-64, 0.0::float-64, rest::binary>>
                 ),
                 uuid()
               )
    end
  end

  test "capture includes server velocity and old fall-only fixtures remain migratable" do
    player =
      Map.merge(pose(), %{
        game_mode: Valimc.GameMode.new(:creative),
        abilities: Valimc.PlayerAbilities.for_mode(:creative),
        motion: %Valimc.PlayerMotion{velocity: {1.0, 2.0, 3.0}, fall_distance: 2.0}
      })

    snapshot = PlayerSnapshot.capture(player, %Inventory{})
    assert snapshot.velocity == {1.0, 2.0, 3.0}
    assert {:ok, <<"VMCPOSE", 8, _::binary>> = bytes} = PlayerSnapshot.encode(uuid(), snapshot)
    assert {:ok, decoded} = PlayerSnapshot.decode(bytes, uuid())
    assert decoded.velocity == snapshot.velocity and decoded.frozen_ticks == 0

    for version <- [6, 7] do
      old =
        snapshot
        |> Map.delete(:velocity)
        |> then(&if(version == 7, do: Map.put(&1, :frozen_ticks, 17), else: &1))

      assert {:ok, <<"VMCPOSE", ^version, _::binary>> = legacy} =
               PlayerSnapshot.encode(uuid(), old)

      assert {:ok, restored} = PlayerSnapshot.decode(legacy, uuid())
      refute Map.has_key?(restored, :velocity)
      assert restored.fall_distance == 2.0
    end
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

  test "pose-only files from before M1 are refused, not migrated to an empty inventory" do
    assert byte_size(legacy()) == 88
    assert PlayerSnapshot.decode(legacy(), uuid()) == {:error, :unsupported_player_file}
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

defmodule Valimc.PlayerSnapshotTest.TableLayer do
  # An open crafting table wraps whatever journal the player has pending (layer 15).
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerSnapshot}
  alias Valimc.Protocol.{Data, ItemStack}
  @uuid <<31::128>>

  defp cells, do: List.to_tuple([ItemStack.new("oak_planks", 3) | List.duplicate(nil, 8)])

  # The player's inventory with three planks in the open table's grid.
  defp table(inventory), do: %{inventory | table_inputs: cells()}

  defp player(inventory) do
    %{
      pose: %{x: 1.5, y: 64.0, z: 1.5, yaw: 0.0, pitch: 0.0},
      inventory: table(inventory),
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 19.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 9,
      outbox: nil
    }
  end

  defp record(stack), do: %{uuid: <<11::128>>, x: 1.5, y: 64.5, z: 1.5, stack: stack}

  # One pending journal of each outbox kind, as each transfer prepares it.
  defp pending(:items) do
    before = player(%Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    kept = put_in(before.inventory.slots[36], ItemStack.new("stone", 4))
    records = [record(ItemStack.new("stone", 3))]
    {:ok, pending} = Valimc.PlayerTransfers.prepare(@uuid, 9, before, kept, {0, 0}, records)
    pending
  end

  defp pending(:mining) do
    intent = %{
      kind: :mining,
      key: {0, 0},
      permit: <<73::128>>,
      target: {1, 63, 1},
      slot: 43,
      before: ItemStack.new("iron_pickaxe"),
      after: nil,
      expected: %{{1, 63, 1} => Data.block("stone")},
      records: [record(ItemStack.new("cobblestone"))]
    }

    %{player(%Inventory{selected: 7}) | outbox: intent}
  end

  defp pending(:placement) do
    stack = ItemStack.new("stone", 2)
    state = player(%Inventory{selected: 7, slots: %{43 => stack}})

    intent = %{
      kind: :placement,
      key: {0, 0},
      permit: <<84::128>>,
      slot: 43,
      before: stack,
      after: %{stack | count: 1},
      request: %{
        hand: :main,
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

    {:ok, pending} = Valimc.PlayerPlacementTransfers.prepare(@uuid, 9, state, intent)
    pending
  end

  defp pending(:pickup) do
    request = %{
      source: @uuid,
      sequence: 10,
      permit: <<82::128>>,
      item_uuid: <<83::128>>,
      generation: 0,
      before: ItemStack.new("stone", 7),
      remainder: nil
    }

    intent = %{kind: :pickup, key: {0, 0}, request: request}
    {:ok, pending} = Valimc.PlayerPickupTransfers.prepare(@uuid, 9, player(%Inventory{}), intent)
    pending
  end

  # An XP orb pickup: a container journal without a menu, so a table can be open.
  defp pending(:experience) do
    state = Map.put(player(%Inventory{}), :progression, %Valimc.PlayerProgression{})

    request = %{
      kind: :experience,
      position: {1, 64, 1},
      permit: <<0::128>>,
      orb_uuid: <<85::128>>,
      value: 7,
      consumed: 0,
      before: %Valimc.PlayerExperience{},
      collector: 17
    }

    intent = %{kind: :container, key: {0, 0}, request: request}
    {:ok, pending} = Valimc.PlayerContainerTransfers.prepare(@uuid, 9, state, intent)
    pending
  end

  test "every pending journal kind round-trips while a crafting table is open" do
    for kind <- [:items, :mining, :placement, :pickup, :experience] do
      state = pending(kind)
      assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, state)
      assert {:ok, restored} = PlayerSnapshot.decode(bytes, @uuid), "#{kind} did not decode"
      assert restored.inventory.table_inputs == cells()
      assert restored.outbox == state.outbox
      assert restored.transfer_sequence == state.transfer_sequence
      assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, restored)
    end
  end
end
