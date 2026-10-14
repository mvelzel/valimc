defmodule Valimc.StackIdentityTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.{ItemStack, ItemTypes, NBT}
  alias Valimc.World.{ItemRecords, Items, ItemTransfers}

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

  defp encoded(stack), do: ItemStack.encode(stack) |> IO.iodata_to_binary()
  defp data(tag), do: %{ItemStack.new("stone") | components: %{"minecraft:custom_data" => tag}}

  test "default additions and absent removals do not affect identity, count or raw codec preservation" do
    a = ItemStack.new("stone", 7)
    b = redundant(10)
    assert ItemStack.same_item?(a, b)
    assert ItemStack.identity_key(a) == ItemStack.identity_key(b)
    assert encoded(a) != encoded(b)
    assert {:ok, ^b} = ItemStack.decode(encoded(b))
    assert ItemStack.same_item?(nil, nil)
    refute ItemStack.same_item?(nil, a)
    refute ItemStack.same_item?(a, ItemStack.new("dirt", 7))
  end

  test "presence differs from fallback values and altered supported components remain distinct" do
    stone = ItemStack.new("stone")

    for name <- ["minecraft:rarity", "minecraft:repair_cost", "minecraft:item_name"] do
      absent = %{stone | removed: MapSet.new([name])}
      refute ItemStack.same_item?(stone, absent)
    end

    for {name, value} <- [
          {"minecraft:max_stack_size", 32},
          {"minecraft:enchantment_glint_override", false},
          {"minecraft:rarity", 1},
          {"minecraft:repair_cost", 1},
          {"minecraft:item_model", "valimc:stone"},
          {"minecraft:unbreakable", :unit},
          {"minecraft:custom_data", {:compound, %{}}}
        ] do
      refute ItemStack.same_item?(stone, %{stone | components: %{name => value}})
    end

    sword = ItemStack.new("iron_sword")
    assert ItemStack.same_item?(sword, %{sword | components: %{"minecraft:damage" => 0}})
    refute ItemStack.same_item?(sword, %{sword | components: %{"minecraft:damage" => 1}})
  end

  test "all extracted item prototypes and supported default codecs are indexed consistently" do
    facts = :json.decode(File.read!(Path.expand("../priv/protocol/item_defaults.json", __DIR__)))

    assert facts["version"] == "26.3" and facts["protocol"] == 777 and
             facts["data_version"] == 5023

    assert map_size(facts["items"]) == 1658

    for {id, raw} <- facts["items"] do
      id = String.to_integer(id)
      assert ItemTypes.item(id) != nil
      defaults = ItemTypes.defaults(id)
      assert MapSet.new(Map.keys(defaults.values)) |> MapSet.subset?(defaults.present)

      for {name, bytes} <- defaults.values do
        assert name in ItemStack.supported_components()
        assert is_binary(bytes)
      end

      for name <- raw["present"], do: assert(ItemTypes.component_id(name) != nil)
    end
  end

  test "NBT NaNs, cached signed zero and empty lists compare like Mojang without changing raw bytes" do
    a =
      {:compound,
       %{
         "float" => {:float, <<0x7F800001::32>>},
         "double" => {:double, <<0xFFF8000000000001::64>>},
         "nested" => {:list, {:compound, [%{"zero" => {:float, <<0x80000000::32>>}}]}},
         "empty" => {:list, {:float, []}}
       }}

    b =
      {:compound,
       %{
         "float" => {:float, <<0xFFC00001::32>>},
         "double" => {:double, <<0x7FF0000000000001::64>>},
         "nested" => {:list, {:compound, [%{"zero" => {:float, <<0::32>>}}]}},
         "empty" => {:list, {:double, []}}
       }}

    assert ItemStack.same_item?(data(a), data(b))
    assert NBT.identity_key(a) == NBT.identity_key(b)
    assert encoded(data(a)) != encoded(data(b))
    assert {:ok, restored} = ItemStack.decode(encoded(data(a)))
    assert restored.components["minecraft:custom_data"] == a

    refute ItemStack.same_item?(
             data({:compound, %{"n" => {:byte, 0}}}),
             data({:compound, %{"n" => {:int, 0}}})
           )

    refute ItemStack.same_item?(
             data({:compound, %{"list" => {:list, {:int, [1, 2]}}}}),
             data({:compound, %{"list" => {:list, {:int, [2, 1]}}}})
           )
  end

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

  test "pickup, shift, drag and collect merge redundant patches but preserve different effective identity" do
    inv = %Inventory{slots: %{9 => ItemStack.new("stone", 63)}, carried: redundant(10)}
    {:ok, next} = Inventory.click(inv, :pickup, 9, 0)
    assert next.slots[9].count == 64 and next.carried.count == 9
    assert ItemStack.same_item?(next.slots[9], next.carried)
    inv = %Inventory{slots: %{9 => redundant(10), 36 => ItemStack.new("stone", 63)}}
    {:ok, next} = Inventory.click(inv, :quick_move, 9, 0)
    assert next.slots[9] == nil and next.slots[36].count == 64 and next.slots[37].count == 9

    inv = %Inventory{
      slots: %{9 => ItemStack.new("stone", 60), 10 => ItemStack.new("stone", 60)},
      carried: redundant(4)
    }

    {:ok, inv} = Inventory.click(inv, :quick_craft, -999, 0)
    {:ok, inv} = Inventory.click(inv, :quick_craft, 9, 1)
    {:ok, inv} = Inventory.click(inv, :quick_craft, 10, 1)
    {:ok, next} = Inventory.click(inv, :quick_craft, -999, 2)
    assert next.slots[9].count == 62 and next.slots[10].count == 62 and next.carried == nil

    changed = %{
      ItemStack.new("stone", 2)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    inv = %Inventory{
      slots: %{9 => ItemStack.new("stone", 7), 11 => changed},
      carried: redundant(1)
    }

    {:ok, next} = Inventory.click(inv, :pickup_all, 10, 0)
    assert next.carried.count == 8 and next.slots[9] == nil and next.slots[11] == changed
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
               PlayerSnapshot.capture(pose, inv),
               PlayerSnapshot.capture(pose, next),
               {0, 0},
               [record]
             )

    assert prepared.transfer_sequence == 9 and prepared.outbox.records == [record]
    assert {:ok, bytes} = PlayerSnapshot.encode(<<1::128>>, prepared)
    assert {:ok, restored} = PlayerSnapshot.decode(bytes, <<1::128>>)
    assert restored.outbox == prepared.outbox

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(
               <<1::128>>,
               8,
               PlayerSnapshot.capture(pose, inv),
               PlayerSnapshot.capture(pose, next),
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
    {:ok, items, receipts, :applied} = ItemTransfers.plan(Items.new(), %{}, {0, 0}, request)
    assert {:ok, bytes} = ItemRecords.encode({0, 0}, Items.records(items), receipts)
    assert {:ok, saved} = ItemRecords.decode(bytes, {0, 0})
    assert saved.records == [record] and saved.receipts == receipts
    {:ok, restored} = Items.restore({0, 0}, saved.records)

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
