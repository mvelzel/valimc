defmodule Valimc.VoxelIntersectionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Shape, VoxelOps}

  test "occupied cells distinguish a hole from the compound bounding box" do
    left = VoxelOps.box({0, 0, 0, 0.25, 1, 1})
    right = VoxelOps.box({0.75, 0, 0, 1, 1, 1})
    hollow = VoxelOps.union(left, right)
    hole = VoxelOps.box({0.3, 0.3, 0.3, 0.7, 0.7, 0.7})
    refute VoxelOps.intersects?(hollow, hole)
    assert VoxelOps.intersects?(hollow, left)
    refute VoxelOps.intersects?(%Shape{}, hollow)
  end

  test "native overlap-only epsilon merging rejects contact and microscopic overlap" do
    a = VoxelOps.box({-0.2, -0.2, -0.2, 1, 1, 1})

    for lo <- [1.0, 1.0 - 1.0e-8, 1.0 + 1.0e-8] do
      b = VoxelOps.box({lo, -0.1, -0.1, 2, 1, 1})
      refute VoxelOps.intersects?(a, b)
      refute VoxelOps.intersects?(b, a)
    end

    b = VoxelOps.box({1.0 - 2.0e-7, -0.1, -0.1, 2, 1, 1})
    assert VoxelOps.intersects?(a, b) and VoxelOps.intersects?(b, a)
  end

  test "world boxes retain native construction rules while local operations stay local" do
    full = VoxelOps.world_box({29_999_990, 64, -29_999_990, 29_999_991, 65, -29_999_989})

    middle =
      VoxelOps.world_box({29_999_990.2, 64.2, -29_999_989.8, 29_999_990.8, 64.8, -29_999_989.2})

    assert VoxelOps.intersects?(full, middle)
    assert_raise ArgumentError, fn -> VoxelOps.union(full, middle) end
    assert_raise ArgumentError, fn -> VoxelOps.box({17, 0, 0, 18, 1, 1}) end
    assert Shape.empty?(VoxelOps.world_box({10, 0, 0, 10.00000001, 1, 1}))
  end

  test "identical grid coordinates preserve native occupancy at their internal boundaries" do
    slab = VoxelOps.box({0, 0, 0, 1, 0.5, 1})
    top = VoxelOps.box({0, 0.5, 0, 1, 1, 1})
    assert VoxelOps.intersects?(slab, slab)
    refute VoxelOps.intersects?(slab, top)
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
