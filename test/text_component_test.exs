defmodule Valimc.Protocol.TextComponentTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerSnapshot, PlayerTransfers}
  alias Valimc.Protocol.{ItemStack, ItemTypes, NBT, TextComponent, Wire}
  alias Valimc.World.{ItemRecords, ItemTransfers}

  defp literal(value), do: {:compound, %{"text" => {:string, value}}}

  defp named(tag, count \\ 1),
    do: %{ItemStack.new("stone", count) | components: %{"minecraft:custom_name" => tag}}

  defp bytes(stack, mode \\ :trusted), do: ItemStack.encode(stack, mode) |> IO.iodata_to_binary()

  defp styled(color),
    do:
      {:compound,
       %{"text" => {:string, "ValiMC\0🚀"}, "bold" => {:byte, 1}, "color" => {:string, color}}}

  test "literal/root sequences, styles and mixed list wrappers compare semantically" do
    a = {:compound, %{"text" => {:string, "A"}, "extra" => {:list, {:string, ["B"]}}}}
    b = {:list, {:string, ["A", "B"]}}
    assert TextComponent.identity_key(a) == TextComponent.identity_key(b)
    assert TextComponent.identity_key(literal("A")) == TextComponent.identity_key({:string, "A"})
    assert ItemStack.same_item?(named(styled("gold")), named(styled("#FFAA00"), 2))
    false_style = {:compound, %{"text" => {:string, "A"}, "italic" => {:byte, 0}}}
    refute ItemStack.same_item?(named(literal("A")), named(false_style))
    font = fn name -> {:compound, %{"text" => {:string, "A"}, "font" => {:string, name}}} end

    assert TextComponent.identity_key(font.("default")) ==
             TextComponent.identity_key(font.("minecraft:default"))

    refute ItemStack.same_item?(named(literal("A")), named(font.("default")))
    nested = {:list, {:compound, [%{"" => {:string, "A"}}, %{"text" => {:string, "B"}}]}}
    assert TextComponent.identity_key(nested) == TextComponent.identity_key(a)

    refute TextComponent.identity_key(a) ==
             TextComponent.identity_key({:list, {:string, ["B", "A"]}})
  end

  test "translations collapse plain component arguments but retain numeric types and styled arguments" do
    translation = fn with ->
      {:compound, %{"translate" => {:string, "test.key"}, "with" => with}}
    end

    a = translation.({:list, {:string, ["A"]}})
    b = translation.({:list, {:compound, [%{"text" => {:string, "A"}}]}})
    assert TextComponent.identity_key(a) == TextComponent.identity_key(b)

    refute TextComponent.identity_key(a) ==
             TextComponent.identity_key(
               translation.(
                 {:list, {:compound, [%{"text" => {:string, "A"}, "italic" => {:byte, 0}}]}}
               )
             )

    refute TextComponent.identity_key(translation.({:byte_array, <<1>>})) ==
             TextComponent.identity_key(translation.({:int_array, <<1::32>>}))

    keybind = {:compound, %{"keybind" => {:string, "key.jump"}}}
    assert TextComponent.valid?(keybind)
    refute ItemStack.same_item?(named(keybind), named({:string, "key.jump"}))
  end

  test "legacy dispatch tries complete codecs while explicit types keep their validation errors" do
    keybind = {:compound, %{"keybind" => {:string, "key.jump"}}}

    for with <- [{:int, 1}, {:list, {:compound, [%{}]}}] do
      fields = %{
        "translate" => {:string, "test.key"},
        "with" => with,
        "keybind" => {:string, "key.jump"}
      }

      assert TextComponent.identity_key({:compound, fields}) ==
               TextComponent.identity_key(keybind)

      assert {:error, _} =
               TextComponent.check(
                 {:compound, Map.put(fields, "type", {:string, "translatable"})}
               )
    end
  end

  test "names and lore round trip with Unicode and raw declarations in both stack formats" do
    tag = styled("#FFAA00")

    stack = %{
      named(tag, 7)
      | components: %{
          "minecraft:custom_name" => tag,
          "minecraft:item_name" =>
            {:compound, %{"translate" => {:string, "block.minecraft.stone"}}},
          "minecraft:lore" => [{:string, "Lore\0🚀"}, literal("Second")]
        }
    }

    for mode <- [:trusted, :untrusted] do
      assert {:ok, ^stack} = ItemStack.decode(bytes(stack, mode), mode)
      assert {:ok, ^stack, <<42>>} = ItemStack.take(bytes(stack, mode) <> <<42>>, mode)
    end

    refute bytes(named(tag)) == bytes(named(styled("gold")))
    assert ItemStack.same_item?(named(tag), named(styled("gold")))
  end

  test "item-name and empty-lore prototypes prune by semantic identity, without erasing patches" do
    ordinary = ItemStack.new("stone")

    patched = %{
      ordinary
      | components: %{
          "minecraft:item_name" =>
            {:compound,
             %{
               "type" => {:string, "translatable"},
               "translate" => {:string, "block.minecraft.stone"},
               "with" => {:list, {:end, []}}
             }},
          "minecraft:lore" => []
        }
    }

    assert ItemStack.same_item?(ordinary, patched)
    refute bytes(ordinary) == bytes(patched)
    assert {:ok, ^patched} = ItemStack.decode(bytes(patched))

    refute ItemStack.same_item?(ordinary, %{
             patched
             | components: Map.put(patched.components, "minecraft:lore", [{:string, ""}])
           })

    refute ItemStack.same_item?(ordinary, %{ordinary | removed: MapSet.new(["minecraft:lore"])})
    assert ItemTypes.defaults(ordinary.item_id).identities["minecraft:lore"] == []
  end

  test "lore line, aggregate node/byte and nesting limits bound accepted work" do
    assert TextComponent.valid_lore?(List.duplicate({:string, "line"}, 256))

    assert {:error, :lore_line_limit} =
             TextComponent.check_lore(List.duplicate({:string, "line"}, 257))

    rich =
      {:compound,
       %{
         "text" => {:string, "A"},
         "bold" => {:byte, 1},
         "color" => {:string, "gold"},
         "italic" => {:byte, 0}
       }}

    assert {:error, :text_node_limit} = TextComponent.check_lore(List.duplicate(rich, 256))

    assert {:error, :text_byte_limit} =
             TextComponent.check_lore(List.duplicate({:string, String.duplicate("a", 1000)}, 66))

    deep =
      Enum.reduce(1..33, literal("A"), fn _, child ->
        {:compound,
         %{"text" => {:string, "A"}, "extra" => {:list, {:compound, [elem(child, 1)]}}}}
      end)

    refute TextComponent.valid?(deep)

    assert catch_throw(TextComponent.take_lore(Wire.varint(257))) ==
             {:text_error, :lore_line_limit}

    assert {:error, {:text, :lore_line_limit}} =
             ItemStack.decode(
               IO.iodata_to_binary([
                 <<1>>,
                 Wire.varint(ItemTypes.id("stone")),
                 <<1, 0>>,
                 Wire.varint(ItemTypes.component_id("lore")),
                 Wire.varint(257)
               ])
             )
  end

  test "unsupported content/events never enter accepted stacks; malformed supported forms fail" do
    unsupported = [
      {:compound, %{"selector" => {:string, "@p"}}},
      {:compound,
       %{
         "text" => {:string, "A"},
         "click_event" =>
           {:compound, %{"action" => {:string, "run_command"}, "command" => {:string, "/help"}}}
       }}
    ]

    for tag <- unsupported do
      assert TextComponent.check(tag) == :unsupported

      for mode <- [:trusted, :untrusted] do
        payload = NBT.encode(tag) |> IO.iodata_to_binary()

        encoded =
          IO.iodata_to_binary([
            <<1>>,
            Wire.varint(ItemTypes.id("stone")),
            <<1, 0>>,
            Wire.varint(ItemTypes.component_id("custom_name")),
            if(mode == :untrusted, do: Wire.varint(byte_size(payload)), else: []),
            payload
          ])

        assert ItemStack.decode(encoded, mode) == {:unsupported, ["minecraft:custom_name"]}
      end

      assert catch_throw(bytes(named(tag))) == {:item_error, :invalid_component_value}
    end

    for tag <- [
          {:int, 1},
          {:compound, %{}},
          {:list, {:end, []}},
          {:compound, %{"text" => {:string, "A"}, "color" => {:string, "reset"}}},
          {:compound, %{"text" => {:string, "A"}, "extra" => {:list, {:end, []}}}},
          {:compound, %{"text" => {:string, "A"}, "bold" => {:string, "true"}}}
        ] do
      assert {:error, _} = TextComponent.check(tag)
    end
  end

  test "authoritative close merges equivalent names and lore; content/style differences stay separate" do
    stack = fn color, n ->
      %{
        named(styled(color), n)
        | components: %{
            "minecraft:custom_name" => styled(color),
            "minecraft:lore" => [literal("Lore")]
          }
      }
    end

    before = %Inventory{slots: %{36 => stack.("gold", 63)}, carried: stack.("#ffaa00", 10)}
    assert {:ok, merged, []} = Inventory.close(before)
    assert merged.slots[36] == stack.("gold", 64)
    assert merged.slots[37] == stack.("#ffaa00", 9)
    assert {:ok, separate, []} = Inventory.close(%{before | carried: stack.("red", 10)})
    assert separate.slots[36] == before.slots[36] and separate.slots[37] == stack.("red", 10)
  end

  test "named/lore transfers preserve exact declarations, journals and destination digests" do
    stack = %{
      named(styled("#ffaa00"), 7)
      | components: %{
          "minecraft:custom_name" => styled("#ffaa00"),
          "minecraft:lore" => [literal("Lore\0🚀")]
        }
    }

    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    before = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => stack}})
    after_state = PlayerSnapshot.capture(pose, %Inventory{slots: %{36 => %{stack | count: 4}}})
    record = %{uuid: <<3::128>>, x: 0.5, y: 65.32, z: 0.5, stack: %{stack | count: 3}}

    assert {:ok, pending} =
             PlayerTransfers.prepare(<<2::128>>, 0, before, after_state, {0, 0}, [record])

    assert {:ok, encoded} = PlayerSnapshot.encode(<<2::128>>, pending)
    assert {:ok, restored} = PlayerSnapshot.decode(encoded, <<2::128>>)

    assert restored.inventory.slots == after_state.inventory.slots and
             restored.outbox.records == [record]

    assert {:ok, ^encoded} = PlayerSnapshot.encode(<<2::128>>, restored)
    assert {:ok, records} = ItemRecords.encode({0, 0}, [record])
    assert {:ok, %{records: [^record], receipts: %{}}} = ItemRecords.decode(records, {0, 0})
    assert {:ok, {0, 0}, request, digest} = PlayerSnapshot.transfer_request(<<2::128>>, restored)

    altered = %{
      record
      | stack: %{
          record.stack
          | components: Map.put(record.stack.components, "minecraft:custom_name", styled("gold"))
        }
    }

    assert ItemStack.same_item?(record.stack, altered.stack)

    assert {:ok, _, other_digest} =
             ItemTransfers.encode_request({0, 0}, %{request | records: [altered]})

    refute digest == other_digest
    assert {:ok, _, ^digest} = ItemTransfers.encode_request({0, 0}, request)
  end
end
