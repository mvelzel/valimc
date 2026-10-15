defmodule Valimc.MovementFoodTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MovementFood

  defp contact(overrides),
    do:
      Map.merge(
        %{
          passenger: false,
          swimming: false,
          underwater: false,
          water: false,
          climbing: false,
          grounded: false,
          sprinting: false
        },
        Map.new(overrides)
      )

  test "native float32 distance differs for three-axis swimming and horizontal sprinting" do
    assert MovementFood.amount({0.3, 0.4, 0.0}, contact(swimming: true)) == 0.004999999888241291

    assert MovementFood.amount({0.3, 0.4, 0.0}, contact(grounded: true, sprinting: true)) ==
             0.029999999329447746

    assert MovementFood.amount({0.0, 0.5, 0.0}, contact(water: true)) == 0.0
    assert MovementFood.amount({0.0, 0.5, 0.0}, contact(underwater: true)) > 0
  end

  test "passenger/fluid/climbing precedence prevents sprint charges for overlapping predicates" do
    move = {0.3, 0.4, 0.0}
    assert MovementFood.amount(move, contact(passenger: true, swimming: true)) == 0.0

    assert MovementFood.amount(
             move,
             contact(swimming: true, climbing: true, grounded: true, sprinting: true)
           ) == 0.004999999888241291

    assert MovementFood.amount(move, contact(climbing: true, grounded: true, sprinting: true)) ==
             0.0

    assert MovementFood.amount(move, contact(grounded: true)) == 0.0
    assert MovementFood.amount(move, contact(sprinting: true)) == 0.0
  end

  test "centimeter quantization and bounded deltas exclude unusable owner inputs" do
    c = contact(swimming: true)
    assert MovementFood.amount({0.004999999422580719, 0.0, 0.0}, c) == 0.0
    assert MovementFood.amount({0.0049999997, 0.0, 0.0}, c) > 0
    assert MovementFood.amount({0.005, 0.0, 0.0}, c) > 0
    assert MovementFood.amount({0.0, 0.0, 0.0}, c) == 0.0
    assert_raise FunctionClauseError, fn -> MovementFood.amount({60_000_001, 0, 0}, c) end
    assert_raise FunctionClauseError, fn -> MovementFood.amount({0, 2_000_001, 0}, c) end
  end

  test "ground jump callbacks request native constants before ability gating" do
    assert MovementFood.jump(true) == 0.20000000298023224
    assert MovementFood.jump(false) == 0.05000000074505806
  end
end
