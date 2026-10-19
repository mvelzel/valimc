defmodule Valimc.Physics.CookingItemsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.CookingItems
  alias Valimc.Protocol.{Data, ItemStack}

  test "complete output must fit its effective identity and capacity without partial input consumption" do
    input = ItemStack.new("raw_iron", 3)
    coal = ItemStack.new("coal", 2)
    ingot = ItemStack.new("iron_ingot")
    output = ItemStack.new("iron_ingot", 63)

    assert CookingItems.finish({input, coal, output}, ingot) ==
             {:ok, {ItemStack.new("raw_iron", 2), coal, ItemStack.new("iron_ingot", 64)}}

    assert CookingItems.finish({input, coal, %{output | count: 64}}, ingot) ==
             {:error, :output_full}

    assert CookingItems.finish({input, coal, output}, %{ingot | count: 2}) ==
             {:error, :output_full}

    named = %{output | components: %{"minecraft:custom_name" => {:string, "Cooked"}}}
    assert CookingItems.finish({input, coal, named}, ingot) == {:error, :output_full}
    explicit = %{ingot | components: %{"minecraft:max_stack_size" => 64}}

    assert CookingItems.finish({input, coal, output}, explicit) ==
             {:ok, {ItemStack.new("raw_iron", 2), coal, %{output | count: 64}}}

    assert CookingItems.finish({input, coal, nil}, ingot, 1) ==
             {:ok, {ItemStack.new("raw_iron", 2), coal, ingot}}

    assert CookingItems.finish({nil, coal, nil}, ingot) == {:error, :invalid_cooking_items}
  end

  test "fuel remainders replace an empty slot or return bounded overflow for durable admission" do
    state = Data.item_block(Data.item("furnace"))

    assert {:ok, %{fuel: nil, drops: [], burn_ticks: 1600}} =
             CookingItems.consume_fuel(ItemStack.new("coal"), state)

    assert {:ok, %{fuel: bucket, drops: [], burn_ticks: 20_000}} =
             CookingItems.consume_fuel(ItemStack.new("lava_bucket"), state)

    assert bucket == ItemStack.new("bucket")

    fuel = %{
      ItemStack.new("lava_bucket", 2)
      | components: %{
          "minecraft:max_stack_size" => 99,
          "minecraft:custom_name" => {:string, "Fuel"}
        }
    }

    assert {:ok, %{fuel: remaining, drops: [^bucket]}} = CookingItems.consume_fuel(fuel, state)
    assert remaining == %{fuel | count: 1}

    assert CookingItems.consume_fuel(
             %{fuel | removed: MapSet.new(["minecraft:cooking_fuel"])},
             state
           ) == {:error, :not_fuel}

    assert CookingItems.consume_fuel(ItemStack.new("stone"), state) == {:error, :not_fuel}

    assert CookingItems.consume_fuel(%{fuel | count: 100}, state) ==
             {:error, :invalid_cooking_fuel}

    assert CookingItems.finish(
             {ItemStack.new("raw_iron"), nil, nil},
             ItemStack.new("iron_ingot"),
             0
           ) == {:error, :invalid_cooking_items}
  end
end
