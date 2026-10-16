defmodule Valimc.ConsumableRemovalTest do
  use ExUnit.Case, async: true
  alias Valimc.{ConsumableRemoval, FoodItems}
  alias Valimc.Protocol.{EffectTypes, ItemStack}

  test "milk clears suppressed beneficial and harmful stacks; honey clears poison only" do
    fire = EffectTypes.id("fire_resistance")
    poison = EffectTypes.id("poison")

    effects = %{
      fire => [{-1, 0, false, true, true}],
      poison => [{1, 255, true, false, false}, {-1, 0, false, true, true}]
    }

    assert {:ok, %{}, removed} = ConsumableRemoval.apply(effects, :all)
    assert removed == Enum.sort([fire, poison])
    assert {:ok, %{^fire => _}, [^poison]} = ConsumableRemoval.apply(effects, :poison)
    assert {:ok, %{}, []} = ConsumableRemoval.apply(%{}, :all)
    assert {:ok, %{}, []} = ConsumableRemoval.apply(%{}, :poison)
    assert {:error, :invalid_player_effects} = ConsumableRemoval.apply(%{poison => []}, :all)
  end

  test "only unchanged stock removal callbacks and listener sets are admitted" do
    for {name, policy} <- [{"milk_bucket", :all}, {"honey_bottle", :poison}] do
      stack = ItemStack.new(name)
      props = FoodItems.properties(stack)
      assert {:ok, ^policy} = ConsumableRemoval.policy(stack, props)
      assert :unsupported = ConsumableRemoval.policy(stack, %{props | consumable: nil})

      assert :unsupported =
               ConsumableRemoval.policy(stack, %{
                 props
                 | consumable: Map.put(props.consumable, "effects", 0)
               })

      assert :unsupported =
               ConsumableRemoval.policy(stack, %{
                 props
                 | other_listeners: ["minecraft:potion_contents"]
               })
    end

    apple = ItemStack.new("golden_apple")
    assert :unsupported = ConsumableRemoval.policy(apple, FoodItems.properties(apple))
  end
end
