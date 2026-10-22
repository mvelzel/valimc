defmodule Valimc.Player.StateTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerFood, PlayerProgression}
  alias Valimc.Living
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Storage.Checkpoint

  @uuid <<27::128>>

  defp patched,
    do: %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"persist" => {:string, "unchanged"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

  defp inventory,
    do: %Inventory{
      slots: %{
        1 => ItemStack.new("egg", 3),
        5 => ItemStack.new("diamond_helmet"),
        9 => patched(),
        36 => ItemStack.new("stone", 23),
        45 => ItemStack.new("shield")
      },
      selected: 2,
      carried: patched(),
      table_inputs: List.to_tuple([ItemStack.new("oak_planks", 3) | List.duplicate(nil, 8)]),
      state_id: 32767,
      infinite_materials: true,
      drag: %{type: 2, targets: MapSet.new([9, 10])}
    }

  defp player do
    %{
      x: -3.25,
      y: 64.0,
      z: 17.75,
      yaw: 123.5,
      pitch: -25.0,
      game_mode: GameMode.new(:survival),
      abilities: %Valimc.PlayerAbilities{flying: false},
      living: %Living{
        (Living.restore(%{health: %{value: 13.5, hurt_ticks: 4, death_ticks: 0}})
         |> elem(1))
        | absorption: 4.0,
          fire_ticks: 80,
          air_supply: 120
      },
      food: %PlayerFood{level: 17, saturation: 1.5, exhaustion: 0.25, timer: 12},
      progression: %PlayerProgression{},
      motion: %Valimc.PlayerMotion{fall_distance: 2.5, velocity: {0.0, -0.0784, 0.0}},
      last_death: {4, 63, -2},
      dimension: :the_nether,
      death_dimension: :overworld,
      portal_cooldown: 300,
      seen_credits: true
    }
  end

  test "a state round-trips every durable field, but not the session's authority" do
    state = PlayerState.capture(player(), inventory())
    assert {:ok, bytes} = PlayerState.encode(@uuid, state)
    assert {:ok, restored} = PlayerState.decode(bytes, @uuid)

    assert restored == %{
             state
             | inventory: %{inventory() | state_id: 0, infinite_materials: false, drag: nil}
           }

    assert restored.absorption == 4.0 and restored.fire_ticks == 80 and restored.seen_credits
  end

  test "another format, another player's file and a changed byte are refused" do
    {:ok, bytes} = PlayerState.encode(@uuid, PlayerState.capture(player(), inventory()))
    assert PlayerState.decode(bytes, <<28::128>>) == {:error, :invalid_player_file}
    <<head::binary-size(40), byte, rest::binary>> = bytes
    flipped = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>
    assert PlayerState.decode(flipped, @uuid) == {:error, :invalid_player_file}

    assert PlayerState.decode("VMCPOSE" <> :binary.copy(<<0>>, 120), @uuid) ==
             {:error, :invalid_player_file}

    # A file missing a field is not filled with defaults (D4: one format).
    {:ok, %{records: records}} = Checkpoint.decode(bytes)
    partial = IO.iodata_to_binary(Checkpoint.encode(0, Map.delete(records, {:player, :food})))
    assert PlayerState.decode(partial, @uuid) == {:error, :invalid_player_file}
  end

  test "every field is checked before it is written" do
    base = PlayerState.capture(player(), inventory())
    slot0 = %{base | inventory: %{base.inventory | slots: %{0 => ItemStack.new("stone")}}}

    huge =
      ItemStack.new("stone")
      |> Map.put(:components, %{
        "minecraft:custom_data" =>
          {:compound, %{"b" => {:byte_array, :binary.copy(<<1>>, 600_000)}}}
      })

    for {state, reason} <- [
          {slot0, :invalid_inventory},
          {%{base | inventory: %{base.inventory | selected: 9}}, :invalid_inventory},
          {%{base | inventory: %{base.inventory | slots: %{1 => huge}}}, :invalid_inventory},
          {%{base | health: %{value: -1.0, hurt_ticks: 0, death_ticks: 0}}, :invalid_health},
          {%{base | food: %PlayerFood{level: 99}}, :invalid_food},
          {%{base | dimension: :moon}, :invalid_dimension},
          {%{base | transfer_sequence: 0, outbox: %{kind: :pickup}}, :invalid_transfer_sequence},
          {%{base | transfer_sequence: 3, outbox: %{kind: :teleport}}, :invalid_outbox}
        ] do
      assert PlayerState.encode(@uuid, state) == {:error, reason}
    end
  end

  test "a save with a transfer pending keeps every durable field but the transfer-bound ones" do
    stored = %{PlayerState.capture(player(), %Inventory{}) | transfer_sequence: 4}
    live = %{PlayerState.capture(player(), inventory()) | absorption: 0.0, food: %PlayerFood{}}
    merged = PlayerState.merge(stored, live)
    assert merged.inventory == stored.inventory and merged.transfer_sequence == 4
    assert merged.absorption == 0.0 and merged.food == %PlayerFood{}
  end
end

defmodule Valimc.Player.StateTest.TableLayer do
  # An open crafting table wraps whatever journal the player has pending (layer 15).
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, Inventory, PlayerFood}
  alias Valimc.Player.State, as: PlayerState
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
      assert {:ok, bytes} = PlayerState.encode(@uuid, state)
      assert {:ok, restored} = PlayerState.decode(bytes, @uuid), "#{kind} did not decode"
      assert restored.inventory.table_inputs == cells()
      assert restored.outbox == state.outbox
      assert restored.transfer_sequence == state.transfer_sequence
      assert {:ok, ^bytes} = PlayerState.encode(@uuid, restored)
    end
  end
end
