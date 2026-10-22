defmodule Valimc.StackIdentityTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemRecords, Entities, ItemTransfers}

  defp redundant(count) do
    %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:max_stack_size" => 64,
          "minecraft:rarity" => 0,
          "minecraft:repair_cost" => 0,
          "minecraft:item_model" => "minecraft:stone"
        },
        removed: MapSet.new(["minecraft:custom_name", "minecraft:unbreakable"])
    }
  end

  defp data(tag), do: %{ItemStack.new("stone") | components: %{"minecraft:custom_data" => tag}}

  test "ordinary scalar float signed zero remains distinct and malformed identity inputs are rejected" do
    sword = ItemStack.new("iron_sword")
    a = %{sword | components: %{"minecraft:minimum_attack_charge" => 0.0}}
    <<negative::float-32>> = <<0x80000000::32>>
    b = %{sword | components: %{"minecraft:minimum_attack_charge" => negative}}
    refute ItemStack.same_item?(a, b)

    assert catch_throw(ItemStack.identity_key(%{sword | count: 2})) ==
             {:item_error, :stack_size_exceeded}

    assert catch_throw(
             ItemStack.identity_key(%{sword | components: %{"minecraft:custom_name" => "bad"}})
           ) ==
             {:item_error, :invalid_component_value}

    invalid = {:compound, %{"too_deep" => {:list, {:byte, Enum.to_list(1..2000)}}}}

    assert catch_throw(ItemStack.identity_key(data(invalid))) ==
             {:item_error, :invalid_component_value}
  end

  test "partial connected returns conserve effective identity despite changed raw merge representations" do
    stone = ItemStack.new("stone", 64)

    inv = %Inventory{
      slots: Map.new(9..44, &{&1, stone}) |> Map.put(38, %{stone | count: 63}),
      selected: 2,
      carried: redundant(10)
    }

    {:ok, next, [remainder]} = Inventory.close(inv)
    assert next.slots[38].count == 64 and remainder == redundant(9)
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    record = %{uuid: <<2::128>>, x: 0.5, y: 64.5, z: 0.5, stack: remainder}

    assert {:ok, prepared} =
             PlayerTransfers.prepare(
               <<1::128>>,
               8,
               PlayerState.capture(pose, inv),
               PlayerState.capture(pose, next),
               {0, 0},
               [record]
             )

    assert prepared.transfer_sequence == 9 and prepared.outbox.records == [record]
    assert {:ok, bytes} = PlayerState.encode(<<1::128>>, prepared)
    assert {:ok, restored} = PlayerState.decode(bytes, <<1::128>>)
    assert restored.outbox == prepared.outbox

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(
               <<1::128>>,
               8,
               PlayerState.capture(pose, inv),
               PlayerState.capture(pose, next),
               {0, 0},
               [
                 %{
                   record
                   | stack: %{
                       remainder
                       | components: %{"minecraft:enchantment_glint_override" => true}
                     }
                 }
               ]
             )
  end

  test "exact raw transfer receipts survive serialization; semantic equivalence cannot change a pinned intent" do
    record = %{uuid: <<2::128>>, x: 0.5, y: 64.5, z: 0.5, stack: redundant(3)}
    request = %{source: <<1::128>>, sequence: 1, records: [record]}
    {:ok, items, receipts, :applied} = ItemTransfers.plan(Entities.new(), %{}, {0, 0}, request)
    assert {:ok, bytes} = ItemRecords.encode({0, 0}, Entities.records(items), receipts)
    assert {:ok, saved} = ItemRecords.decode(bytes, {0, 0})
    assert saved.records == [record] and saved.receipts == receipts
    {:ok, restored} = Entities.restore({0, 0}, saved.records)

    assert {:ok, ^restored, ^receipts, :already_applied} =
             ItemTransfers.plan(restored, receipts, {0, 0}, request)

    assert ItemStack.same_item?(record.stack, ItemStack.new("stone", 3))

    assert {:error, :transfer_conflict} =
             ItemTransfers.plan(restored, receipts, {0, 0}, %{
               request
               | records: [%{record | stack: ItemStack.new("stone", 3)}]
             })
  end
end
