defmodule Valimc.ScaffoldingCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockShapes, CollisionContext, Shape}
  @pos {0, 64, 0}
  @epsilon 9.999999747378752e-6

  test "explicit empty context resolves all scaffolding states without guessing other families" do
    context = CollisionContext.empty()
    results = Enum.map(0..(BlockShapes.state_count() - 1), &BlockShapes.fetch(&1, @pos, context))
    assert Enum.count(results, &match?({:ok, %Shape{}}, &1)) == 35_609
    assert Enum.count(results, &match?({:context_required, _}, &1)) == 114
    assert {:context_required, "minecraft:scaffolding"} = BlockShapes.fetch(24063, @pos)
    {:ok, stable} = BlockShapes.fetch(24063, @pos, context)

    for id <- 24063..24094,
        do: assert(BlockShapes.fetch(id, @pos, context) == {:ok, stable})

    assert {:ok, powder_snow} = BlockShapes.fetch(30519, @pos, context)
    assert Shape.empty?(powder_snow)
    assert BlockShapes.fetch(35_723, @pos, context) == {:error, :unknown_block_state}
    assert CollisionContext.above?(context, 1.0, 64, true)
    refute CollisionContext.above?(context, 1.0, 64, false)
  end

  test "above comparison is strict and uses promoted float epsilon, not decimal double epsilon" do
    threshold = 65.0 - @epsilon
    refute CollisionContext.above?(CollisionContext.entity(threshold), 1.0, 64, true)
    assert CollisionContext.above?(CollisionContext.entity(threshold + 1.0e-12), 1.0, 64, false)
    refute CollisionContext.above?(CollisionContext.entity(1.0 - 1.0e-5 + 1.0e-13), 1.0, 0, true)
    assert CollisionContext.entity(65).bottom === 65.0
  end

  test "malformed contexts or positions reject before any shape is published" do
    for context <- [
          nil,
          %{},
          %CollisionContext{descending: true},
          %CollisionContext{kind: :entity, bottom: "65"},
          %CollisionContext{kind: :entity, bottom: 60_000_001},
          %CollisionContext{kind: :entity, placement: 1}
        ],
        id <- [0, 24063, 35_723] do
      refute CollisionContext.valid?(context)
      assert BlockShapes.fetch(id, @pos, context) == {:error, :invalid_context}
    end

    assert BlockShapes.fetch(24063, {0.0, 64, 0}, CollisionContext.empty()) ==
             {:error, :invalid_position}

    assert_raise ArgumentError, fn -> CollisionContext.entity("65") end
    assert_raise ArgumentError, fn -> CollisionContext.entity(65, 1) end
  end
end
