defmodule Valimc.CookingTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Protocol.{Data, ItemStack}

  test "fuel admission and repeated steps complete recipes without consuming inputs early" do
    block = Data.item_block(Data.item("furnace"))

    initial = %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil},
      total: 200
    }

    assert {:ok, first, %{lit: true, completed: nil, drops: []}} = Cooking.step(initial, block)
    assert first.slots == {ItemStack.new("raw_iron", 2), ItemStack.new("coal"), nil}
    assert {first.burn_left, first.burn_total, first.progress} == {1600, 1600, 1}

    {after_steps, completions} =
      Enum.reduce(1..199, {first, []}, fn _, {current, completed} ->
        {:ok, next, events} = Cooking.step(current, block)
        {next, if(events.completed, do: [events.completed | completed], else: completed)}
      end)

    assert length(completions) == 1 and after_steps.progress == 0 and
             after_steps.burn_left == 1401

    assert after_steps.slots ==
             {ItemStack.new("raw_iron"), ItemStack.new("coal"), ItemStack.new("iron_ingot")}

    assert initial.slots == {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil}
  end

  test "cooldown, blocked output and missing recipes preserve the distinct native progress rules" do
    block = Data.item_block(Data.item("furnace"))

    assert {:ok, %{progress: 8}, %{lit: false}} =
             Cooking.step(%Cooking{progress: 10, total: 200}, block)

    input = ItemStack.new("raw_iron")
    fuel = ItemStack.new("coal")

    full = %Cooking{
      slots: {input, fuel, ItemStack.new("iron_ingot", 64)},
      total: 200,
      progress: 99,
      burn_left: 2
    }

    assert {:ok, blocked, %{drops: [], completed: nil}} = Cooking.step(full, block)
    assert blocked.progress == 0 and blocked.burn_left == 1 and blocked.slots == full.slots
    missing = %{full | slots: {ItemStack.new("diamond"), fuel, nil}}
    assert {:ok, %{progress: 99, burn_left: 1}, %{completed: nil}} = Cooking.step(missing, block)
  end

  test "fast refuelling rescales partial progress with native float32 rounding before its next step" do
    block = Data.item_block(Data.item("blast_furnace"))

    initial = %Cooking{
      slots: {ItemStack.new("raw_iron"), ItemStack.new("coal"), nil},
      total: 200,
      progress: 99,
      burn_left: 1,
      burn_total: 1600
    }

    assert {:ok, next, %{lit: true, completed: nil}} = Cooking.step(initial, block)

    assert {next.burn_left, next.burn_total, next.speed, next.total, next.progress} ==
             {800, 800, 2.0, 100, 51}

    assert elem(next.slots, 1) == nil
  end

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
