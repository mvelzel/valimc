defmodule Valimc.BlockCollisionsTest do
  use ExUnit.Case, async: true

  alias Valimc.Physics.{
    BlockCollisions,
    BlockScan,
    Box,
    CollisionContext
  }

  alias Valimc.World.View

  defp view(box, overrides \\ %{}, default \\ 0) do
    {:ok, plan} = BlockScan.plan(box)
    View.of(Map.new(plan, fn {pos, _} -> {pos, Map.get(overrides, pos, default)} end))
  end

  @box {0.2, 0.2, 0.2, 1.8, 1.8, 1.8}

  test "colliders come in scan order; a cell the view cannot read is an error" do
    v = view(@box, %{{0, 0, 0} => 1, {1, 0, 0} => 1, {0, 1, 1} => 1})
    assert {:ok, result} = BlockCollisions.collect(@box, v)
    assert Enum.map(result.colliders, & &1.position) == [{0, 0, 0}, {1, 0, 0}, {0, 1, 1}]
    pos = {0, 0, 0}

    assert {:error, {:missing_block, ^pos}} =
             BlockCollisions.collect(@box, %{v | supplied: Map.delete(v.supplied, pos)})

    assert {:error, :unknown_block_state} =
             BlockCollisions.collect(@box, %{v | supplied: Map.put(v.supplied, pos, 35_723)})
  end

  test "candidate and collider limits fail without partial results" do
    large = {0.2, 0.2, 0.2, 5.8, 5.8, 5.8}
    assert {:error, :collider_limit} = BlockCollisions.collect(large, view(large, %{}, 1))

    assert {:error, :block_scan_limit} =
             BlockCollisions.collect({0, 0, 0, 10, 10, 10}, View.of(%{}))
  end

  test "one view serves every context; dynamic geometry resolves afresh each time" do
    v = view(@box, %{{0, 0, 0} => 30519})
    empty = CollisionContext.empty()
    falling = CollisionContext.entity(0.2) |> CollisionContext.with_entity(3.0, false, false)
    assert {:ok, %{colliders: []}} = BlockCollisions.collect(@box, v, empty)
    assert {:ok, %{colliders: [collider]}} = BlockCollisions.collect(@box, v, falling)
    assert collider.shape.boxes == [{0.0, 0.0, 0.0, 1.0, 0.8999999761581421, 1.0}]
    assert {:ok, %{colliders: []}} = BlockCollisions.collect(@box, v, empty)

    assert {:error, {:missing_block, _}} =
             BlockCollisions.collect(Box.move(@box, {4, 0, 0}), v, empty)

    assert {:error, :invalid_context} = BlockCollisions.collect(@box, v, :bad)
  end
end
