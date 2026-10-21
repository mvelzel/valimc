defmodule Valimc.PistonCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext, PistonSnapshot, Shape}
  @moving 3809
  @pos {0, 64, 0}
  test "a moving piston without its block entity has no collision, as in vanilla" do
    for id <- [@moving] do
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
end
