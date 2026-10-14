defmodule Valimc.Protocol.EnchantmentsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.{Enchantments, ItemStack, ItemTypes, Wire}
  alias Valimc.World.{ItemRecords, ItemTransfers, Items}

  defp raw(entries),
    do:
      [
        Wire.varint(length(entries)),
        Enum.map(entries, fn {id, level} -> [Wire.varint(id), Wire.varint(level)] end)
      ]
      |> IO.iodata_to_binary()

  defp ench(level), do: %{"minecraft:unbreaking" => level, "minecraft:fortune" => 2}

  defp stack(count, level \\ 3),
    do: %{ItemStack.new("stone", count) | components: %{"minecraft:enchantments" => ench(level)}}

  defp bytes(stack, mode \\ :trusted), do: ItemStack.encode(stack, mode) |> IO.iodata_to_binary()

  test "all negotiated IDs and level boundaries round trip, consuming only their own component" do
    assert length(Enchantments.names()) == 43

    for {name, id} <- Enum.with_index(Enchantments.names()) do
      assert Enchantments.id(name) == id and Enchantments.name(id) == name

      for level <- [0, 1, 3, 255] do
        values = %{name => level}
        assert {^values, <<42>>} = Enchantments.take(raw([{id, level}]) <> <<42>>)

        assert {^values, <<>>} =
                 Enchantments.take(IO.iodata_to_binary(Enchantments.encode(values)))
      end
    end

    assert {%{}, <<42>>} = Enchantments.take(<<0, 42>>)
  end

  test "duplicate last values win, including overwritten invalid levels and retained zero" do
    id = Enchantments.id("minecraft:unbreaking")

    for overwritten <- [-1, 0, 1, 255, 256] do
      assert {%{"minecraft:unbreaking" => 3}, <<>>} =
               Enchantments.take(raw([{id, overwritten}, {id, 3}]))
    end

    assert {%{"minecraft:unbreaking" => 0}, <<>>} = Enchantments.take(raw([{id, 3}, {id, 0}]))

    refute ItemStack.same_item?(ItemStack.new("stone"), %{
             ItemStack.new("stone")
             | components: %{"minecraft:enchantments" => %{"minecraft:unbreaking" => 0}}
           })
  end

  test "unknown holders, invalid final levels, truncation and raw-entry budgets reject atomically" do
    id = Enchantments.id("minecraft:unbreaking")

    for entries <- [[{id, -1}], [{id, 256}], [{id, 3}, {id, -1}]] do
      assert catch_throw(Enchantments.take(raw(entries))) ==
               {:enchantment_error, :invalid_enchantment_level}
    end

    for invalid <- [-1, 43, 999],
        do:
          assert(
            catch_throw(Enchantments.take(raw([{id, 3}, {invalid, 1}]))) ==
              {:enchantment_error, :unknown_enchantment}
          )

    assert {%{"minecraft:unbreaking" => 3}, <<>>} =
             Enchantments.take(raw(List.duplicate({id, 3}, 1024)))

    for count <- [-1, 1025],
        do:
          assert(
            catch_throw(Enchantments.take(Wire.varint(count))) ==
              {:enchantment_error, :enchantment_count_limit}
          )

    assert_raise ArgumentError, fn -> Enchantments.take(<<1, id>>) end

    for value <- [
          %{"minecraft:unbreaking" => -1},
          %{"minecraft:unbreaking" => 256},
          %{"minecraft:unbreaking" => 1.0},
          %{"unbreaking" => 3},
          %{"valimc:unknown" => 1},
          [],
          nil
        ] do
      refute Enchantments.valid?(value)

      assert catch_throw(
               bytes(%{ItemStack.new("stone") | components: %{"minecraft:enchantments" => value}})
             ) == {:item_error, :invalid_component_value}
    end
  end

  test "empty prototype maps prune semantically; absent, removed and stored maps remain distinct" do
    ordinary = ItemStack.new("stone")
    empty = %{ordinary | components: %{"minecraft:enchantments" => %{}}}
    assert ItemStack.same_item?(ordinary, empty)
    refute bytes(ordinary) == bytes(empty)

    refute ItemStack.same_item?(ordinary, %{
             ordinary
             | removed: MapSet.new(["minecraft:enchantments"])
           })

    refute ItemStack.same_item?(ordinary, %{
             ordinary
             | components: %{"minecraft:stored_enchantments" => %{}}
           })

    book = ItemStack.new("enchanted_book")

    assert ItemStack.same_item?(book, %{
             book
             | components: %{"minecraft:stored_enchantments" => %{}}
           })

    active = stack(1)

    refute ItemStack.same_item?(active, %{
             active
             | components: %{"minecraft:stored_enchantments" => ench(3)}
           })

    refute ItemStack.same_item?(active, stack(1, 2))
  end

  test "map order normalizes independently of names/lore and both stack formats retain values" do
    a = [{Enchantments.id("minecraft:fortune"), 2}, {Enchantments.id("minecraft:unbreaking"), 3}]
    {left, <<>>} = Enchantments.take(raw(a))
    {right, <<>>} = Enchantments.take(raw(Enum.reverse(a)))
    assert left == right
    assert IO.iodata_to_binary(Enchantments.encode(left)) == raw(a)

    item = %{
      stack(7)
      | components:
          Map.merge(stack(7).components, %{
            "minecraft:stored_enchantments" => %{"minecraft:sharpness" => 5},
            "minecraft:custom_name" => {:string, "Enchanted é 🚀"},
            "minecraft:lore" => [{:string, "Lore"}]
          })
    }

    for mode <- [:trusted, :untrusted] do
      assert {:ok, ^item} = ItemStack.decode(bytes(item, mode), mode)
      assert {:ok, ^item, <<42>>} = ItemStack.take(bytes(item, mode) <> <<42>>, mode)
    end

    assert ItemTypes.defaults(item.item_id).values["minecraft:enchantments"] == <<0>>
  end

  test "authoritative close merges equal maps/defaults and conserves differing enchantment identity" do
    before = %Inventory{slots: %{36 => stack(63)}, carried: stack(10)}
    assert {:ok, after_state, []} = Inventory.close(before)
    assert after_state.slots[36] == stack(64) and after_state.slots[37] == stack(9)
    assert {:ok, separate, []} = Inventory.close(%{before | carried: stack(10, 2)})
    assert separate.slots[36] == stack(63) and separate.slots[37] == stack(10, 2)

    assert {:ok, merged, []} =
             Inventory.close(%Inventory{
               slots: %{36 => ItemStack.new("stone", 63)},
               carried: %{
                 ItemStack.new("stone", 10)
                 | components: %{"minecraft:enchantments" => %{}}
               }
             })

    assert merged.slots[36].count == 64 and merged.slots[37].count == 9
  end

  test "enchanted outboxes/items/snapshots preserve exact records and conflicting retries remain fenced" do
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    before = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => stack(7)}})
    after_state = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => stack(4)}})
    record = %{uuid: <<3::128>>, x: 0.5, y: 65.32, z: 0.5, stack: stack(3)}

    assert {:ok, pending} =
             PlayerTransfers.prepare(<<2::128>>, 0, before, after_state, {0, 0}, [record])

    assert {:ok, saved} = PlayerSnapshot.encode(<<2::128>>, pending)
    assert {:ok, recovered} = PlayerSnapshot.decode(saved, <<2::128>>)

    assert recovered.inventory.slots == after_state.inventory.slots and
             recovered.outbox.records == [record]

    assert {:ok, ^saved} = PlayerSnapshot.encode(<<2::128>>, recovered)
    assert {:ok, {0, 0}, request, digest} = PlayerSnapshot.transfer_request(<<2::128>>, recovered)

    assert {:ok, items, receipts, :applied} =
             ItemTransfers.plan(Items.new(), %{}, {0, 0}, request)

    assert receipts[<<2::128>>].digest == digest
    assert {:ok, file} = ItemRecords.encode({0, 0}, Items.records(items), receipts)
    assert {:ok, %{records: [^record], receipts: ^receipts}} = ItemRecords.decode(file, {0, 0})

    assert {:ok, ^items, ^receipts, :already_applied} =
             ItemTransfers.plan(items, receipts, {0, 0}, request)

    assert {:error, :transfer_conflict} =
             ItemTransfers.plan(items, receipts, {0, 0}, %{
               request
               | records: [%{record | stack: stack(3, 2)}]
             })

    assert {:error, :item_conservation_failed} =
             PlayerTransfers.prepare(<<2::128>>, 0, before, after_state, {0, 0}, [
               %{record | stack: stack(3, 2)}
             ])
  end
end
