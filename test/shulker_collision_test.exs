defmodule Valimc.ShulkerCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockEntityContext, BlockShapes, Box, Collision, CollisionContext, Shape}
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

  test "open lids expand along the state facing and upward contacts use the expanded top" do
    boxes =
      @states
      |> Enum.take(6)
      |> Enum.map(fn id ->
        shape(id, BlockEntityContext.shulker(1, 1)).boxes |> hd()
      end)
      |> MapSet.new()

    assert boxes ==
             MapSet.new([
               {0.0, -0.5, 0.0, 1.0, 1.0, 1.0},
               {0.0, 0.0, 0.0, 1.0, 1.5, 1.0},
               {0.0, 0.0, -0.5, 1.0, 1.0, 1.0},
               {0.0, 0.0, 0.0, 1.0, 1.0, 1.5},
               {-0.5, 0.0, 0.0, 1.0, 1.0, 1.0},
               {0.0, 0.0, 0.0, 1.5, 1.0, 1.0}
             ])

    opened = shape(@up, BlockEntityContext.shulker(1, 1))
    assert opened.boxes == [{0.0, 0.0, 0.0, 1.0, 1.5, 1.0}]
    box = Box.new({0.2, 67.0, 0.2, 0.8, 68.8, 0.8})
    assert Collision.clip(:y, box, [Shape.move(opened, @pos)], -5.0) == -1.5
  end

  test "native float interpolation retains old progress even at partial tick one" do
    interpolated = shape(@up, BlockEntityContext.shulker(1.0, 0.1))
    direct = shape(@up, BlockEntityContext.shulker(0.0, 0.1))
    refute interpolated == direct
    assert interpolated.boxes == [{0.0, 0.0, 0.0, 1.0, 1.050000011920929, 1.0}]
    normalized = BlockEntityContext.shulker(0.0, 0.1)
    assert normalized.progress == 0.10000000149011612
  end

  test "negligible lid extensions snap to the full cube while larger extensions retain bounds" do
    full = shape(@up, BlockEntityContext.absent())
    assert shape(@up, BlockEntityContext.shulker(0, 1.0e-8)) == full
    refute shape(@up, BlockEntityContext.shulker(0, 1.0e-5)) == full
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
