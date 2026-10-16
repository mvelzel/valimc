defmodule Valimc.StockFoodEffectsTest do
  use ExUnit.Case, async: true
  alias Valimc.{FoodItems, StockFoodEffects}
  alias Valimc.Protocol.{EffectTypes, ItemStack}

  test "stock golden apple keeps the full ordered regeneration and Absorption group" do
    item = ItemStack.new("golden_apple")

    assert {:ok, [callback] = callbacks} =
             StockFoodEffects.policy(item, FoodItems.properties(item))

    assert callback.probability == 1.0

    assert Enum.map(callback.effects, &elem(&1, 0)) ==
             Enum.map(~w(regeneration absorption), &EffectTypes.id/1)

    assert {:ok, effects} = StockFoodEffects.resolve(callbacks, [0.9999999403953552])
    assert effects == callback.effects
  end

  test "chance equality fails the whole callback group and a lower draw selects every ordered effect" do
    item = ItemStack.new("chicken")
    {:ok, [callback] = callbacks} = StockFoodEffects.policy(item, FoodItems.properties(item))
    assert {:ok, []} = StockFoodEffects.resolve(callbacks, [callback.probability])
    assert {:ok, selected} = StockFoodEffects.resolve(callbacks, [0.0])
    assert selected == callback.effects
    assert Enum.map(selected, &elem(&1, 0)) == [EffectTypes.id("hunger")]
  end

  test "draw count/precision boundaries and non-stock listener policies cannot silently lose callbacks" do
    item = ItemStack.new("enchanted_golden_apple")
    props = FoodItems.properties(item)
    {:ok, callbacks} = StockFoodEffects.policy(item, props)

    for draws <- [[], [0.0, 0.0], [-0.1], [1.0], [nil], [0.1]],
        do:
          assert(
            StockFoodEffects.resolve(callbacks, draws) == {:error, :invalid_food_effect_draws}
          )

    assert StockFoodEffects.policy(item, %{props | other_listeners: ["minecraft:potion_contents"]}) ==
             :unsupported

    assert StockFoodEffects.policy(item, %{
             props
             | consumable: Map.put(props.consumable, "effects", 0)
           }) == :unsupported

    assert StockFoodEffects.policy(
             ItemStack.new("apple"),
             FoodItems.properties(ItemStack.new("apple"))
           ) == :unsupported
  end
end
