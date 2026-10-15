defmodule Valimc.Physics.ClimbMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ClimbMotion

  test "ladder Shift stops descent while scaffolding retains the native speed cap" do
    assert {:ok, %{velocity: {-0.15000000596046448, +0.0, 0.15000000596046448}, reset_fall: true}} =
             ClimbMotion.prepare({-1.0, -2.0, 1.0}, true, true, false)

    assert {:ok, %{velocity: {_, -0.15000000596046448, _}}} =
             ClimbMotion.prepare({-1.0, -2.0, 1.0}, true, true, true)

    v = {1.0, -2.0, -1.0}
    assert {:ok, %{velocity: ^v, reset_fall: false}} = ClimbMotion.prepare(v, false, true, false)
  end

  test "climb boost follows collision or jump without overriding other resolved axes" do
    assert {:ok, {0.1, 0.2, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, true, true, false)
    assert {:ok, {0.1, 0.2, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, true, false, true)
    assert {:ok, {0.1, -0.15, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, false, true, true)
    assert {:error, :invalid_climb_motion} = ClimbMotion.prepare({0, 65, 0}, true, false, false)
  end
end
