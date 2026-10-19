defmodule Valimc.ShulkerCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, CollisionContext}
  @pos {0, 64, 0}
  @states BlockShapes.entries()
          |> Tuple.to_list()
          |> Enum.with_index()
          |> Enum.filter(fn {name, _} ->
            is_binary(name) and String.ends_with?(name, "shulker_box")
          end)
          |> Enum.map(&elem(&1, 1))
  @up 16849

  defp shape(id, context) do
    {:ok, result} = BlockShapes.fetch(id, @pos, CollisionContext.empty(), context)
    result
  end

  test "all colors and facings require explicit authoritative block-entity observations" do
    assert length(@states) == 102

    for id <- @states do
      assert {:context_required, name} = BlockShapes.fetch(id, @pos, CollisionContext.empty())

      assert BlockShapes.fetch(
               id,
               @pos,
               CollisionContext.empty(),
               BlockEntityContext.unavailable()
             ) ==
               {:context_required, name}

      full = shape(id, BlockEntityContext.absent())
      assert full.boxes == [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
      assert shape(id, BlockEntityContext.other()) == full
      assert shape(id, BlockEntityContext.shulker(0, 0)) == full
    end
  end

  test "invalid contexts reject and unavailable snapshots do not interfere with independent shapes" do
    for invalid <- [
          nil,
          %{},
          %BlockEntityContext{kind: :unknown},
          %BlockEntityContext{kind: :shulker, progress: "1"},
          %BlockEntityContext{kind: :shulker, progress: 1.1},
          %BlockEntityContext{kind: :absent, progress: 0.5}
        ] do
      refute BlockEntityContext.valid?(invalid)

      assert BlockShapes.fetch(@up, @pos, CollisionContext.empty(), invalid) ==
               {:error, :invalid_block_entity_context}
    end

    assert {:ok, _} =
             BlockShapes.fetch(
               0,
               @pos,
               CollisionContext.empty(),
               BlockEntityContext.unavailable()
             )

    assert BlockShapes.fetch(
             @up,
             {0.0, 64, 0},
             CollisionContext.empty(),
             BlockEntityContext.absent()
           ) ==
             {:error, :invalid_position}

    assert BlockShapes.fetch(@up, @pos, nil, BlockEntityContext.absent()) ==
             {:error, :invalid_context}

    assert_raise ArgumentError, fn -> BlockEntityContext.shulker(-0.1, 0) end
    assert_raise ArgumentError, fn -> BlockEntityContext.shulker(0, false) end
  end
end
