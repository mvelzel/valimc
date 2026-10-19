defmodule Valimc.MovementCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Collision, Shape}
  @box {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}

  test "empty list preserves tiny displacements and signed zeros while nonempty lists use native epsilon" do
    request = {-0.0, 1.0e-8, -1.0e-8}

    assert :erlang.term_to_binary(Collision.move(@box, [], request)) ==
             :erlang.term_to_binary(request)

    assert Collision.move(@box, [%Shape{}], request) == {0.0, 0.0, 0.0}
    assert <<elem(Collision.move(@box, [%Shape{}], request), 0)::float-64>> == <<0::64>>
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
