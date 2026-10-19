defmodule Valimc.Physics.FluidBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.FluidBlocks

  test "only bounded registered state identities have fluid facts" do
    assert FluidBlocks.count() == 35_723
    assert {:ok, _} = FluidBlocks.fetch(35_722)

    for invalid <- [-1, 35_723, 0.0, nil],
        do: assert({:error, :unknown_block_state} == FluidBlocks.fetch(invalid))
  end
end
