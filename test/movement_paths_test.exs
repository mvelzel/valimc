defmodule Valimc.Physics.MovementPathsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MovementPaths

  test "blocked tiny travel is omitted while stationary and final gap contacts remain" do
    origin = {0.5, 64.0, 0.5}
    empty = %MovementPaths{}
    assert MovementPaths.record(empty, origin, {0.0, 0.0, 0.0}, {0.1, 0.0, 0.0}) == empty
    assert MovementPaths.record(empty, origin, {0.0001, 0.0, 0.0}, {0.1, 0.0, 0.0}) == empty
    refute MovementPaths.records?({0.0001, 0.0, 0.0}, {0.1, 0.0, 0.0})
    assert MovementPaths.records?({0.0001, 0.0, 0.0}, {0.0001, 0.0, 0.0})

    assert MovementPaths.collect(empty, origin, origin) == [
             %{from: origin, to: origin, axis: nil}
           ]

    h = MovementPaths.record(empty, origin, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0})
    assert h.count == 1
    assert length(MovementPaths.collect(h, origin, {0.500001, 64.0, 0.5})) == 1
    assert length(MovementPaths.collect(h, origin, {0.50002, 64.0, 0.5})) == 2
  end
end
