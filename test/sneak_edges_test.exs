defmodule Valimc.Physics.SneakEdgesTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{Box, SneakEdges}

  @box {-0.3, 64.0, -0.3, 0.3, 65.8, 0.3}
  defp free(supports), do: fn q -> {:ok, not Enum.any?(supports, &Box.intersects?(q, &1))} end

  test "independent axes precede corner protection and retain vertical displacement" do
    supports = [{-2.0, 63.0, -0.1, 2.0, 64.0, 0.1}, {-0.1, 63.0, -2.0, 0.1, 64.0, 2.0}]

    {:ok, result} =
      SneakEdges.step(
        @box,
        {0.6, -0.08, 0.6},
        %SneakEdges{shift: true, on_ground: true},
        free(supports)
      )

    {x, y, z} = result.requested
    assert x == z and x < 0.4 and x > 0.3 and y == -0.08
    assert result.queries > 2

    {:ok, empty} =
      SneakEdges.step(
        @box,
        {64.0, 0.0, -64.0},
        %SneakEdges{shift: true, on_ground: true},
        free([])
      )

    assert empty.requested == {0.0, 0.0, 0.0} and empty.queries < 4096
  end

  test "near-ground support matters only below the native fall threshold" do
    requested = {0.6, 0.0, 0.0}
    support = [{-1.0, 63.0, -1.0, 0.1, 63.5, 1.0}]

    {:ok, close} =
      SneakEdges.step(
        @box,
        requested,
        %SneakEdges{shift: true, fall_distance: 0.05},
        free(support)
      )

    assert elem(close.requested, 0) < 0.6

    {:ok, falling} =
      SneakEdges.step(
        @box,
        requested,
        %SneakEdges{shift: true, fall_distance: 0.6000000238418579},
        free(support)
      )

    assert falling.requested == requested and falling.queries == 0
  end

  test "exclusions perform no reads, while a missing supporting frame is never empty space" do
    missing = fn _ -> {:error, :incomplete_frame} end

    for facts <- [
          %SneakEdges{},
          %SneakEdges{shift: true, flying: true},
          %SneakEdges{shift: true, mover: :piston}
        ] do
      assert {:ok, %{queries: 0, requested: {0.4, -0.1, 0.2}}} =
               SneakEdges.step(@box, {0.4, -0.1, 0.2}, facts, missing)
    end

    assert {:ok, %{queries: 0}} =
             SneakEdges.step(@box, {0.4, 0.001, 0.2}, %SneakEdges{shift: true}, missing)

    assert {:error, :incomplete_frame} =
             SneakEdges.step(@box, {0.4, 0.0, 0.2}, %SneakEdges{shift: true}, missing)

    assert {:error, :invalid_sneak_edges} =
             SneakEdges.step(@box, {65.0, 0.0, 0.0}, %SneakEdges{}, missing)
  end
end
