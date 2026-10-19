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

  test "centimeter quantization and bounded deltas exclude unusable owner inputs" do
    c = contact(swimming: true)
    assert MovementFood.amount({0.004999999422580719, 0.0, 0.0}, c) == 0.0
    assert MovementFood.amount({0.0049999997, 0.0, 0.0}, c) > 0
    assert MovementFood.amount({0.005, 0.0, 0.0}, c) > 0
    assert MovementFood.amount({0.0, 0.0, 0.0}, c) == 0.0
    assert_raise FunctionClauseError, fn -> MovementFood.amount({60_000_001, 0, 0}, c) end
    assert_raise FunctionClauseError, fn -> MovementFood.amount({0, 2_000_001, 0}, c) end
  end
end
