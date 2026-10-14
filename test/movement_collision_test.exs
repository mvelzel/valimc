defmodule Valimc.MovementCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Box, Collision, Shape, VoxelOps}
  @box {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}

  test "horizontal magnitude and ties determine which side of a corner is clipped" do
    corner = VoxelOps.box({1, 0, 1, 2, 3, 2})
    assert Collision.move(@box, [corner], {2, 0, 2}) == {2.0, 0.0, 0.7}
    assert Collision.move(@box, [corner], {1, 0, 2}) == {0.7, 0.0, 2.0}
    assert Collision.move(@box, [corner], {2, 0, 1}) == {2.0, 0.0, 0.7}
  end

  test "vertical clipping precedes horizontal movement and later axes see resolved movement" do
    floor = VoxelOps.box({-4, -1, -4, 4, 0, 4})
    wall = VoxelOps.box({1, 0, -4, 2, 3, 4})
    assert Collision.move(@box, [floor, wall], {2, -1, 2}) == {0.7, 0.0, 2.0}
    ceiling = VoxelOps.box({-4, 2, -4, 4, 3, 4})
    {x, y, z} = Collision.move(@box, [ceiling, wall], {2, 1, 2})
    assert {x, z} == {0.7, 2.0}
    assert y == 2.0 - 1.8
  end

  test "empty list preserves tiny displacements and signed zeros while nonempty lists use native epsilon" do
    request = {-0.0, 1.0e-8, -1.0e-8}

    assert :erlang.term_to_binary(Collision.move(@box, [], request)) ==
             :erlang.term_to_binary(request)

    assert Collision.move(@box, [%Shape{}], request) == {0.0, 0.0, 0.0}
    assert <<elem(Collision.move(@box, [%Shape{}], request), 0)::float-64>> == <<0::64>>
  end

  test "world translation preserves resolved corner contacts" do
    offset = {-17, 64, 17}
    corner = VoxelOps.box({1, 0, 1, 2, 3, 2}) |> Shape.move(offset)
    {x, y, z} = Collision.move(Box.move(@box, offset), [corner], {2, 0, 2})
    assert x == 2.0 and y == 0.0
    assert z == 18.0 - (17.0 + 0.3)
  end

  test "work bounds apply even to empty or zero movement queries" do
    for {box, shapes, request} <- [
          {@box, List.duplicate(%Shape{}, 129), {0, 0, 0}},
          {@box, [], {65, 0, 0}},
          {@box, [], {:invalid, 0, 0}},
          {@box, [], {0, 0}},
          {{1, 0, 0, -1, 1, 1}, [], {0, 0, 0}},
          {{0, 0, 0, 60_000_001, 1, 1}, [], {0, 0, 0}}
        ],
        do: assert_raise(ArgumentError, fn -> Collision.move(box, shapes, request) end)

    assert Collision.move(@box, List.duplicate(%Shape{}, 128), {1, 0, 0}) == {1.0, 0.0, 0.0}
  end
end
