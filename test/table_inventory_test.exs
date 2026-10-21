defmodule Valimc.TableInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.ItemStack
  @uuid <<29::128>>

  defp patched do
    %{
      ItemStack.new("oak_planks", 3)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"table" => {:string, "owned"}}},
          "minecraft:enchantments" => %{"minecraft:vanishing_curse" => 1}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }
  end

  defp inventory do
    %Inventory{
      slots: %{
        1 => ItemStack.new("diamond"),
        5 => ItemStack.new("iron_helmet"),
        38 => ItemStack.new("stone", 7),
        45 => ItemStack.new("shield")
      },
      selected: 2,
      carried: ItemStack.new("egg", 3),
      table_inputs: List.duplicate(patched(), 9) |> List.to_tuple()
    }
  end

  defp snapshot(inventory),
    do: %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: inventory}

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  test "v15 preserves all nine exact inputs and existing journal; plain snapshots keep their format" do
    original = snapshot(%{inventory() | drag: %{mode: 0}, state_id: 11, infinite_materials: true})
    assert {:ok, <<"VMCPOSE", 15, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, original)
    assert {:ok, loaded} = PlayerSnapshot.decode(bytes, @uuid)

    assert loaded.inventory == %{
             original.inventory
             | drag: nil,
               state_id: 0,
               infinite_materials: false
           }

    assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, loaded)
    plain = put_in(original.inventory.table_inputs, nil)
    assert {:ok, <<"VMCPOSE", 2, _::binary>> = legacy} = PlayerSnapshot.encode(@uuid, plain)
    assert {:ok, restored} = PlayerSnapshot.decode(legacy, @uuid)
    assert restored.inventory.table_inputs == nil

    {:ok, next, stacks} = Inventory.disconnect(original.inventory)

    records =
      Enum.with_index(stacks, 1)
      |> Enum.map(fn {stack, index} ->
        %{uuid: <<index::128>>, x: 0.5, y: 65.0, z: 0.5, stack: stack}
      end)

    assert {:ok, pending} =
             PlayerTransfers.prepare(
               @uuid,
               7,
               original,
               %{original | inventory: next},
               {0, 0},
               records
             )

    assert {:ok, <<"VMCPOSE", 15, _::binary>> = bytes} = PlayerSnapshot.encode(@uuid, pending)
    assert {:ok, loaded} = PlayerSnapshot.decode(bytes, @uuid)
    assert loaded.transfer_sequence == 8 and loaded.outbox == pending.outbox
    assert loaded.inventory.table_inputs == next.table_inputs
    assert {:ok, ^bytes} = PlayerSnapshot.encode(@uuid, loaded)
  end

  test "table and physical inventory share one aggregate budget and reject malformed extensions" do
    inv = inventory()

    for bad <- [
          [],
          {},
          List.duplicate(nil, 8) |> List.to_tuple(),
          List.duplicate(nil, 10) |> List.to_tuple(),
          put_elem(inv.table_inputs, 0, ItemStack.new("air")),
          put_elem(inv.table_inputs, 0, ItemStack.new("egg", 17))
        ] do
      assert {:error, _} = PlayerSnapshot.encode(@uuid, snapshot(%{inv | table_inputs: bad}))
    end

    big = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"big" => {:byte_array, :binary.copy(<<1>>, 60_000)}}}
        }
    }

    legal = %Inventory{
      slots: Map.new(9..15, &{&1, big}),
      table_inputs: List.to_tuple([big | List.duplicate(nil, 8)])
    }

    assert {:ok, bytes} = PlayerSnapshot.encode(@uuid, snapshot(legal))
    assert {:ok, loaded} = PlayerSnapshot.decode(bytes, @uuid)
    assert loaded.inventory == legal
    too_big = %{legal | table_inputs: put_elem(legal.table_inputs, 1, big)}
    assert {:error, :inventory_byte_limit} = PlayerSnapshot.encode(@uuid, snapshot(too_big))
    assert {:error, :inventory_byte_limit} = Inventory.creative(too_big, 36, nil)

    payload_size = byte_size(bytes) - 32
    <<payload::binary-size(^payload_size), _::binary-size(32)>> = bytes
    <<header::binary-size(60), _base, tail::binary>> = payload

    for bad <- [
          seal(header <> <<15>> <> tail),
          seal(header <> <<1>> <> tail),
          seal(payload <> <<0>>),
          binary_part(bytes, 0, byte_size(bytes) - 1)
        ] do
      assert {:error, :invalid_player_file} = PlayerSnapshot.decode(bad, @uuid)
    end

    # A valid checksum cannot admit an over-budget extension either.
    {:ok, <<"VMCPOSE", 2, rest::binary>>} =
      PlayerSnapshot.encode(@uuid, snapshot(%{legal | table_inputs: nil}))

    rest = binary_part(rest, 0, byte_size(rest) - 32)
    <<header::binary-size(52), physical::binary>> = rest

    extension =
      IO.iodata_to_binary([
        ItemStack.encode(big),
        ItemStack.encode(big),
        List.duplicate(<<0>>, 7)
      ])

    assert {:error, :invalid_player_file} =
             PlayerSnapshot.decode(
               seal(<<"VMCPOSE", 15, header::binary, 2, extension::binary, physical::binary>>),
               @uuid
             )
  end

  test "bounded disconnect retains each uncommitted input and conservation rejects omission" do
    inv = inventory()
    {:ok, next, first} = Inventory.disconnect(inv)
    assert first == [inv.carried, inv.slots[1], patched(), patched(), patched()]
    assert Enum.count(Inventory.table_contents(next), &(&1 != nil)) == 6
    assert Map.drop(inv.slots, [1]) == next.slots and next.carried == nil
    {:ok, last, second} = Inventory.disconnect(next)
    assert length(second) == 5 and Enum.count(Inventory.table_contents(last), &(&1 != nil)) == 1
    {:ok, empty, [final]} = Inventory.disconnect(last)
    assert final == patched() and empty.table_inputs == nil
    assert {:ok, _, []} = Inventory.disconnect(empty)
    before = snapshot(inv)
    after_snapshot = snapshot(%{next | table_inputs: nil})

    records =
      Enum.with_index(first, 1)
      |> Enum.map(fn {stack, index} ->
        %{uuid: <<index::128>>, x: 0.5, y: 65.0, z: 0.5, stack: stack}
      end)

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(@uuid, 0, before, after_snapshot, {0, 0}, records)
  end
end
