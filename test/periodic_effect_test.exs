defmodule Valimc.PeriodicEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.{PeriodicEffect, PlayerHealth, StatusEffect}
  alias Valimc.Protocol.EffectTypes

  test "finite countdown precedes decrement; infinite timing uses signed entity age" do
    regen = EffectTypes.id("regeneration")
    {:ok, finite} = StatusEffect.new(50, 0)
    {:ok, infinite} = StatusEffect.new(-1, 0)
    health = %PlayerHealth{value: 10.0}
    assert {:ok, {:heal, 1.0}} = PeriodicEffect.request(regen, finite, 1, health)
    assert {:ok, :none} = PeriodicEffect.request(regen, infinite, 1, health)
    assert {:ok, {:heal, 1.0}} = PeriodicEffect.request(regen, infinite, -50, health)
    assert {:ok, :none} = PeriodicEffect.request(regen, [{0, 255, false, true, true}], 50, health)
  end

  test "amplifier shift wraps at32 instead of becoming permanently every-tick" do
    poison = EffectTypes.id("poison")

    for {amplifier, expected} <- [{31, {:hurt, :magic, 1.0}}, {32, :none}, {64, :none}] do
      {:ok, effect} = StatusEffect.new(1, amplifier)
      assert {:ok, ^expected} = PeriodicEffect.request(poison, effect, 50, %PlayerHealth{})
    end
  end

  test "only the active head acts before hidden promotion; poison and healing requests have native thresholds" do
    poison = EffectTypes.id("poison")
    effect = [{1, 31, false, true, true}, {-1, 0, false, true, true}]
    assert {:ok, :none} = PeriodicEffect.request(poison, effect, 25, %PlayerHealth{value: 1.0})

    assert {:ok, {:hurt, :magic, 1.0}} =
             PeriodicEffect.request(poison, effect, 1, %PlayerHealth{})

    assert {:ok, [infinite], true, true} = StatusEffect.tick(effect)
    assert {:ok, :none} = PeriodicEffect.request(poison, [infinite], 2, %PlayerHealth{})
    {:ok, effect} = StatusEffect.new(50, 0)

    assert {:ok, :none} =
             PeriodicEffect.request(EffectTypes.id("regeneration"), effect, 1, %PlayerHealth{})

    assert {:ok, {:heal, 1.0}} =
             PeriodicEffect.request(EffectTypes.id("regeneration"), effect, 1, %PlayerHealth{
               value: 0.0
             })

    # A heal request cannot itself revive a player; live owner application is separate.
  end

  test "invalid state/health/age is refused and other catalog effects have no health action" do
    {:ok, effect} = StatusEffect.new(-1, 0)

    assert {:ok, :none} =
             PeriodicEffect.request(EffectTypes.id("water_breathing"), effect, 1, %PlayerHealth{})

    assert {:error, :invalid_periodic_effect} = PeriodicEffect.request(10, [], 1, %PlayerHealth{})

    assert {:error, :invalid_periodic_effect} =
             PeriodicEffect.request(10, effect, 2_147_483_648, %PlayerHealth{})

    assert {:error, :invalid_periodic_effect} =
             PeriodicEffect.request(10, effect, 1, %PlayerHealth{value: -1.0})
  end
end
