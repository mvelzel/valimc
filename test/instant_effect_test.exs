defmodule Valimc.InstantEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.InstantEffect

  test "ordinary player drinks heal or request self-attributed indirect magic" do
    assert {:ok, {:heal, 4.0}} = InstantEffect.drink_request(5, 0)
    assert {:ok, {:heal, 8.0}} = InstantEffect.drink_request(5, 1)
    assert {:ok, {:hurt, :indirect_magic, 6.0}} = InstantEffect.drink_request(6, 0)
    assert {:ok, {:hurt, :indirect_magic, 12.0}} = InstantEffect.drink_request(6, 1)
  end

  test "signed Java shift distances wrap, including negative and zero requests" do
    assert {:ok, {:heal, 134_217_728.0}} = InstantEffect.drink_request(5, 25)
    assert {:ok, {:heal, -2_147_483_648.0}} = InstantEffect.drink_request(5, 29)
    assert {:ok, {:heal, amount}} = InstantEffect.drink_request(5, 30)
    assert amount == 0
    assert InstantEffect.drink_request(5, 32) == InstantEffect.drink_request(5, 0)
    assert InstantEffect.drink_request(6, 255) == InstantEffect.drink_request(6, 31)
    assert {:ok, {:hurt, :indirect_magic, -1_073_741_824.0}} = InstantEffect.drink_request(6, 29)
  end

  test "unrelated effects and unbounded amplifiers are refused" do
    for {id, amplifier} <- [{9, 0}, {5, -1}, {6, 256}, {5, nil}, {"instant_health", 0}] do
      assert {:error, :invalid_instant_effect} = InstantEffect.drink_request(id, amplifier)
    end
  end
end
