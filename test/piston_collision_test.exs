defmodule Valimc.PistonCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext, PistonSnapshot, Shape}
  @moving 3809
  @pos {0, 64, 0}
  defp shape(snapshot, exclusion \\ nil) do
    c = CollisionContext.with_piston_movement(CollisionContext.empty(), exclusion)
    {:ok, result} = BlockShapes.fetch(@moving, @pos, c, BlockEntityContext.piston(snapshot))
    result
  end

  test "all moving states distinguish unavailable, absent and incompatible block entities" do
    for id <- 3801..3812 do
      assert {:context_required, "minecraft:moving_piston"} =
               BlockShapes.fetch(
                 id,
                 @pos,
                 CollisionContext.empty(),
                 BlockEntityContext.unavailable()
               )

      for c <- [
            BlockEntityContext.absent(),
            BlockEntityContext.other(),
            BlockEntityContext.shulker(1, 1)
          ] do
        {:ok, empty} = BlockShapes.fetch(id, @pos, CollisionContext.empty(), c)
        assert Shape.empty?(empty)
      end
    end

    snapshot = PistonSnapshot.new(1, :up, true, false, 0.5)

    {:ok, other_type} =
      BlockShapes.fetch(
        16849,
        @pos,
        CollisionContext.empty(),
        BlockEntityContext.piston(snapshot)
      )

    assert other_type.boxes == [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
  end

  test "ordinary blocks move in opposite directions for extension and retraction" do
    extending = shape(PistonSnapshot.new(1, :up, true, false, 0.5))
    retracting = shape(PistonSnapshot.new(1, :up, false, false, 0.5))
    assert extending.boxes == [{0.0, -0.5, 0.0, 1.0, 0.5, 1.0}]
    assert retracting.boxes == [{0.0, 0.5, 0.0, 1.0, 1.5, 1.0}]

    assert shape(PistonSnapshot.new(1, :up, true, false, 1)).boxes == [
             {0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
           ]
  end

  test "movement exclusions are caller-local, direction-specific and stop at progress one" do
    p = PistonSnapshot.new(1, :up, true, false, 0.5)
    assert Shape.empty?(shape(p, :up))
    refute Shape.empty?(shape(p, :down))
    refute Shape.empty?(shape(p))
    retract = PistonSnapshot.new(1, :up, false, false, 0.5)
    assert Shape.empty?(shape(retract, :down))
    refute Shape.empty?(shape(PistonSnapshot.new(1, :up, true, false, 1), :up))
  end

  test "retracting sources retain the stationary extended base while excluding the moving head" do
    p = PistonSnapshot.new(2383, :up, false, true, 0.5)
    base = shape(p, :down)
    assert base.boxes == [{0.0, 0.0, 0.0, 1.0, 0.75, 1.0}]
    full = shape(p)
    assert Enum.any?(full.boxes, fn {_, _, _, _, y, _} -> y == 1.5 end)

    assert shape(PistonSnapshot.new(2383, :up, false, true, 1)).boxes == [
             {0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
           ]
  end

  test "moved dynamic blocks use native empty/entity-type defaults" do
    assert Shape.empty?(shape(PistonSnapshot.new(30519, :up, true, false, 0.5)))
    shulker = shape(PistonSnapshot.new(16849, :up, true, false, 0.5))
    assert shulker.boxes == [{0.0, -0.5, 0.0, 1.0, 0.5, 1.0}]
    scaffold = shape(PistonSnapshot.new(24063, :up, true, false, 0.5))
    refute Shape.empty?(scaffold)
  end

  test "invalid or recursive observations reject before geometry is queried" do
    p = PistonSnapshot.new(1, :up, true, false, 0.1)
    assert p.progress == 0.10000000149011612

    for invalid <- [
          %{p | moved_state: -1},
          %{p | moved_state: 35723},
          %{p | moved_state: @moving},
          %{p | direction: :diagonal},
          %{p | progress: "0.1"},
          %{p | source: 1}
        ] do
      refute PistonSnapshot.valid?(invalid)
      assert_raise ArgumentError, fn -> BlockEntityContext.piston(invalid) end
    end

    assert_raise ArgumentError, fn -> PistonSnapshot.new(@moving, :up, true, false, 0.5) end
    assert_raise ArgumentError, fn -> PistonSnapshot.new(1, :up, true, false, false) end

    assert_raise ArgumentError, fn ->
      CollisionContext.with_piston_movement(CollisionContext.empty(), :diagonal)
    end

    invalid = %{CollisionContext.empty() | piston_movement: "up"}
    refute CollisionContext.valid?(invalid)

    assert BlockShapes.fetch(@moving, @pos, invalid, BlockEntityContext.absent()) ==
             {:error, :invalid_context}
  end
end
