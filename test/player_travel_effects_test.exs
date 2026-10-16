defmodule Valimc.PlayerTravelEffectsTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerEffects, PlayerTravelEffects}
  alias Valimc.Protocol.EffectTypes
  @slow EffectTypes.id("slow_falling")
  @levitation EffectTypes.id("levitation")

  test "slow falling changes gravity only while descending but always resets fall distance" do
    effects = %{@slow => [{200, 255, false, true, true}]}

    assert {:ok, %{gravity: 0.01, reset_fall: true, levitation: nil}} =
             PlayerTravelEffects.derive(effects, -1)

    assert {:ok, %{gravity: 0.08, reset_fall: true}} = PlayerTravelEffects.derive(effects, 1)
    assert PlayerTravelEffects.gravity(0, 0, true) == {:ok, 0.0}
    assert {:ok, -0.08} = PlayerTravelEffects.gravity(-0.08, 0, true)
  end

  test "only the active Levitation head enters air travel and its promotion signature" do
    effects = %{@levitation => [{1, 255, false, true, true}, {10, 0, false, true, true}]}
    assert PlayerTravelEffects.signature(effects) == {false, 255}
    assert {:ok, %{levitation: 255, reset_fall: true}} = PlayerTravelEffects.derive(effects, 1)
    assert {:ok, weak, _} = PlayerEffects.tick(effects)
    assert PlayerTravelEffects.signature(weak) == {false, 0}

    assert {:ok, %{gravity: 0.08, levitation: nil, reset_fall: false}} =
             PlayerTravelEffects.derive(%{}, 0)
  end

  test "bad heads or velocities cannot become travel facts" do
    assert {:error, :invalid_travel_effects} = PlayerTravelEffects.derive(%{@slow => []}, 0)
    assert {:error, :invalid_travel_effects} = PlayerTravelEffects.derive(nil, 0)
    assert {:error, :invalid_travel_effects} = PlayerTravelEffects.derive(%{}, 65)
    assert {:error, :invalid_travel_effects} = PlayerTravelEffects.gravity(2, 0, true)
  end
end
