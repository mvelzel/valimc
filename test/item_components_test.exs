defmodule Valimc.Protocol.ItemComponentsTest do
  # Untrusted text, tooltip and enchantment components: bounds and rejection.
  # Their semantics (identity, round trips) are the `text`, `tooltip`,
  # `enchantment` and `stack_identity` oracle stages.
  use ExUnit.Case, async: true
  alias Valimc.Text.Codec
  alias Valimc.Protocol.{Enchantments, ItemStack, ItemTypes, TooltipDisplay, Wire}
  alias Valimc.Data.NBT

  defp literal(value), do: {:compound, %{"text" => {:string, value}}}

  defp named(tag, count \\ 1),
    do: %{ItemStack.new("stone", count) | components: %{"minecraft:custom_name" => tag}}

  defp bytes(stack, mode \\ :trusted), do: ItemStack.encode(stack, mode) |> IO.iodata_to_binary()

  defp styled(color),
    do:
      {:compound,
       %{"text" => {:string, "ValiMC\0🚀"}, "bold" => {:byte, 1}, "color" => {:string, color}}}

  defp controls(hidden), do: %TooltipDisplay{hide: false, hidden: MapSet.new(hidden)}

  defp hidden(flag, ids),
    do:
      [<<flag>>, Wire.varint(length(ids)), Enum.map(ids, &Wire.varint/1)] |> IO.iodata_to_binary()

  defp levels(entries),
    do:
      [
        Wire.varint(length(entries)),
        Enum.map(entries, fn {id, level} -> [Wire.varint(id), Wire.varint(level)] end)
      ]
      |> IO.iodata_to_binary()

  test "literal/root sequences, styles and mixed list wrappers compare semantically" do
    a = {:compound, %{"text" => {:string, "A"}, "extra" => {:list, {:string, ["B"]}}}}
    b = {:list, {:string, ["A", "B"]}}
    assert Codec.identity_key(a) == Codec.identity_key(b)
    assert Codec.identity_key(literal("A")) == Codec.identity_key({:string, "A"})
    assert ItemStack.same_item?(named(styled("gold")), named(styled("#FFAA00"), 2))
    false_style = {:compound, %{"text" => {:string, "A"}, "italic" => {:byte, 0}}}
    refute ItemStack.same_item?(named(literal("A")), named(false_style))
    font = fn name -> {:compound, %{"text" => {:string, "A"}, "font" => {:string, name}}} end

    assert Codec.identity_key(font.("default")) ==
             Codec.identity_key(font.("minecraft:default"))

    refute ItemStack.same_item?(named(literal("A")), named(font.("default")))
    nested = {:list, {:compound, [%{"" => {:string, "A"}}, %{"text" => {:string, "B"}}]}}
    assert Codec.identity_key(nested) == Codec.identity_key(a)

    refute Codec.identity_key(a) ==
             Codec.identity_key({:list, {:string, ["B", "A"]}})
  end

  test "lore line, aggregate node/byte and nesting limits bound accepted work" do
    assert Codec.valid_lore?(List.duplicate({:string, "line"}, 256))

    assert {:error, :lore_line_limit} =
             Codec.check_lore(List.duplicate({:string, "line"}, 257))

    rich =
      {:compound,
       %{
         "text" => {:string, "A"},
         "bold" => {:byte, 1},
         "color" => {:string, "gold"},
         "italic" => {:byte, 0}
       }}

    assert {:error, :text_node_limit} = Codec.check_lore(List.duplicate(rich, 256))

    assert {:error, :text_byte_limit} =
             Codec.check_lore(List.duplicate({:string, String.duplicate("a", 1000)}, 66))

    deep =
      Enum.reduce(1..33, literal("A"), fn _, child ->
        {:compound,
         %{"text" => {:string, "A"}, "extra" => {:list, {:compound, [elem(child, 1)]}}}}
      end)

    refute Codec.valid?(deep)

    assert catch_throw(Codec.take_lore(Wire.varint(257))) ==
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
      assert Codec.check(tag) == :unsupported

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
      assert {:error, _} = Codec.check(tag)
    end
  end

  test "tooltip display: unknown IDs, truncation and raw-entry budgets reject" do
    for invalid <- [-1, 122, 999],
        do:
          assert(
            catch_throw(TooltipDisplay.take(hidden(0, [1, invalid]))) ==
              {:tooltip_error, :unknown_hidden_component}
          )

    assert {_, <<>>} = TooltipDisplay.take(hidden(0, List.duplicate(1, 1024)))

    assert catch_throw(TooltipDisplay.take(hidden(0, List.duplicate(1, 1025)))) ==
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

  test "enchantments: unknown holders, invalid final levels, truncation and entry budgets reject" do
    id = Enchantments.id("minecraft:unbreaking")

    for entries <- [[{id, -1}], [{id, 256}], [{id, 3}, {id, -1}]] do
      assert catch_throw(Enchantments.take(levels(entries))) ==
               {:enchantment_error, :invalid_enchantment_level}
    end

    for invalid <- [-1, 43, 999],
        do:
          assert(
            catch_throw(Enchantments.take(levels([{id, 3}, {invalid, 1}]))) ==
              {:enchantment_error, :unknown_enchantment}
          )

    assert {%{"minecraft:unbreaking" => 3}, <<>>} =
             Enchantments.take(levels(List.duplicate({id, 3}, 1024)))

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
end
