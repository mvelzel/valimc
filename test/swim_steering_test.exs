defmodule Valimc.Physics.SwimSteeringTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.SwimSteering

  test "upward steering needs jump or fluid above; downward steering always applies while swimming" do
    v = {0.1, 0.0, -0.2}
    assert {:ok, ^v} = SwimSteering.step(v, 1.0, true, false, false, false)
    assert {:ok, {0.1, 0.06, -0.2}} = SwimSteering.step(v, 1.0, true, true, false, false)
    assert {:ok, {0.1, 0.06, -0.2}} = SwimSteering.step(v, 1.0, true, false, true, false)
    assert {:ok, {0.1, -0.085, -0.2}} = SwimSteering.step(v, -1.0, true, false, false, false)
    assert {:ok, ^v} = SwimSteering.step(v, -1.0, false, true, true, false)
    assert {:ok, ^v} = SwimSteering.step(v, -1.0, true, true, true, true)
  end

  test "the downward blend changes strictly below minus point two and observations are bounded" do
    assert {:ok, {+0.0, -0.012, +0.0}} =
             SwimSteering.step({0, 0, 0}, -0.2, true, false, false, false)

    {:ok, {_, y, _}} = SwimSteering.step({0, 0, 0}, -0.2000000001, true, false, false, false)
    assert y < -0.017
    assert {:ok, -1.0} = SwimSteering.look_y(90)
    assert {:ok, 1.0} = SwimSteering.look_y(-90)
    assert {:error, :invalid_swim_pitch} = SwimSteering.look_y(1_000_001)

    assert {:error, :invalid_swim_steering} =
             SwimSteering.step({0, 65, 0}, 0, true, false, false, false)
  end
end
