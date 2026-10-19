defmodule Valimc.PeriodicEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.{PeriodicEffect, PlayerHealth, StatusEffect}
  alias Valimc.Protocol.EffectTypes

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
