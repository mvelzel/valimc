defmodule Valimc.PlayerAbsorptionTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerAbsorption, PlayerEffects}
  @absorption Valimc.Protocol.EffectTypes.id("absorption")

  test "only the active dose supplies maximum golden hearts and native addition is bounded" do
    effects = %{@absorption => [{1, 255, false, true, true}, {-1, 0, false, true, true}]}

    assert {:ok,
            %{
              maximum: 1024.0,
              attribute: {22, +0.0, [{"minecraft:effect.absorption", 1024.0, 0}]}
            }} =
             PlayerAbsorption.derive(effects)

    assert {:ok, %{maximum: 2048.0}} = PlayerAbsorption.derive(effects, 2048.0)
    assert {:ok, +0.0} = PlayerAbsorption.set(-1, 4.0)
    assert {:ok, 4.0} = PlayerAbsorption.set(5, 4.0)
  end

  test "an unchanged refresh starts its incoming dose without inventing a notification" do
    effect = [{200, 1, false, true, true}]

    assert {:ok, effects, false} =
             PlayerEffects.add(%{@absorption => effect}, @absorption, [{1, 0, false, true, true}])

    assert {:ok, %{maximum: maximum}} = PlayerAbsorption.derive(effects)
    assert {:ok, 4.0} = PlayerAbsorption.start(0.5, maximum, 0)
    assert {:ok, 7.5} = PlayerAbsorption.start(7.5, maximum, 0)
  end

  test "depletion ends even an infinite head before hidden promotion; ordinary promotion does not refill" do
    effect = [{1, 1, false, true, true}, {10, 0, false, true, true}]
    assert {:ok, ^effect, false, false} = PlayerAbsorption.tick(effect, 0.0)

    assert {:ok, [{-1, 0, false, true, true}], false, false} =
             PlayerAbsorption.tick([{-1, 0, false, true, true}], 0.0)

    assert {:ok, promoted, true, true} = PlayerAbsorption.tick(effect, 0.5)
    assert {:ok, %{maximum: maximum}} = PlayerAbsorption.derive(%{@absorption => promoted})
    assert maximum == 4.0
    assert {:ok, 0.5} = PlayerAbsorption.set(0.5, maximum)
    assert {:ok, 4.0} = PlayerAbsorption.set(7.5, maximum)
  end

  test "unbounded or malformed state is rejected before attribute/pool work" do
    assert {:error, :invalid_absorption} =
             PlayerAbsorption.derive(%{@absorption => [{1, 256, false, true, true}]})

    assert {:error, :invalid_absorption} = PlayerAbsorption.derive(%{}, 2049)
    assert {:error, :invalid_absorption} = PlayerAbsorption.set(nil, 4)
    assert {:error, :invalid_absorption} = PlayerAbsorption.start(0, 4, 256)
    assert {:error, :invalid_absorption} = PlayerAbsorption.tick([], 1)
  end
end
