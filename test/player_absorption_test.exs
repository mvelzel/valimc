defmodule Valimc.PlayerAbsorptionTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerAbsorption
  @absorption Valimc.Protocol.EffectTypes.id("absorption")

  test "unbounded or malformed state is rejected before attribute/pool work" do
    assert {:error, :invalid_absorption} =
             PlayerAbsorption.derive(%{@absorption => [{1, 256, false, true, true}]})

    assert {:error, :invalid_absorption} = PlayerAbsorption.derive(%{}, 2049)
    assert {:error, :invalid_absorption} = PlayerAbsorption.set(nil, 4)
    assert {:error, :invalid_absorption} = PlayerAbsorption.start(0, 4, 256)
    assert {:error, :invalid_absorption} = PlayerAbsorption.tick([], 1)
    assert {:error, :invalid_absorption} = PlayerAbsorption.spend(4, -1)
  end
end
