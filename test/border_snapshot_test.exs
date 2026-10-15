defmodule Valimc.BorderSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.BorderSnapshot, as: Border

  test "fractional bounds clamp to the absolute limit and point bounds are asymmetric" do
    {:ok, border} = Border.new(1.25, -2.5, 16, 8)
    assert {:ok, {-6.75, -8.0, 8.0, 5.5}} = Border.bounds(border)
    assert {:ok, true} = Border.contains?(border, {-6.75, -8.0})
    assert {:ok, false} = Border.contains?(border, {8.0, 0.0})
    assert {:ok, false} = Border.contains?(border, {0.0, 5.5})
    assert {:ok, -1.0} = Border.distance(border, {9.0, 0.0})
  end

  test "box containment uses its native max-corner tolerance" do
    {:ok, border} = Border.new(0, 0, 8)
    assert {:ok, true} = Border.contains?(border, {-4.0, 0, -4.0, 4.0, 1, 4.0})
    assert {:ok, true} = Border.contains?(border, {3.0, 0, 3.0, 4.000005, 1, 4.000005})
    assert {:ok, false} = Border.contains?(border, {3.0, 0, 3.0, 4.00002, 1, 4.00002})
  end

  test "rounded collision planes differ from containment and outside subjects skip the border" do
    {:ok, border} = Border.new(0.25, -0.25, 8)
    box = {4.5, 64.0, -0.3, 5.1, 65.8, 0.3}
    assert {:ok, false} = Border.no_collision?(border, {4.8, 0}, box)
    assert {:ok, true} = Border.no_collision?(border, {5.3, 0}, box)
    assert {:ok, true} = Border.no_collision?(border, nil, box)
    assert {:ok, false} = Border.contains?(border, {4.6, 0})
    assert {:ok, true} = Border.no_collision?(border, {4.6, 0}, {4.3, 64, -0.3, 4.9, 65.8, 0.3})
  end

  test "epsilon-sized corner intersections retain the complete native voxel union" do
    {:ok, border} = Border.new(0, 0, 16)
    box = {8 - 1.0e-7, 64, 8 - 1.0e-7, 8 + 1.0e-7, 65.8, 8 + 1.0e-7}
    assert {:ok, false} = Border.no_collision?(border, {8, 8}, box)
    {:ok, collapsed} = Border.new(0, 0, 0, 0)
    box = {-5.0e-8, 64, -5.0e-8, 5.0e-8, 65.8, 5.0e-8}
    assert {:ok, true} = Border.no_collision?(collapsed, {0, 0}, box)
  end

  test "malformed observations and queries remain explicit failures" do
    for values <- [{nil, 0, 8, 32}, {0, 0, -1, 32}, {0, 0, 8, -1}, {0, 0, 8, 32.0}] do
      assert {:error, :invalid_border_observation} = apply(Border, :new, Tuple.to_list(values))
    end

    for border <- [nil, %Border{diameter: :unknown}, Map.put(%Border{}, :extra, true)] do
      assert {:error, :invalid_border_observation} = Border.bounds(border)
    end

    assert {:error, :invalid_border_query} = Border.contains?(%Border{}, nil)
    assert {:error, :invalid_border_query} = Border.distance(%Border{}, {:unknown, 0})

    assert {:error, :invalid_border_query} =
             Border.no_collision?(%Border{}, {nil, 0}, {0, 0, 0, 1, 1, 1})

    assert {:error, :invalid_border_query} = Border.no_collision?(%Border{}, nil, nil)
  end
end
