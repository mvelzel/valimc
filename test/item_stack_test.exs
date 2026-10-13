defmodule Valimc.Protocol.ItemStackTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}

  defp bytes(stack, mode \\ :trusted), do: IO.iodata_to_binary(ItemStack.encode(stack, mode))
  defp patch(name, value), do: %{("minecraft:" <> name) => value}

  defp prefix(added, removed \\ 0),
    do: [<<1>>, Wire.varint(ItemTypes.id("stone")), Wire.varint(added), Wire.varint(removed)]

  test "empty, ordinary block and non-block stacks round trip without runtime lookups" do
    assert ItemStack.decode(<<0>>) == {:ok, nil}
    assert ItemStack.decode(<<0, 1>>) == {:error, :trailing_item_bytes}

    for stack <- [
          ItemStack.new("stone", 64),
          ItemStack.new("diamond_sword"),
          ItemStack.new("egg", 16)
        ],
        mode <- [:trusted, :untrusted] do
      assert {:ok, ^stack} = ItemStack.decode(bytes(stack, mode), mode)
    end

    assert ItemStack.max_stack_size(ItemStack.new("diamond_sword")) == 1
    assert ItemStack.max_stack_size(ItemStack.new("egg")) == 16
  end

  test "scalar fields, zero-byte units and removals use distinct ordinary/delimited formats" do
    stack = %{
      ItemStack.new("stone", 32)
      | components:
          Map.merge(patch("max_stack_size", 32), %{
            "minecraft:enchantment_glint_override" => true,
            "minecraft:unbreakable" => :unit,
            "minecraft:intangible_projectile" => :unit,
            "minecraft:item_model" => "valimc:test/item",
            "minecraft:rarity" => 2,
            "minecraft:minimum_attack_charge" => 0.25
          }),
        removed: MapSet.new(["minecraft:custom_name", "minecraft:repair_cost"])
    }

    assert bytes(stack, :trusted) != bytes(stack, :untrusted)

    for mode <- [:trusted, :untrusted],
        do: assert(ItemStack.decode(bytes(stack, mode), mode) == {:ok, stack})

    assert {:ok, ^stack, <<99>>} = ItemStack.take(bytes(stack) <> <<99>>)
  end

  test "known unsupported values are bounded and reported rather than silently discarded" do
    encoded =
      IO.iodata_to_binary([
        prefix(1),
        Wire.varint(ItemTypes.component_id("custom_name")),
        <<2, 10, 0>>
      ])

    assert ItemStack.decode(encoded, :untrusted) == {:unsupported, ["minecraft:custom_name"]}
    assert ItemStack.decode(encoded <> <<0>>, :untrusted) == {:error, :trailing_item_bytes}
    assert {:error, :unsupported_component} = ItemStack.decode(encoded, :trusted)
    huge = IO.iodata_to_binary([prefix(1), <<0>>, Wire.varint(65_537)])
    assert ItemStack.decode(huge, :untrusted) == {:error, :item_byte_limit}
  end

  test "truncation, malformed lengths, unknown IDs and duplicate/overlapping patches fail" do
    id = Wire.varint(ItemTypes.component_id("damage"))

    for mode <- [:trusted, :untrusted] do
      value = if mode == :untrusted, do: <<1, 0>>, else: <<0>>
      duplicate = IO.iodata_to_binary([prefix(2), id, value, id, value])
      assert ItemStack.decode(duplicate, mode) == {:error, :duplicate_component}
      overlap = IO.iodata_to_binary([prefix(1, 1), id, value, id])
      assert ItemStack.decode(overlap, mode) == {:error, :overlapping_components}
    end

    assert {:error, :unknown_component} =
             ItemStack.decode(
               IO.iodata_to_binary([prefix(1), Wire.varint(999), <<0>>]),
               :untrusted
             )

    assert {:error, :component_count_limit} =
             ItemStack.decode(IO.iodata_to_binary(prefix(123)), :untrusted)

    assert {:error, :truncated_component} =
             ItemStack.decode(IO.iodata_to_binary([prefix(1), id, <<3, 0>>]), :untrusted)

    assert {:error, :malformed_item} =
             ItemStack.decode(IO.iodata_to_binary([prefix(1), id, <<2, 0, 0>>]), :untrusted)

    for count <- [100, 2_147_483_647, 4_294_967_295],
        do: assert(ItemStack.decode(Wire.varint(count)) == {:error, :invalid_item_count})

    assert ItemStack.decode(<<1, 255, 255, 127>>) == {:error, :unknown_item}

    valid =
      bytes(
        %{ItemStack.new("stone") | components: patch("enchantment_glint_override", true)},
        :untrusted
      )

    for size <- 0..(byte_size(valid) - 1),
        do: assert(match?({:error, _}, ItemStack.decode(binary_part(valid, 0, size), :untrusted)))
  end

  test "custom-data NBT is preserved in both formats and requires a compound root" do
    tag = {:compound, %{"unicode" => {:string, "Hello 😀" <> <<0>>}, "value" => {:int, 42}}}
    stack = %{ItemStack.new("stone", 7) | components: %{"minecraft:custom_data" => tag}}

    for mode <- [:trusted, :untrusted],
        do: assert(ItemStack.decode(bytes(stack, mode), mode) == {:ok, stack})

    scalar =
      IO.iodata_to_binary([
        prefix(1),
        Wire.varint(ItemTypes.component_id("custom_data")),
        <<1, 0>>
      ])

    assert ItemStack.decode(scalar, :untrusted) == {:error, :invalid_component_value}

    bad =
      IO.iodata_to_binary([
        prefix(1),
        Wire.varint(ItemTypes.component_id("custom_data")),
        <<2, 10, 13>>
      ])

    assert ItemStack.decode(bad, :untrusted) == {:error, {:nbt, :unknown_nbt_tag}}
  end

  test "identifier input uses vanilla's default namespace" do
    for name <- ["stone", ":stone"] do
      payload = IO.iodata_to_binary(Wire.string(name))

      encoded =
        IO.iodata_to_binary([
          prefix(1),
          Wire.varint(ItemTypes.component_id("item_model")),
          Wire.varint(byte_size(payload)),
          payload
        ])

      assert {:ok, stack} = ItemStack.decode(encoded, :untrusted)
      assert stack.components["minecraft:item_model"] == "minecraft:stone"
    end
  end

  test "effective stack-size/damage defaults include component removals and patches" do
    sword = ItemStack.new("diamond_sword", 2)
    assert catch_throw(ItemStack.encode(sword)) == {:item_error, :stack_size_exceeded}
    stack = %{ItemStack.new("stone", 2) | components: patch("max_damage", 50)}
    assert catch_throw(ItemStack.encode(stack)) == {:item_error, :damageable_stack}
    stack = %{ItemStack.new("stone") | removed: MapSet.new(["minecraft:max_stack_size"])}
    assert ItemStack.max_stack_size(stack) == 1
    assert ItemStack.decode(bytes(stack)) == {:ok, stack}

    sword = %{
      sword
      | components: patch("max_stack_size", 2),
        removed: MapSet.new(["minecraft:max_damage"])
    }

    assert ItemStack.decode(bytes(sword)) == {:ok, sword}

    for {name, value} <- [
          {"max_stack_size", 0},
          {"rarity", 4},
          {"minimum_attack_charge", 1.1},
          {"item_model", "Bad:Space"}
        ] do
      stack = %{ItemStack.new("stone") | components: patch(name, value)}
      assert catch_throw(ItemStack.encode(stack)) == {:item_error, :invalid_component_value}
    end
  end
end
