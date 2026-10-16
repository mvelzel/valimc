defmodule Valimc.StatusEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.StatusEffect

  test "shorter strong effects retain a weaker duration that keeps counting while suppressed" do
    {:ok, weak} = StatusEffect.new(20, 0)
    {:ok, strong} = StatusEffect.new(2, 1)
    assert {:ok, stacked, true} = StatusEffect.refresh(weak, strong)

    assert {:ok, [{1, 1, false, true, true}, {19, 0, false, true, true}], true, false} =
             StatusEffect.tick(stacked)

    {:ok, stacked, _, _} = StatusEffect.tick(stacked)
    assert {:ok, [{18, 0, false, true, true}], true, true} = StatusEffect.tick(stacked)
  end

  test "suppressed refresh can change storage without requesting an active-effect notification" do
    {:ok, strong} = StatusEffect.new(2, 255)
    {:ok, infinite} = StatusEffect.new(-1, 0)
    assert {:ok, stacked, false} = StatusEffect.refresh(strong, infinite)
    {:ok, stacked, true, false} = StatusEffect.tick(stacked)
    assert {:ok, [{-1, 0, false, true, true}], true, true} = StatusEffect.tick(stacked)
    assert {:ok, ^infinite, true, false} = StatusEffect.tick(infinite)
    {:ok, ended} = StatusEffect.new(0, 0)
    assert {:ok, ^ended, false, false} = StatusEffect.tick(ended)
  end

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
