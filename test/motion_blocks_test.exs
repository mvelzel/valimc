defmodule Valimc.Physics.MotionBlocksTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MotionBlocks

  test "native material coefficients distinguish ice, slime, honey and fluid" do
    assert {:ok, stone} = MotionBlocks.fetch(1)
    assert {:ok, ice} = MotionBlocks.fetch(8597)
    assert ice.friction > stone.friction
    assert {:ok, %{bounciness: 1.0, fluid_empty: true}} = MotionBlocks.fetch(14379)
    assert {:ok, honey} = MotionBlocks.fetch(25173)
    assert honey.speed_factor < 1 and honey.jump_factor < 1
    assert {:ok, %{fluid_empty: false}} = MotionBlocks.fetch(89)
  end

  test "catalog covers registry endpoints and rejects absent/noninteger states" do
    count = MotionBlocks.state_count()
    assert count == Valimc.Protocol.Data.block_state_count()
    assert {:ok, _} = MotionBlocks.fetch(0)
    assert {:ok, _} = MotionBlocks.fetch(count - 1)

    for id <- [-1, count, 1.0, :missing],
        do: assert(MotionBlocks.fetch(id) == {:error, :unknown_block_state})
  end
end
