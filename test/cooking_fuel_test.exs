defmodule Valimc.Physics.CookingFuelTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.CookingFuel
  alias Valimc.Protocol.{Data, ItemStack}

  test "removal overrides default fuel, names preserve it, unsupported patches refuse instead of guessing" do
    furnace = Data.item_block(Data.item("furnace"))
    stock = ItemStack.new("coal", 4)
    named = %{stock | components: %{"minecraft:custom_name" => {:string, "Fuel"}}}
    assert CookingFuel.resolve(named, furnace) == CookingFuel.resolve(stock, furnace)

    assert CookingFuel.resolve(
             %{stock | removed: MapSet.new(["minecraft:cooking_fuel"])},
             furnace
           ) == {:ok, %{burn_ticks: 0, speed_multiplier: 1.0}}

    assert CookingFuel.resolve(%{stock | components: %{"minecraft:cooking_fuel" => 1}}, furnace) ==
             {:error, :unsupported_cooking_fuel}

    assert CookingFuel.resolve(%{stock | count: 0}, furnace) == {:error, :invalid_cooking_fuel}

    assert CookingFuel.resolve(stock, Data.block("stone")) ==
             {:error, :unsupported_furnace_context}
  end
end
