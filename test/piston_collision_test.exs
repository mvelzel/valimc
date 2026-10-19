defmodule Valimc.PistonCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext, PistonSnapshot, Shape}
  @moving 3809
  @pos {0, 64, 0}
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
