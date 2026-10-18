defmodule Valimc.CookingSlotEditTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack

  defp edit(state, slots, speed \\ 1.0, kind \\ :furnace) do
    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    Cooking.edit_slots(%{state | speed: speed}, slots, block)
  end

  test "same components preserve progress across input count changes, but a new identity resets" do
    input = ItemStack.new("raw_iron", 3)

    state = %Cooking{
      slots: {input, nil, nil},
      burn_left: 17,
      burn_total: 1600,
      progress: 49,
      total: 123
    }

    fewer = %{input | count: 1}
    assert {:ok, %{progress: 49, total: 123}} = edit(state, {fewer, nil, nil})
    named = %{input | components: %{"minecraft:custom_name" => {:string, "Ore"}}}

    assert {:ok, %{progress: 0, total: 100, burn_left: 17, burn_total: 1600, speed: 2.0}} =
             edit(state, {named, nil, nil}, 2.0, :blast_furnace)
  end

  test "clearing or inserting an unprocessable input uses native unscaled fallback duration" do
    state = %Cooking{slots: {ItemStack.new("cod"), nil, nil}, progress: 49, total: 123}

    for input <- [nil, ItemStack.new("bedrock")], kind <- [:furnace, :smoker, :blast_furnace] do
      assert {:ok, %{progress: 0, total: 200}} = edit(state, {input, nil, nil}, 2.0, kind)
    end
  end

  test "fuel/output edits and a completely empty no-op do not reset or rescale progress" do
    state = %Cooking{progress: 49, total: 123, burn_left: 17, burn_total: 1600}

    for slots <- [
          {nil, nil, nil},
          {nil, ItemStack.new("coal"), nil},
          {nil, nil, ItemStack.new("iron_ingot")}
        ] do
      assert {:ok, next} = edit(state, slots, 2.0)
      assert next == %{state | slots: slots, speed: 2.0}
    end
  end

  test "oversized or malformed proposals return no clamped or partial result" do
    state = %Cooking{slots: {ItemStack.new("raw_iron", 3), nil, nil}, progress: 49, total: 123}

    for slots <- [{ItemStack.new("coal", 99), nil, nil}, {}, {nil, :invalid, nil}] do
      assert {:error, :invalid_cooking_edit} = edit(state, slots)
    end

    assert state.progress == 49 and elem(state.slots, 0).count == 3
    assert {:error, :invalid_cooking_edit} = Cooking.edit_slots(state, state.slots, 0)
  end
end
