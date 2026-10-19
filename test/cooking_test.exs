defmodule Valimc.CookingTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Protocol.{Data, ItemStack}

  test "same-step fuel remainder and wet sponge completion compose into one slot proposal" do
    block = Data.item_block(Data.item("furnace"))

    initial = %Cooking{
      slots: {ItemStack.new("wet_sponge"), ItemStack.new("lava_bucket"), nil},
      total: 200,
      progress: 199
    }

    assert {:ok, next, %{drops: [], completed: key}} = Cooking.step(initial, block)
    assert is_binary(key)
    assert next.slots == {nil, ItemStack.new("water_bucket"), ItemStack.new("sponge")}
    fuel = %{ItemStack.new("lava_bucket", 2) | components: %{"minecraft:max_stack_size" => 99}}
    initial = %Cooking{slots: {ItemStack.new("raw_iron"), fuel, nil}, total: 200}
    assert {:ok, next, %{drops: [bucket]}} = Cooking.step(initial, block)
    assert bucket == ItemStack.new("bucket") and elem(next.slots, 1) == %{fuel | count: 1}
    assert Cooking.step(%Cooking{}, Data.block("stone")) == {:error, :unsupported_furnace_context}
    assert Cooking.step(%{initial | burn_left: 20_001}, block) == {:error, :invalid_cooking_state}
  end
end
