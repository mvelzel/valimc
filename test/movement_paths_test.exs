defmodule Valimc.Physics.MovementPathsTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MovementPaths

  test "bounded history coalesces the oldest travel without retaining its bent axis order" do
    history =
      Enum.reduce(0..149, %MovementPaths{}, fn i, history ->
        MovementPaths.record(history, {i * 0.01, 64.0, 0.5}, {0.01, 0.0, 0.0}, {0.02, 0.0, 0.0})
      end)

    assert history.count == 100
    paths = MovementPaths.collect(history, {0.0, 64.0, 0.5}, {1.5, 64.0, 0.5})
    assert length(paths) == 100
    assert hd(paths).from == {0.0, 64.0, 0.5} and hd(paths).axis == nil
    assert elem(hd(paths).to, 0) == 0.51
    assert Enum.at(paths, 1).axis == {0.02, 0.0, 0.0}
    assert List.last(paths).to == {1.5, 64.0, 0.5}
  end

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
