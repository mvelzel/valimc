defmodule Valimc.PowderSnowCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockShapes, CollisionContext, Shape}
  @id 30519
  @pos {0, 64, 0}

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
