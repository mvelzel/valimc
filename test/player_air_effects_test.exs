defmodule Valimc.PlayerAirEffectsTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerAirEffects, PlayerEffects}
  alias Valimc.Protocol.EffectTypes

  test "air predicates use map presence until expiry, including Nautilus/refill overrides" do
    water = EffectTypes.id("water_breathing")
    nautilus = EffectTypes.id("breath_of_the_nautilus")

    effects = %{
      water => [{0, 255, false, false, false}],
      nautilus => [{-1, 0, false, true, true}]
    }

    assert PlayerAirEffects.breathes?(effects) and PlayerAirEffects.refills?(effects)
    assert {:ok, next, [{:remove, ^water}]} = PlayerEffects.tick(effects)
    assert PlayerAirEffects.breathes?(next)
    refute PlayerAirEffects.refills?(next)
    assert {:ok, empty, true} = PlayerEffects.remove(next, nautilus)
    refute PlayerAirEffects.breathes?(empty)
    assert PlayerAirEffects.refills?(empty)
  end
end
