defmodule Valimc.PlayerResistanceTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerResistance
  alias Valimc.Protocol.EffectTypes

  test "active level controls eligible damage even at zero duration; hidden level is inactive" do
    id = EffectTypes.id("resistance")
    effects = %{id => [{0, 0, false, true, true}]}
    assert {:ok, 4.0} = PlayerResistance.reduce(5, :magic, effects)
    assert {:ok, 5.0} = PlayerResistance.reduce(5, :out_of_world, effects)
    assert {:ok, 5.0} = PlayerResistance.reduce(5, :starve, effects)
    assert {:ok, 5.0} = PlayerResistance.reduce(5, :magic, %{})

    assert PlayerResistance.reduce(5, :magic, %{
             id => [{1, 4, false, true, true}, {-1, 0, false, true, true}]
           }) == {:ok, 0.0}

    assert PlayerResistance.reduce(5, :magic, %{id => [{-1, 255, false, true, true}]}) ==
             {:ok, 0.0}
  end

  test "native multiply/divide order keeps float32 results and bounded lethal overflow" do
    id = EffectTypes.id("resistance")
    effects = %{id => [{-1, 0, false, true, true}]}
    assert {:ok, 0.07999999821186066} = PlayerResistance.reduce(0.1, :cactus, effects)

    assert {:ok, 3.4028234663852886e38} =
             PlayerResistance.reduce(3.4028234663852886e38, :cactus, effects)

    assert {:error, :invalid_resistance_damage} = PlayerResistance.reduce(-1, :cactus, effects)

    assert {:error, :invalid_resistance_damage} =
             PlayerResistance.reduce(1, :unknown_source, effects)

    assert {:error, :invalid_resistance_damage} = PlayerResistance.reduce(1, :cactus, %{id => []})
  end
end
