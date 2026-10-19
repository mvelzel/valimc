defmodule Valimc.BlockScanTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.BlockScan
  alias Valimc.Protocol.Data

  test "face candidates retain protruding fences and edges retain only moving pistons" do
    fence = Data.item_block(Data.item("oak_fence"))
    assert {:ok, true} = BlockScan.eligible(fence, 1)
    assert {:ok, false} = BlockScan.eligible(fence, 2)
    assert {:ok, false} = BlockScan.eligible(1, 1)
    assert {:ok, true} = BlockScan.eligible(1, 0)
    for id <- 3801..3812, do: assert(BlockScan.eligible(id, 2) == {:ok, true})
    assert {:ok, false} = BlockScan.eligible(:unread, 3)
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

  test "combined simulation frames have a distinct bounded envelope" do
    box = {0.2, 0.2, 0.2, 6.8, 5.8, 5.8}
    assert {:error, :block_scan_limit} == BlockScan.plan(box)
    assert {:ok, positions} = BlockScan.plan(box, 1024)
    assert length(positions) < 1024
    assert {:error, :block_scan_limit} == BlockScan.plan({0.2, 0.2, 0.2, 10.8, 10.8, 10.8}, 1024)
    assert {:error, :block_scan_limit} == BlockScan.plan(box, 2048)
  end
end
