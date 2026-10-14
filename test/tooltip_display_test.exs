defmodule Valimc.Protocol.TooltipDisplayTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.{ComponentTypes, ItemStack, ItemTypes, TooltipDisplay, Wire}
  alias Valimc.World.{ItemRecords, ItemTransfers, Items}

  defp controls(hidden \\ [], hide \\ false),
    do: %TooltipDisplay{hide: hide, hidden: MapSet.new(hidden)}

  defp raw(flag, ids),
    do:
      [<<flag>>, Wire.varint(length(ids)), Enum.map(ids, &Wire.varint/1)] |> IO.iodata_to_binary()

  defp stack(count, controls),
    do: %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:custom_name" => {:string, "Tooltip é 🚀"},
          "minecraft:lore" => [{:string, "Retained lore"}],
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 3},
          "minecraft:tooltip_display" => controls
        }
    }

  defp bytes(stack, mode \\ :trusted), do: ItemStack.encode(stack, mode) |> IO.iodata_to_binary()

  test "shared index covers all types including unsupported value codecs without runtime initialization" do
    assert ComponentTypes.count() == 122 and ItemTypes.component_count() == 122

    for {name, id} <- Enum.with_index(ComponentTypes.names()) do
      assert ItemTypes.component(id) == name and ItemTypes.component_id(name) == id

      assert {%TooltipDisplay{hide: false, hidden: hidden}, <<42>>} =
               TooltipDisplay.take(raw(0, [id]) <> <<42>>)

      assert hidden == MapSet.new([name])
    end

    refute "minecraft:attribute_modifiers" in ItemStack.supported_components()
    assert TooltipDisplay.valid?(controls(["minecraft:attribute_modifiers"]))
  end

  test "set duplicates/order and nonzero boolean bytes normalize, with hidden membership still significant" do
    a = ComponentTypes.id("enchantments")
    b = ComponentTypes.id("lore")
    {left, <<>>} = TooltipDisplay.take(raw(0, [a, b, a]))
    {right, <<>>} = TooltipDisplay.take(raw(0, [b, a]))
    assert TooltipDisplay.identity_key(left) == TooltipDisplay.identity_key(right)
    assert IO.iodata_to_binary(TooltipDisplay.encode(left)) == raw(0, Enum.sort([a, b]))

    for flag <- [1, 2, 127, 128, 255] do
      assert {value, <<>>} = TooltipDisplay.take(raw(flag, [a]))
      assert value.hide and value.hidden == MapSet.new(["minecraft:enchantments"])
    end

    refute ItemStack.same_item?(
             stack(1, controls([], true)),
             stack(1, controls(["minecraft:lore"], true))
           )
  end

  test "presentation queries leave owned names/lore/enchantments untouched in both stack formats" do
    visible = stack(7, controls())
    hidden = stack(7, controls(["minecraft:lore", "minecraft:enchantments"]))
    all = stack(7, controls(["minecraft:lore"], true))

    assert Map.delete(visible.components, "minecraft:tooltip_display") ==
             Map.delete(hidden.components, "minecraft:tooltip_display")

    assert TooltipDisplay.shows?(hidden.components["minecraft:tooltip_display"], "custom_name")
    refute TooltipDisplay.shows?(hidden.components["minecraft:tooltip_display"], "lore")
    refute TooltipDisplay.shows?(all.components["minecraft:tooltip_display"], "custom_name")

    for item <- [visible, hidden, all],
        mode <- [:trusted, :untrusted],
        do: assert(ItemStack.decode(bytes(item, mode), mode) == {:ok, item})
  end

  test "default controls merge but removal, whole-hide and explicit hidden controls remain distinct" do
    plain = ItemStack.new("stone")
    defaults = %{plain | components: %{"minecraft:tooltip_display" => controls()}}
    assert ItemStack.same_item?(plain, defaults)
    refute bytes(plain) == bytes(defaults)

    refute ItemStack.same_item?(plain, %{
             plain
             | removed: MapSet.new(["minecraft:tooltip_display"])
           })

    for value <- [controls([], true), controls(["minecraft:lore"])],
        do:
          refute(
            ItemStack.same_item?(plain, %{
              plain
              | components: %{"minecraft:tooltip_display" => value}
            })
          )
  end

  test "unknown IDs, truncation and raw-entry budgets reject before partial publication" do
    for invalid <- [-1, 122, 999],
        do:
          assert(
            catch_throw(TooltipDisplay.take(raw(0, [1, invalid]))) ==
              {:tooltip_error, :unknown_hidden_component}
          )

    assert {_, <<>>} = TooltipDisplay.take(raw(0, List.duplicate(1, 1024)))

    assert catch_throw(TooltipDisplay.take(raw(0, List.duplicate(1, 1025)))) ==
             {:tooltip_error, :tooltip_count_limit}

    assert catch_throw(TooltipDisplay.take(<<>>)) == {:tooltip_error, :malformed_tooltip_display}

    for payload <- [<<>>, <<0>>, <<0, 1>>] do
      encoded =
        IO.iodata_to_binary([
          <<1>>,
          Wire.varint(ItemTypes.id("stone")),
          <<1, 0>>,
          Wire.varint(ItemTypes.component_id("tooltip_display")),
          Wire.varint(byte_size(payload)),
          payload
        ])

      assert {:error, _} = ItemStack.decode(encoded, :untrusted)
    end

    for invalid <- [
          %TooltipDisplay{hide: 1},
          controls(["unknown"]),
          controls(["lore"]),
          %{hide: false, hidden: MapSet.new()}
        ],
        do: refute(TooltipDisplay.valid?(invalid))
  end

  test "authoritative close conserves equal sets and keeps different presentation identity separate" do
    before = %Inventory{
      slots: %{36 => stack(63, controls(["minecraft:lore", "minecraft:enchantments"]))},
      carried: stack(10, controls(["minecraft:enchantments", "minecraft:lore"]))
    }

    assert {:ok, after_state, []} = Inventory.close(before)
    assert after_state.slots[36].count == 64 and after_state.slots[37].count == 9

    assert {:ok, separate, []} =
             Inventory.close(%{before | carried: stack(10, controls([], true))})

    assert separate.slots[36].count == 63 and separate.slots[37].count == 10
  end

  test "hidden data/controls survive snapshot/outbox/item files and exact receipt fencing" do
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    value = controls(["minecraft:enchantments", "minecraft:lore"], true)
    before = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => stack(7, value)}})
    after_state = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => stack(4, value)}})
    record = %{uuid: <<3::128>>, x: 0.5, y: 65.32, z: 0.5, stack: stack(3, value)}

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
               | records: [%{record | stack: stack(3, controls())}]
             })
  end
end
