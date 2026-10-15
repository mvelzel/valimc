defmodule Valimc.Physics.FallDamageTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FallDamage

  test "native epsilon/floor threshold differs from rounding a positive fraction upward" do
    assert {:ok, 0} = FallDamage.calculate(3.5, 1.0, %FallDamage{})
    assert {:ok, 0} = FallDamage.calculate(3.999998, 1.0, %FallDamage{})
    assert {:ok, 1} = FallDamage.calculate(3.999999, 1.0, %FallDamage{})
    assert {:ok, -3} = FallDamage.calculate(0.0, 1.0, %FallDamage{})
    assert {:ok, 0} = FallDamage.calculate(100.0, 1.0, %FallDamage{immune: true})
  end

  test "material float32, attribute range and positive int saturation remain explicit" do
    assert {:ok, 2} = FallDamage.calculate(13.0, 0.2, %FallDamage{})

    assert {:ok, 2_147_483_647} =
             FallDamage.calculate(60_000_000.0, 4.0, %FallDamage{attribute_multiplier: 100.0})

    assert {:error, :invalid_fall_damage} = FallDamage.calculate(-1.0, 1.0, %FallDamage{})

    assert {:error, :invalid_fall_damage} =
             FallDamage.calculate(1.0, 1.0, %FallDamage{attribute_multiplier: 101.0})
  end
end
