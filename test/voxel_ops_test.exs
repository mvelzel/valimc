defmodule Valimc.VoxelOpsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Shape, VoxelOps}

  test "FULL support requires native face equality, not merely covering the unit face" do
    expanded = VoxelOps.box({-1.0e-7, 0.0, 0.0, 1.5, 1.0, 1.0})
    refute VoxelOps.face_full?(expanded, 0)
    refute VoxelOps.face_full?(expanded, 1)
    assert VoxelOps.face_full?(expanded, 4)
    assert VoxelOps.face_full?(expanded, 5)
    refute VoxelOps.face_full?(%Shape{}, 0)
    assert_raise ArgumentError, fn -> VoxelOps.face_full?(expanded, 6) end
  end

  test "optimization removes redundant interior cuts and does not modify inputs" do
    lower = VoxelOps.box({0.0, 0.0, 0.0, 1.0, 0.5, 1.0})
    upper = VoxelOps.box({0.0, 0.5, 0.0, 1.0, 1.0, 1.0})
    full = VoxelOps.box({0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
    assert VoxelOps.union(lower, upper) == full
    assert VoxelOps.union(%Shape{}, lower) == lower
    assert VoxelOps.optimize(lower) == lower
    assert lower.sizes == {1, 2, 1}
    assert lower.bits == <<1>>
    expanded = VoxelOps.union(full, VoxelOps.box({-0.5, 0.0, 0.0, 1.5, 1.0, 1.0}))
    assert expanded.boxes == [{-0.5, 0.0, 0.0, 1.5, 1.0, 1.0}]
  end

  test "invalid geometry and oversized coordinate jobs fail before producing a partial union" do
    full = VoxelOps.box({0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
    assert_raise ArgumentError, fn -> VoxelOps.box("invalid") end
    assert_raise ArgumentError, fn -> VoxelOps.box({1.0, 0.0, 0.0, 0.0, 1.0, 1.0}) end
    assert_raise ArgumentError, fn -> VoxelOps.box({0.0, 0.0, 0.0, 17.0, 1.0, 1.0}) end
    assert_raise ArgumentError, fn -> VoxelOps.union(full, %Shape{bits: <<0>>}) end

    for oversized <- [
          %{full | axes: {:erlang.make_tuple(100_000, 0.0), {0.0, 1.0}, {0.0, 1.0}}},
          %{full | boxes: [:erlang.make_tuple(100_000, 0.0)]},
          %{full | bits: :binary.copy(<<1>>, 100_000)},
          %{full | boxes: List.duplicate(hd(full.boxes), 100_000)}
        ],
        do: assert_raise(ArgumentError, fn -> VoxelOps.optimize(oversized) end)

    dense = %Shape{
      axes: {List.to_tuple(Enum.map(0..32, &(&1 / 32))), {0.0, 1.0}, {0.0, 1.0}},
      sizes: {32, 1, 1},
      bits: <<255, 255, 255, 255>>,
      boxes: full.boxes
    }

    assert_raise ArgumentError, fn ->
      VoxelOps.union(dense, Shape.move(dense, {0.001, 0.0, 0.0}))
    end

    assert dense.bits == <<255, 255, 255, 255>>
  end

  test "fragmented grids stop at the box work bound without returning an approximation" do
    axes = List.to_tuple(Enum.map(0..15, &(&1 / 15)))

    bits =
      for byte <- 0..421, into: <<>> do
        value =
          Enum.reduce(0..7, 0, fn bit, acc ->
            index = byte * 8 + bit
            x = div(index, 225)
            y = rem(div(index, 15), 15)
            z = rem(index, 15)

            if index < 3375 and rem(x + y + z, 2) == 0,
              do: Bitwise.bor(acc, Bitwise.bsl(1, bit)),
              else: acc
          end)

        <<value>>
      end

    fragmented = %Shape{
      axes: {axes, axes, axes},
      sizes: {15, 15, 15},
      bits: bits,
      boxes: [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
    }

    assert_raise ArgumentError, fn -> VoxelOps.optimize(fragmented) end
  end
end
