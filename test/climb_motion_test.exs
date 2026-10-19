defmodule Valimc.Physics.ClimbMotionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ClimbMotion

  test "climb boost follows collision or jump without overriding other resolved axes" do
    assert {:ok, {0.1, 0.2, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, true, true, false)
    assert {:ok, {0.1, 0.2, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, true, false, true)
    assert {:ok, {0.1, -0.15, -0.1}} = ClimbMotion.finish({0.1, -0.15, -0.1}, false, true, true)
    assert {:error, :invalid_climb_motion} = ClimbMotion.prepare({0, 65, 0}, true, false, false)
  end
end
