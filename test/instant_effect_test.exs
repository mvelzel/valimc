defmodule Valimc.InstantEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.InstantEffect
  @saturation Valimc.Protocol.EffectTypes.id("saturation")

  test "Saturation supplies absolute food properties without wrapping or applying health" do
    assert {:ok, {:eat, 1, 2.0}} = InstantEffect.drink_request(@saturation, 0)
    assert {:ok, {:eat, 256, 512.0}} = InstantEffect.drink_request(@saturation, 255)
    assert {:error, :invalid_instant_effect} = InstantEffect.drink_request(@saturation, 256)
  end

  test "unrelated effects and unbounded amplifiers are refused" do
    for {id, amplifier} <- [{9, 0}, {5, -1}, {6, 256}, {5, nil}, {"instant_health", 0}] do
      assert {:error, :invalid_instant_effect} = InstantEffect.drink_request(id, amplifier)
    end
  end

  test "native instant healing requests clamp health and never revive a dead owner" do
    health = %Valimc.PlayerHealth{value: 18.0}
    assert {:ok, capped} = Valimc.PlayerHealth.heal(health, 4.0)
    assert capped.value == 20.0
    assert {:ok, {:heal, negative}} = InstantEffect.drink_request(5, 29)
    assert {:ok, zero} = Valimc.PlayerHealth.heal(health, negative)
    assert zero.value == 0
    assert {:ok, ^zero} = Valimc.PlayerHealth.heal(zero, 8.0)
    assert {:error, :invalid_health} = Valimc.PlayerHealth.heal(health, nil)
  end
end
