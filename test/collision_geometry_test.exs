defmodule Valimc.CollisionGeometryTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockShapes, Box, Collision, Shape}
  alias Valimc.Protocol.Data

  defp shape(name) do
    {:ok, shape} = BlockShapes.fetch(Data.item_block(Data.item(name)))
    shape
  end

  test "every native state is cached or explicitly contextual; unknown IDs cannot become air" do
    assert BlockShapes.state_count() == 35_723
    assert BlockShapes.shape_count() == 330
    statuses = Enum.map(0..(BlockShapes.state_count() - 1), &BlockShapes.fetch/1)
    assert Enum.count(statuses, &match?({:ok, %Shape{}}, &1)) == 35_524
    assert Enum.count(statuses, &match?({:context_required, _}, &1)) == 199

    for id <- [-1, 35_723, nil, "1"],
        do: assert(BlockShapes.fetch(id) == {:error, :unknown_block_state})

    # Native state IDs, including blocks without corresponding inventory items.
    for {id, name} <- [
          {30519, "powder_snow"},
          {24094, "scaffolding"},
          {3801, "moving_piston"},
          {16849, "shulker_box"},
          {18636, "bamboo"},
          {33571, "pointed_dripstone"},
          {33591, "sulfur_spike"}
        ] do
      assert BlockShapes.fetch(id) == {:context_required, "minecraft:" <> name}
    end
  end

  test "slab variants, stairs and fences retain their actual geometry and out-of-unit height" do
    assert shape("stone").boxes == [{0.0, 0.0, 0.0, 1.0, 1.0, 1.0}]
    assert shape("oak_slab").boxes == [{0.0, 0.0, 0.0, 1.0, 0.5, 1.0}]
    {:ok, top} = BlockShapes.fetch(15178)
    assert top.boxes == [{0.0, 0.5, 0.0, 1.0, 1.0, 1.0}]
    {:ok, double} = BlockShapes.fetch(15182)
    assert double == shape("stone")
    assert length(shape("oak_stairs").boxes) == 2
    assert Enum.any?(shape("oak_fence").boxes, &(elem(&1, 4) == 1.5))
    {:ok, air} = BlockShapes.fetch(0)
    assert Shape.empty?(air) and air.boxes == []
  end

  test "clip stops at full-block contact, respects perpendicular contact and preserves overlap" do
    stone = shape("stone")
    box = Box.new({-1.0, 0.0, 0.0, -0.4, 1.8, 0.6})
    assert Collision.clip(:x, box, [stone], 1.0) == 0.4
    assert Collision.clip(:x, box, [stone], -1.0) == -1.0
    shifted = Shape.move(stone, {-3, -5, 9})
    assert shifted.bits == stone.bits

    assert Collision.clip(:x, Box.move(box, {-3, -5, 9}), [shifted], 1.0) ==
             -3.0 - (-0.4 - 3.0)

    assert Collision.clip(:x, Box.move(box, {0, 1, 0}), [stone], 1.0) == 1.0
    inside = Box.new({0.2, 0.2, 0.2, 0.8, 0.8, 0.8})
    assert Shape.collide(stone, :x, inside, 1.0) == 1.0
    falling = Box.new({0.2, 1.0, 0.2, 0.8, 2.8, 0.8})
    assert Collision.clip(:y, falling, [shape("oak_slab")], -2.0) == -0.5
  end

  test "native tiny-delta ordering distinguishes empty lists, raw empty shapes and list clipping" do
    {:ok, air} = BlockShapes.fetch(0)
    stone = shape("stone")
    box = Box.new({-1, 0, 0, -0.4, 1.8, 0.6})
    assert Shape.collide(air, :x, box, -1.0e-8) == -1.0e-8
    assert Collision.clip(:x, box, [], -1.0e-8) == -1.0e-8
    assert Collision.clip(:x, box, [air], -1.0e-8) == 0.0
    assert Shape.collide(stone, :x, box, -1.0e-8) == 0.0
    assert <<Shape.collide(air, :x, box, -0.0)::float-64>> == <<0x8000000000000000::64>>
    assert <<Shape.collide(stone, :x, box, -0.0)::float-64>> == <<0::64>>
  end

  test "invalid grid facts and unbounded jobs reject before geometry is used" do
    good = %{
      "axes" => [[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]],
      "sizes" => [1, 1, 1],
      "bits" => "01",
      "boxes" => [[0.0, 0.0, 0.0, 1.0, 1.0, 1.0]],
      "full_block" => true
    }

    assert Shape.from_facts!(good) == shape("stone")

    for bad <- [
          Map.put(good, "sizes", [33, 1, 1]),
          Map.put(good, "bits", "ff"),
          Map.put(good, "bits", ""),
          Map.put(good, "bits", "00"),
          Map.put(good, "axes", [[1.0, 0.0], [0.0, 1.0], [0.0, 1.0]]),
          Map.put(good, "boxes", List.duplicate(good["boxes"] |> hd(), 65))
        ] do
      assert_raise ArgumentError, fn -> Shape.from_facts!(bad) end
    end

    box = Box.new({0, 0, 0, 1, 1, 1})

    assert_raise ArgumentError, fn ->
      Collision.clip(:x, box, List.duplicate(shape("stone"), 129), 1.0)
    end

    assert_raise ArgumentError, fn -> Collision.clip(:x, box, [], 65.0) end
    assert_raise ArgumentError, fn -> Shape.move(shape("stone"), {30_000_001, 0, 0}) end

    assert_raise ArgumentError, fn ->
      "[\"nan\",0,0,1,1,1]" |> JSON.decode!() |> List.to_tuple() |> Box.new()
    end
  end

  test "native box intersections exclude touching faces and normalize reversed corners" do
    a = Box.new({1, 1, 1, 0, 0, 0})
    assert a == {0.0, 0.0, 0.0, 1.0, 1.0, 1.0}
    refute Box.intersects?(a, Box.new({1, 0, 0, 2, 1, 1}))
    assert Box.intersects?(a, Box.new({0.99999999, 0, 0, 2, 1, 1}))
  end
end
