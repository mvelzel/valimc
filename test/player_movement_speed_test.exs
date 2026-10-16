defmodule Valimc.PlayerMovementSpeedTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerEffects, PlayerMovementSpeed}
  alias Valimc.Protocol.EffectTypes
  @speed EffectTypes.id("speed")
  @slow EffectTypes.id("slowness")

  test "promoted native coefficients compose with sprint before the travel float cast" do
    effects = %{@speed => [{200, 1, false, true, true}], @slow => [{200, 0, false, true, true}]}
    assert {:ok, result} = PlayerMovementSpeed.derive(effects, true)

    assert result.attribute ==
             {26, 0.10000000149011612,
              [
                {"minecraft:sprinting", 0.30000001192092896, 2},
                {"minecraft:effect.speed", 0.4000000059604645, 2},
                {"minecraft:effect.slowness", -0.15000000596046448, 2}
              ]}

    assert result.travel_speed > 0.15 and result.travel_speed < 0.16
  end

  test "high amplifiers do not wrap and negative total speed clamps to zero" do
    assert {:ok, fast} =
             PlayerMovementSpeed.derive(%{@speed => [{-1, 255, false, true, true}]}, false)

    assert fast.travel_speed > 5.0

    assert {:ok, stopped} =
             PlayerMovementSpeed.derive(%{@slow => [{-1, 6, false, true, true}]}, true)

    assert stopped.value == 0 and stopped.travel_speed == 0
  end

  test "only active heads contribute, including zero duration until owner removal" do
    effects = %{@speed => [{1, 1, false, true, true}, {201, 0, false, true, true}]}
    assert {:ok, strong} = PlayerMovementSpeed.derive(effects, false)
    assert {:ok, promoted, _} = PlayerEffects.tick(effects)
    assert {:ok, weak} = PlayerMovementSpeed.derive(promoted, false)
    assert strong.travel_speed > weak.travel_speed

    assert {:ok, ended} =
             PlayerMovementSpeed.derive(%{@speed => [{0, 1, false, true, true}]}, false)

    assert ended == strong
    assert {:ok, %{}, _} = PlayerEffects.tick(%{@speed => [{0, 1, false, true, true}]})
  end

  test "unrelated effects have no speed contribution; malformed state is refused" do
    assert PlayerMovementSpeed.derive(%{11 => [{50, 0, false, true, true}]}, false) ==
             PlayerMovementSpeed.derive(%{}, false)

    for invalid <- [nil, %{@speed => []}, %{@slow => [{-1, 256, false, true, true}]}] do
      assert {:error, :invalid_movement_speed} = PlayerMovementSpeed.derive(invalid, false)
    end

    assert {:error, :invalid_movement_speed} = PlayerMovementSpeed.derive(%{}, 1)
  end
end
