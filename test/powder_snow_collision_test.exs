defmodule Valimc.PowderSnowCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockShapes, Box, Collision, CollisionContext, Shape}
  @id 30519
  @pos {0, 64, 0}
  @epsilon 9.999999747378752e-6
  @falling_top 0.8999999761581421

  defp context(
         bottom,
         fall \\ 0.0,
         falling \\ false,
         walkable \\ false,
         descending \\ false,
         placement \\ false
       ) do
    CollisionContext.entity(bottom, descending, placement)
    |> CollisionContext.with_entity(fall, falling, walkable)
  end

  defp shape(c) do
    {:ok, result} = BlockShapes.fetch(@id, @pos, c)
    result
  end

  test "empty and absent entities pass through; placement suppresses every entity branch" do
    assert Shape.empty?(shape(CollisionContext.empty()))
    assert Shape.empty?(shape(CollisionContext.entity(65.0)))
    assert Shape.empty?(shape(context(65.0)))

    for fall <- [0.0, 10.0],
        falling <- [false, true],
        walkable <- [false, true],
        do: assert(Shape.empty?(shape(context(65.0, fall, falling, walkable, false, true))))

    assert {:context_required, "minecraft:powder_snow"} = BlockShapes.fetch(@id, @pos)

    piston =
      BlockShapes.entries()
      |> Tuple.to_list()
      |> Enum.find_index(&(&1 == "minecraft:moving_piston"))

    assert {:context_required, "minecraft:moving_piston"} =
             BlockShapes.fetch(piston, @pos, context(65.0))
  end

  test "fall distance is a strict double boundary with precedence over boots and falling blocks" do
    assert Shape.empty?(shape(context(65.0, 2.5)))
    falling = shape(context(65.0, 2.5 + 4.440892098500626e-16))
    assert falling.boxes == [{0.0, 0.0, 0.0, 1.0, @falling_top, 1.0}]

    for identity <- [false, true],
        walkable <- [false, true],
        descending <- [false, true],
        do: assert(shape(context(64.5, 10.0, identity, walkable, descending)) == falling)

    box = Box.new({0.2, 67.0, 0.2, 0.8, 68.8, 0.8})

    assert Collision.clip(:y, box, [Shape.move(falling, @pos)], -5.0) ==
             64.0 + @falling_top - 67.0
  end

  test "falling blocks collide fully even below the top or while descending" do
    for bottom <- [63.0, 64.5, 65.0], descending <- [false, true] do
      full = shape(context(bottom, 2.5, true, false, descending))
      assert full.boxes == [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
    end
  end

  test "walkable entities require feet above the strict epsilon boundary and no descent" do
    threshold = 65.0 - @epsilon
    assert Shape.empty?(shape(context(threshold, 0.0, false, true)))
    full = shape(context(threshold + 1.0e-12, 0.0, false, true))
    assert full.boxes == [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
    assert Shape.empty?(shape(context(65.0, 0.0, false, true, true)))
    assert Shape.empty?(shape(context(64.5, 0.0, false, true)))
  end

  test "invalid entity facts reject before lookup and factories normalize bounded numbers" do
    valid = context(65, 3)
    assert valid.fall_distance === 3.0

    for invalid <- [
          %{valid | fall_distance: "3"},
          %{valid | fall_distance: 60_000_001},
          %{valid | falling_block: 1},
          %{valid | powder_snow_walkable: nil},
          %{valid | entity_present: false},
          %{CollisionContext.empty() | entity_present: true},
          %{CollisionContext.empty() | powder_snow_walkable: true}
        ] do
      refute CollisionContext.valid?(invalid)
      assert BlockShapes.fetch(@id, @pos, invalid) == {:error, :invalid_context}
    end

    assert_raise ArgumentError, fn ->
      CollisionContext.with_entity(CollisionContext.empty(), 0.0, false, false)
    end

    assert_raise ArgumentError, fn ->
      CollisionContext.with_entity(CollisionContext.entity(65.0), "3", false, false)
    end
  end
end
