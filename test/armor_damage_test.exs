defmodule Valimc.Physics.ArmorDamageTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ArmorDamage

  test "zero armor preserves damage, including the largest native float" do
    for amount <- [0.0, 1.0, 4.0, 20.0, 3.4028234663852886e38],
        toughness <- [0.0, 20.0],
        do: assert(ArmorDamage.reduce(amount, 0, toughness) == {:ok, amount})
  end

  test "within native attribute domains armor never grants health or amplifies damage" do
    for amount <- [0.0, 0.5, 1.0, 4.0, 20.0, 100.0],
        armor <- [0, 5, 20, 30],
        toughness <- [0, 8, 20] do
      assert {:ok, damage} = ArmorDamage.reduce(amount, armor, toughness)
      assert damage >= 0.0 and damage <= amount
    end

    assert {:ok, 12.0} = ArmorDamage.reduce(20, 20, 0)
  end

  test "owner supplied values outside native domains refuse before arithmetic" do
    for args <- [
          {-1, 0, 0},
          {1.0e100, 0, 0},
          {1, -1, 0},
          {1, 30.0001, 0},
          {1, 0, -1},
          {1, 0, 20.0001},
          {nil, 0, 0},
          {1, :armor, 0},
          {1, 0, "8"}
        ] do
      assert {:error, :invalid_armor_damage} = apply(ArmorDamage, :reduce, Tuple.to_list(args))
    end
  end
end
