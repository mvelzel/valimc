defmodule Valimc.DispensingTest do
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Dispensing
  alias Valimc.Protocol.ItemStack

  test "items dispense by vanilla's behaviour; what ValiMC cannot do keeps the item" do
    assert Dispensing.behaviour(ItemStack.new("dirt")) == :drop
    assert Dispensing.behaviour(ItemStack.new("water_bucket")) == {:pour, 2}
    assert Dispensing.behaviour(ItemStack.new("bucket")) == :fill
    assert Dispensing.behaviour(ItemStack.new("iron_helmet")) == :equipment
    assert Dispensing.behaviour(ItemStack.new("oak_boat")) == :unsupported
    assert Dispensing.behaviour(ItemStack.new("experience_bottle")) == :unsupported

    assert {:projectile, %{entity: "minecraft:small_fireball", event: 1018} = fire} =
             Dispensing.behaviour(ItemStack.new("fire_charge"))

    # A fire charge starts a whole block out; an arrow 0.7 out and 0.1 up.
    assert Dispensing.launch({0, 64, 0}, {1, 0, 0}, fire) == {1.5, 64.5, 0.5}
    {:projectile, arrow} = Dispensing.behaviour(ItemStack.new("arrow"))
    {x, y, _} = Dispensing.launch({0, 64, 0}, {1, 0, 0}, arrow)
    assert_in_delta x, 1.2, 1.0e-9
    assert_in_delta y, 64.6, 1.0e-9
    assert {arrow.power, arrow.uncertainty} == {1.100000023841858, 6.0}
  end

  test "a random filled slot as getRandomSlot draws it, else none" do
    stone = ItemStack.new("stone")
    assert Dispensing.random_slot(Tuple.duplicate(nil, 9), fn _ -> 0 end) == nil
    slots = {nil, stone, nil, stone, stone, nil, nil, nil, nil}
    # Each later filled slot replaces the choice on a zero draw.
    assert Dispensing.random_slot(slots, fn _ -> 0 end) == 4
    assert Dispensing.random_slot(slots, fn odds -> if odds == 1, do: 0, else: 1 end) == 1
  end

  test "insertItem merges, then fills empty slots; the rest comes back" do
    full = ItemStack.new("bucket", 16)
    slots = {ItemStack.new("bucket", 15), full, nil}

    assert Dispensing.insert(slots, ItemStack.new("bucket", 3)) ==
             {{full, full, ItemStack.new("bucket", 2)}, nil}

    assert Dispensing.insert({full, full}, ItemStack.new("bucket")) ==
             {{full, full}, ItemStack.new("bucket")}
  end
end
