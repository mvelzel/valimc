defmodule Valimc.BlockOffsetTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockOffset, BlockShapes, Shape}

  test "position resolves exactly the 52 supported states and preserves other contexts" do
    results = Enum.map(0..(BlockShapes.state_count() - 1), &BlockShapes.fetch(&1, {0, 64, 0}))
    assert Enum.count(results, &match?({:ok, %Shape{}}, &1)) == 35_576
    assert Enum.count(results, &match?({:context_required, _}, &1)) == 147

    for id <- [18636, 33571, 33591] do
      assert {:context_required, _} = BlockShapes.fetch(id)
      assert {:ok, _} = BlockShapes.fetch(id, {0, 64, 0})
    end

    for id <- [30519, 24094, 3801, 16849],
        do: assert(BlockShapes.fetch(id, {0, 64, 0}) == BlockShapes.fetch(id))

    assert BlockShapes.fetch(35_723, {0, 64, 0}) == {:error, :unknown_block_state}
    assert BlockShapes.fetch("1", {0, 64, 0}) == {:error, :unknown_block_state}
  end

  test "native overflow and float promotion produce exact offset golden values" do
    for {position, expected} <- [
          {{687, -64, 1}, {0.18333333730697632, 0.0, -0.04999999701976776}},
          {{-687, -64, 1}, {-0.21666666492819786, 0.0, -0.14999999850988388}},
          {{30_000_000, -64, 30_000_000}, {-0.04999999701976776, 0.0, 0.11666667461395264}},
          {{-30_000_000, -64, -30_000_000}, {-0.04999999701976776, 0.0, 0.11666667461395264}},
          {{1, -64, 1}, {-0.0833333283662796, 0.0, -0.0833333283662796}}
        ] do
      assert BlockOffset.horizontal(position, 0.25) == expected
    end

    assert BlockOffset.horizontal({0, 64, 0}, 0.25) == {-0.25, 0.0, -0.25}
    assert BlockOffset.horizontal({0, 64, 0}, 0.125) == {-0.125, 0.0, -0.125}
  end

  test "local geometry shares occupied cells, ignores column height and keeps narrower clamp" do
    {:ok, bamboo} = BlockShapes.fetch(18636, {0, 64, 0})
    assert {:ok, ^bamboo} = BlockShapes.fetch(18636, {0, 65, 0})
    assert {:ok, ^bamboo} = BlockShapes.fetch(18647, {0, -384, 0})
    assert bamboo.boxes == [{0.15625, 0.0, 0.15625, 0.34375, 1.0, 0.34375}]
    {:ok, shifted} = BlockShapes.fetch(18636, {687, 64, 1})
    assert shifted.bits == bamboo.bits and shifted.sizes == bamboo.sizes
    assert shifted.boxes != bamboo.boxes

    {:ok, stone} = BlockShapes.fetch(1)
    assert {:ok, ^stone} = BlockShapes.fetch(1, {1_000_000, 64, -1_000_000})
    assert BlockOffset.horizontal({687, 100, 1}, 0.125) == {0.125, 0.0, -0.04999999701976776}
  end

  test "invalid coordinates reject even for cached or unknown states" do
    for position <- [
          nil,
          {0, 0},
          {0.0, 64, 0},
          {0, "64", 0},
          {30_000_001, 64, 0},
          {0, -1_000_001, 0},
          {0, 64, -30_000_001}
        ],
        id <- [0, 18636, 35_723] do
      refute BlockOffset.valid_position?(position)
      assert BlockShapes.fetch(id, position) == {:error, :invalid_position}
    end

    for limit <- [-0.1, 0.251, "0.25", nil],
        do: assert_raise(ArgumentError, fn -> BlockOffset.horizontal({0, 64, 0}, limit) end)
  end
end
