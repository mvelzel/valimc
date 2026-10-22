defmodule Valimc.StackIdentityTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp redundant(count) do
    %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:max_stack_size" => 64,
          "minecraft:rarity" => 0,
          "minecraft:repair_cost" => 0,
          "minecraft:item_model" => "minecraft:stone"
        },
        removed: MapSet.new(["minecraft:custom_name", "minecraft:unbreakable"])
    }
  end

  defp data(tag), do: %{ItemStack.new("stone") | components: %{"minecraft:custom_data" => tag}}

  test "ordinary scalar float signed zero remains distinct and malformed identity inputs are rejected" do
    sword = ItemStack.new("iron_sword")
    a = %{sword | components: %{"minecraft:minimum_attack_charge" => 0.0}}
    <<negative::float-32>> = <<0x80000000::32>>
    b = %{sword | components: %{"minecraft:minimum_attack_charge" => negative}}
    refute ItemStack.same_item?(a, b)

    assert catch_throw(ItemStack.identity_key(%{sword | count: 2})) ==
             {:item_error, :stack_size_exceeded}

    assert catch_throw(
             ItemStack.identity_key(%{sword | components: %{"minecraft:custom_name" => "bad"}})
           ) ==
             {:item_error, :invalid_component_value}

    invalid = {:compound, %{"too_deep" => {:list, {:byte, Enum.to_list(1..2000)}}}}

    assert catch_throw(ItemStack.identity_key(data(invalid))) ==
             {:item_error, :invalid_component_value}
  end

  test "partial connected returns conserve effective identity despite changed raw merge representations" do
    stone = ItemStack.new("stone", 64)

    inv = %Inventory{
      slots: Map.new(9..44, &{&1, stone}) |> Map.put(38, %{stone | count: 63}),
      selected: 2,
      carried: redundant(10)
    }

    {:ok, next, [remainder]} = Inventory.close(inv)
    assert next.slots[38].count == 64 and remainder == redundant(9)
  end
end
