defmodule Valimc.BorderSnapshotTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.BorderSnapshot, as: Border

  test "box containment uses its native max-corner tolerance" do
    {:ok, border} = Border.new(0, 0, 8)
    assert {:ok, true} = Border.contains?(border, {-4.0, 0, -4.0, 4.0, 1, 4.0})
    assert {:ok, true} = Border.contains?(border, {3.0, 0, 3.0, 4.000005, 1, 4.000005})
    assert {:ok, false} = Border.contains?(border, {3.0, 0, 3.0, 4.00002, 1, 4.00002})
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
