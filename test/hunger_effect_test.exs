defmodule Valimc.HungerEffectTest do
  use ExUnit.Case, async: true
  alias Valimc.{HungerEffect, PlayerFood, StatusEffect}

  test "hidden promotion contributes only on the following owner tick" do
    effect = [{1, 3, false, true, true}, {101, 0, false, true, true}]
    assert {:ok, {:exhaust, strong}} = HungerEffect.request(effect)
    assert {:ok, promoted, true, true} = StatusEffect.tick(effect)
    assert {:ok, {:exhaust, weak}} = HungerEffect.request(promoted)
    assert strong == weak * 4
    assert PlayerFood.exhaust(%PlayerFood{exhaustion: 40.0}, strong).exhaustion == 40.0
  end

  test "malformed status maps/rungs cannot supply exhaustion work" do
    for invalid <- [nil, [], %{}, [{-2, 0, false, true, true}], [{1, 256, false, true, true}]] do
      assert {:error, :invalid_hunger_effect} = HungerEffect.request(invalid)
    end
  end
end
