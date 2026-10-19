defmodule Valimc.PlayerMovementSpeedTest do
  use ExUnit.Case, async: true
  alias Valimc.PlayerMovementSpeed
  alias Valimc.Protocol.EffectTypes
  @speed EffectTypes.id("speed")
  @slow EffectTypes.id("slowness")

  test "malformed state is refused" do
    for invalid <- [nil, %{@speed => []}, %{@slow => [{-1, 256, false, true, true}]}] do
      assert {:error, :invalid_movement_speed} = PlayerMovementSpeed.derive(invalid, false)
    end

    assert {:error, :invalid_movement_speed} = PlayerMovementSpeed.derive(%{}, 1)
  end
end
