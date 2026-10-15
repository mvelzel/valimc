defmodule Valimc.FoodItemsTest do
  use ExUnit.Case, async: true
  alias Valimc.{FoodItems, PlayerAbilities, PlayerFood}
  alias Valimc.Protocol.ItemStack

  test "native plain food defaults and removals select use without silently dropping specialized listeners" do
    bread = ItemStack.new("bread")
    props = FoodItems.properties(bread)
    assert props.food == %{nutrition: 5, saturation: 6.0, can_always_eat: false}
    assert props.consumable["ticks"] == 32 and props.remainder == nil
    assert FoodItems.plain?(props)
    assert FoodItems.properties(ItemStack.new("mushroom_stew")).remainder == ItemStack.new("bowl")

    for name <- ["honey_bottle", "potion", "suspicious_stew", "milk_bucket"],
        do: refute(FoodItems.plain?(FoodItems.properties(ItemStack.new(name))))

    refute FoodItems.plain?(FoodItems.properties(ItemStack.new("stone")))

    refute FoodItems.plain?(
             FoodItems.properties(%{bread | removed: MapSet.new(["minecraft:consumable"])})
           )

    assert FoodItems.properties(%{bread | removed: MapSet.new(["minecraft:food"])}).food == nil

    assert FoodItems.properties(%{
             ItemStack.new("mushroom_stew")
             | removed: MapSet.new(["minecraft:use_remainder"])
           }).remainder == nil
  end

  test "food overrides drive eligibility; food removed from a consumable still permits use" do
    survival = PlayerAbilities.for_mode(:survival)
    bread = ItemStack.new("bread")
    props = FoodItems.properties(bread)
    refute FoodItems.eligible?(props, %PlayerFood{}, survival)
    assert FoodItems.eligible?(props, %PlayerFood{level: 19}, survival)
    assert FoodItems.eligible?(props, %PlayerFood{}, PlayerAbilities.for_mode(:creative))
    patched = %{bread | components: %{"minecraft:food" => %{props.food | can_always_eat: true}}}
    assert FoodItems.eligible?(FoodItems.properties(patched), %PlayerFood{}, survival)

    assert FoodItems.eligible?(
             FoodItems.properties(%{bread | removed: MapSet.new(["minecraft:food"])}),
             %PlayerFood{},
             survival
           )
  end

  test "meal arithmetic preserves native positive integer overflow and saturation bounds" do
    assert PlayerFood.eat(%PlayerFood{level: 1}, 2_147_483_647, 6.0).level == 0
    assert PlayerFood.eat(%PlayerFood{level: 0}, 2_147_483_647, 6.0).level == 20
    food = PlayerFood.eat(%PlayerFood{level: 19}, 5, 3.4028234663852886e38)
    assert food.level == 20 and food.saturation == 20.0
    assert PlayerFood.valid?(food)
  end
end
