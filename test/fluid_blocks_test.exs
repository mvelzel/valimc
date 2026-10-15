defmodule Valimc.Physics.FluidBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FluidBlocks

  test "empty fluid, water source and lava keep distinct scalar observations" do
    assert {:ok, empty} = FluidBlocks.fetch(0)
    assert empty === %{kind: :empty, amount: 0, height: 0.0, source: false, falling: false}

    assert {:ok, water} = FluidBlocks.fetch(89)
    assert water.kind == :water and water.source and water.amount == 8
    assert water.height == 0.8888888955116272 and not water.falling
    assert {:ok, lava} = FluidBlocks.fetch(105)
    assert lava.kind == :lava and lava.source and lava.height == water.height
  end

  test "waterlogged slab scalar facts differ from its dry state" do
    assert {:ok, %{kind: :empty}} = FluidBlocks.fetch(15180)
    assert {:ok, %{kind: :water, source: true, amount: 8}} = FluidBlocks.fetch(15179)
  end

  test "only bounded registered state identities have fluid facts" do
    assert FluidBlocks.count() == 35_723
    assert {:ok, _} = FluidBlocks.fetch(35_722)

    for invalid <- [-1, 35_723, 0.0, nil],
        do: assert({:error, :unknown_block_state} == FluidBlocks.fetch(invalid))
  end
end
