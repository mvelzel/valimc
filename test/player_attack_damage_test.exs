defmodule Valimc.PlayerAttackDamageTest do
  @moduledoc "A player's melee damage under Strength and Weakness (VMC-083)."
  use ExUnit.Case, async: true
  alias Valimc.Data.EffectTypes
  alias Valimc.Player.Attack
  alias Valimc.Protocol.ItemStack

  defp effect(name, amplifier),
    do: %{EffectTypes.id(name) => [{-1, amplifier, false, true, true}]}

  test "Strength adds three a level to a sword's damage and Weakness takes four" do
    sword = ItemStack.new("diamond_sword")
    assert Attack.attack_damage(sword, %{}) == 7.0
    assert Attack.attack_damage(sword, effect("strength", 0)) == 10.0
    assert Attack.attack_damage(sword, effect("strength", 4)) == 22.0
    assert Attack.attack_damage(nil, effect("weakness", 0)) == 0.0
  end
end
