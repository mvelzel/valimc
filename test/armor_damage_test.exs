defmodule Valimc.Physics.ArmorDamageTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ArmorDamage

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
