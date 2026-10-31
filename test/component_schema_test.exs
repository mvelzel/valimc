defmodule Valimc.ComponentSchemaTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ComponentSchema, ComponentSchemas, ItemData, ItemStack, ItemTypes, Wire}

  defp take(name, bytes), do: ComponentSchema.take(ComponentSchemas.schema(name), bytes)

  defp error(name, bytes) do
    take(name, bytes)
    flunk("decoded #{inspect(bytes)}")
  catch
    {:component_error, reason} -> reason
  end

  test "malformed and out-of-bound network values are refused" do
    # A list count beyond the input, before any element is read.
    assert error("minecraft:banner_patterns", Wire.varint(1_000_000)) == :list_too_long
    assert error("minecraft:dye", <<16>>) == :unknown_enum
    assert error("minecraft:villager/variant", <<99>>) == :unknown_registry_id
    # An inline holder (id 0) carries a value no vanilla item has.
    assert error("minecraft:break_sound", <<0>>) == :direct_holder
    tag = IO.iodata_to_binary([<<0>>, Wire.string("minecraft:no_such_tag")])
    assert error("minecraft:repairable", tag) == :unknown_tag
    assert error("minecraft:enchantable", <<0>>) == :out_of_range
    assert error("minecraft:potion_duration_scale", <<0xBF800000::32>>) == :out_of_range
    assert error("minecraft:fireworks", <<200, 2>>) == :out_of_range
    # A truncated colour.
    assert error("minecraft:custom_model_data", <<0, 0, 0, 1, 1, 2>>) == :malformed
  end

  test "block predicates refuse NBT tests and partial component predicates" do
    # One predicate: no blocks, no state, an NBT test.
    assert error("minecraft:can_break", <<1, 0, 0, 1, 10, 0>>) == :unsupported_predicate
    # No NBT test, no exact components, one partial predicate.
    assert error("minecraft:can_break", <<1, 0, 0, 0, 0, 1>>) == :unsupported_predicate
    assert {[%{"components" => []}], <<>>} = take("minecraft:can_break", <<1, 0, 0, 0, 0, 0>>)
  end

  test "a status effect's icon follows its particles unless written" do
    schema = ComponentSchemas.schema("minecraft:death_protection")

    effect = fn fields ->
      {:compound,
       %{
         "death_effects" =>
           {:list,
            {:compound,
             [
               %{
                 "type" => {:string, "apply_effects"},
                 "effects" => {:list, {:compound, [Map.put(fields, "id", {:string, "speed"})]}}
               }
             ]}}
       }}
    end

    icon = fn tag ->
      %{"death_effects" => [%{"effects" => [details]}]} = ComponentSchema.from_tag(schema, tag)
      details["show_icon"]
    end

    refute icon.(effect.(%{"show_particles" => {:byte, 0}}))
    assert icon.(effect.(%{"show_particles" => {:byte, 0}, "show_icon" => {:byte, 1}}))
    assert icon.(effect.(%{}))
  end

  test "held stacks nest at most 16 deep and must fit their own items" do
    box = ItemTypes.id("shulker_box")
    container = ItemTypes.component_id("container")

    nest = fn depth ->
      Enum.reduce(1..depth, <<0>>, fn _, inner ->
        # One slot holding a shulker box whose patch adds a container.
        IO.iodata_to_binary([1, 1, Wire.varint(box), 1, 1, 0, Wire.varint(container), inner])
      end)
    end

    assert {_, <<>>} = take("minecraft:container", nest.(16))
    assert error("minecraft:container", nest.(17)) == :nesting_too_deep
    swords = IO.iodata_to_binary([Wire.varint(ItemTypes.id("diamond_sword")), 2, 0, 0])
    assert error("minecraft:container", <<1, 1>> <> swords) == :stack_size_exceeded
    # A use remainder is a template too, but nothing limits its count.
    assert {%ItemStack{count: 2}, <<>>} = take("minecraft:use_remainder", swords)
  end

  test "NaN floats keep their bits and compare as Java's Float.equals" do
    schema = ComponentSchemas.schema("minecraft:custom_model_data")
    bytes = <<1, 0x7FC00001::32, 0, 0, 0>>
    {value, <<>>} = ComponentSchema.take(schema, bytes)
    assert value["floats"] == [{:float_bits, 0x7FC00001}]
    assert IO.iodata_to_binary(ComponentSchema.encode(schema, value)) == bytes
    other = %{value | "floats" => [{:float_bits, 0x7FC00000}]}

    assert ComponentSchema.identity_key(schema, value) ==
             ComponentSchema.identity_key(schema, other)
  end

  test "a stack holding schema components round-trips both formats and merges with defaults" do
    stick = ItemTypes.id("stick")
    break_sound = ItemStack.component(ItemStack.new("stick"), "minecraft:break_sound")

    stack = %ItemStack{
      item_id: stick,
      count: 3,
      components: %{
        "minecraft:dyed_color" => 0x123456,
        "minecraft:enchantable" => %{"value" => 10},
        "minecraft:trim" => %{
          "material" => "minecraft:gold",
          "pattern" => "minecraft:spire"
        },
        "minecraft:break_sound" => break_sound
      },
      removed: MapSet.new(["minecraft:attack_animation"])
    }

    for mode <- [:trusted, :untrusted] do
      bytes = stack |> ItemStack.encode(mode) |> IO.iodata_to_binary()
      assert ItemStack.decode(bytes, mode) == {:ok, stack}
    end

    assert stack |> ItemData.tag() |> ItemData.stack() == {:ok, ItemStack.normalize(stack)}
    # The default break sound is redundant; the rest of the patch is not.
    assert ItemStack.normalize(stack).components |> Map.keys() |> Enum.sort() ==
             ~w(minecraft:dyed_color minecraft:enchantable minecraft:trim)

    plain = %{stack | components: Map.delete(stack.components, "minecraft:break_sound")}
    assert ItemStack.same_item?(stack, plain)
    refute ItemStack.same_item?(stack, %{plain | removed: MapSet.new()})
  end

  test "a command reads schema components from SNBT" do
    assert ItemData.decode_component("minecraft:base_color", {:string, "lime"}) == {:ok, "lime"}

    assert ItemData.decode_component(
             "minecraft:enchantable",
             {:compound, %{"value" => {:int, 0}}}
           ) == {:error, "Invalid minecraft:enchantable value"}
  end
end
