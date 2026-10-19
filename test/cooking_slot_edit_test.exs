defmodule Valimc.CookingSlotEditTest do
  use ExUnit.Case, async: true
  alias Valimc.Cooking
  alias Valimc.Physics.CookingBlocks
  alias Valimc.Protocol.ItemStack

  defp edit(state, slots, speed \\ 1.0, kind \\ :furnace) do
    {:ok, block} = CookingBlocks.placement(kind, 0.0)
    Cooking.edit_slots(%{state | speed: speed}, slots, block)
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
