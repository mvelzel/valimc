defmodule Valimc.StatusEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.StatusEffect

  test "flags update independently; malformed or unordered chains cannot enter owner state" do
    {:ok, state} = StatusEffect.new(20, 2, true, false, true)
    {:ok, weaker} = StatusEffect.new(1, 0, true, true, false)
    assert {:ok, [{20, 2, true, true, false}], true} = StatusEffect.refresh(state, weaker)

    for state <- [
          [],
          [{1, 0, false, true, true}, {20, 1, false, true, true}],
          [{1, 1, false, true, true}, {2, 1, false, true, true}],
          List.duplicate({1, 1, false, true, true}, 257),
          [nil],
          [{-2, 0, false, true, true}],
          [{1, 256, false, true, true}]
        ] do
      refute StatusEffect.valid?(state)
      assert StatusEffect.tick(state) == {:error, :invalid_status_effect}
      assert StatusEffect.refresh(state, weaker) == {:error, :invalid_status_effect}
    end

    assert StatusEffect.new(-2, 0) == {:error, :invalid_status_effect}
    assert StatusEffect.refresh(state, state ++ state) == {:error, :invalid_status_effect}
  end
end
