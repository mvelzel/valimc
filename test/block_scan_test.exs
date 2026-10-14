defmodule Valimc.BlockScanTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{BlockScan, Box}
  alias Valimc.Protocol.Data

  test "native cursor is X-fastest, classifies boundaries and skips corners" do
    assert {:ok, positions} = BlockScan.plan({0.2, 0.2, 0.2, 0.8, 0.8, 0.8})
    assert length(positions) == 19
    assert Enum.take(positions, 3) == [{{0, -1, -1}, 2}, {{-1, 0, -1}, 2}, {{0, 0, -1}, 1}]
    assert {{0, 0, 0}, 0} in positions
    refute Enum.any?(positions, fn {_, type} -> type == 3 end)
  end

  test "face candidates retain protruding fences and edges retain only moving pistons" do
    fence = Data.item_block(Data.item("oak_fence"))
    assert {:ok, true} = BlockScan.eligible(fence, 1)
    assert {:ok, false} = BlockScan.eligible(fence, 2)
    assert {:ok, false} = BlockScan.eligible(1, 1)
    assert {:ok, true} = BlockScan.eligible(1, 0)
    for id <- 3801..3812, do: assert(BlockScan.eligible(id, 2) == {:ok, true})
    assert {:ok, false} = BlockScan.eligible(:unread, 3)
  end

  test "negative coordinates and an exact integer expand both sides with native epsilon" do
    {:ok, positions} = BlockScan.plan({0.0, 0.0, 0.0, 1.0, 1.0, 1.0})
    assert {{-2, 0, 0}, 1} in positions and {{2, 0, 0}, 1} in positions
    {:ok, shifted} = BlockScan.plan(Box.move({0.2, 0.2, 0.2, 0.8, 0.8, 0.8}, {-17, 64, 17}))
    assert {{-17, 64, 17}, 0} in shifted
  end

  test "raw volume is bounded before candidate allocation, including corners" do
    assert {:ok, positions} = BlockScan.plan({0.2, 0.2, 0.2, 5.8, 5.8, 5.8})
    assert length(positions) == 504
    assert {:error, :block_scan_limit} = BlockScan.plan({0.2, 0.2, 0.2, 6.8, 5.8, 5.8})
    assert {:error, :block_scan_limit} = BlockScan.plan({-60_000_000, 0, 0, 60_000_000, 1, 1})

    for box <- [nil, {1, 0, 0, -1, 1, 1}, {0, 0, 0, 60_000_001, 1, 1}, {0, 0, 0, :bad, 1, 1}],
        do: assert(BlockScan.plan(box) == {:error, :invalid_box})
  end

  test "unknown state and boundary types stay errors" do
    for id <- [-1, 35_723, nil, "1"],
        type <- 0..2,
        do: assert(BlockScan.eligible(id, type) == {:error, :unknown_block_state})

    for type <- [-1, 4, :bad, nil],
        do: assert(BlockScan.eligible(1, type) == {:error, :invalid_boundary_type})
  end
end
