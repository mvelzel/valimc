defmodule Valimc.Physics.FallDamageTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FallDamage

  test "material float32, attribute range and positive int saturation remain explicit" do
    assert {:ok, 2} = FallDamage.calculate(13.0, 0.2, %FallDamage{})

    assert {:ok, 2_147_483_647} =
             FallDamage.calculate(60_000_000.0, 4.0, %FallDamage{attribute_multiplier: 100.0})

    assert {:error, :invalid_fall_damage} = FallDamage.calculate(-1.0, 1.0, %FallDamage{})

    assert {:error, :invalid_fall_damage} =
             FallDamage.calculate(1.0, 1.0, %FallDamage{attribute_multiplier: 101.0})
  end
end
