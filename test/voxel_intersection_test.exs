defmodule Valimc.VoxelIntersectionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Shape, VoxelOps}

  test "world boxes retain native construction rules while local operations stay local" do
    full = VoxelOps.world_box({29_999_990, 64, -29_999_990, 29_999_991, 65, -29_999_989})

    middle =
      VoxelOps.world_box({29_999_990.2, 64.2, -29_999_989.8, 29_999_990.8, 64.8, -29_999_989.2})

    assert VoxelOps.intersects?(full, middle)
    assert_raise ArgumentError, fn -> VoxelOps.union(full, middle) end
    assert_raise ArgumentError, fn -> VoxelOps.box({17, 0, 0, 18, 1, 1}) end
    assert Shape.empty?(VoxelOps.world_box({10, 0, 0, 10.00000001, 1, 1}))
  end

  test "malformed or oversized grids reject before merged cell iteration" do
    shape = VoxelOps.box({0, 0, 0, 1, 1, 1})

    for bad <- [
          nil,
          %{shape | sizes: {33, 1, 1}},
          %{shape | bits: <<>>},
          %{shape | axes: {{0.0, 60_000_001.0}, {0.0, 1.0}, {0.0, 1.0}}},
          %{shape | boxes: List.duplicate({0, 0, 0, 1, 1, 1}, 65)}
        ] do
      assert_raise ArgumentError, fn -> VoxelOps.intersects?(bad, shape) end
    end

    assert_raise ArgumentError, fn -> VoxelOps.world_box({0, 0, 0, 60_000_001, 1, 1}) end
  end
end
