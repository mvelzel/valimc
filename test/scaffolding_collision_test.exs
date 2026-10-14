defmodule Valimc.ScaffoldingCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockShapes, Box, Collision, CollisionContext, Shape}
  @pos {0, 64, 0}
  @epsilon 9.999999747378752e-6

  test "explicit empty context resolves all scaffolding states without guessing other families" do
    context = CollisionContext.empty()
    results = Enum.map(0..(BlockShapes.state_count() - 1), &BlockShapes.fetch(&1, @pos, context))
    assert Enum.count(results, &match?({:ok, %Shape{}}, &1)) == 35_608
    assert Enum.count(results, &match?({:context_required, _}, &1)) == 115
    assert {:context_required, "minecraft:scaffolding"} = BlockShapes.fetch(24063, @pos)
    {:ok, stable} = BlockShapes.fetch(24063, @pos, context)

    for id <- 24063..24094,
        do: assert(BlockShapes.fetch(id, @pos, context) == {:ok, stable})

    assert BlockShapes.fetch(30519, @pos, context) == {:context_required, "minecraft:powder_snow"}
    assert BlockShapes.fetch(35_723, @pos, context) == {:error, :unknown_block_state}
    assert CollisionContext.above?(context, 1.0, 64, true)
    refute CollisionContext.above?(context, 1.0, 64, false)
  end

  test "landing uses the stable platform while descending a supported block removes collision" do
    {:ok, stable} = BlockShapes.fetch(24063, @pos, CollisionContext.entity(65.1))
    world = Shape.move(stable, @pos)
    box = Box.new({0.2, 65.1, 0.2, 0.8, 66.9, 0.8})
    assert Collision.clip(:y, box, [world], -2.0) == 65.0 - 65.1
    {:ok, empty} = BlockShapes.fetch(24063, @pos, CollisionContext.entity(65.1, true))
    assert Shape.empty?(empty)
    assert Collision.clip(:y, box, [Shape.move(empty, @pos)], -2.0) == -2.0

    for id <- 24063..24094 do
      assert {:ok, placement} =
               BlockShapes.fetch(id, @pos, CollisionContext.entity(65.1, false, true))

      assert Shape.empty?(placement)
    end
  end

  test "unsupported bottom plate depends on distance, bottom property and lower height boundary" do
    {:ok, bottom} = BlockShapes.fetch(24065, @pos, CollisionContext.entity(64.5, true))
    assert bottom.boxes == [{0.0, 0.0, 0.0, 1.0, 0.125, 1.0}]
    assert {:ok, ^bottom} = BlockShapes.fetch(24065, @pos, CollisionContext.entity(64.5))

    for {id, height} <- [{24063, 64.5}, {24081, 64.5}, {24065, 64.0 - @epsilon}] do
      {:ok, shape} = BlockShapes.fetch(id, @pos, CollisionContext.entity(height))
      assert Shape.empty?(shape)
    end

    assert {:ok, ^bottom} =
             BlockShapes.fetch(24065, @pos, CollisionContext.entity(64.0 - @epsilon + 1.0e-12))
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
