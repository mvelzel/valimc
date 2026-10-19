defmodule Valimc.Physics.MotionBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MotionBlocks

  test "catalog covers registry endpoints and rejects absent/noninteger states" do
    count = MotionBlocks.state_count()
    assert count == Valimc.Protocol.Data.block_state_count()
    assert {:ok, _} = MotionBlocks.fetch(0)
    assert {:ok, _} = MotionBlocks.fetch(count - 1)

    for id <- [-1, count, 1.0, :missing],
        do: assert(MotionBlocks.fetch(id) == {:error, :unknown_block_state})
  end
end
