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
end
