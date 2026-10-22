defmodule Valimc.BlockSnapshotTest do
  @moduledoc """
  Published chunk snapshots (VMC-077p) read what the owner's store held when
  they were taken, whatever the store writes afterwards: states one at a time
  and in batches, searches, the highest filled section and column heights.
  """
  use ExUnit.Case, async: true
  alias Valimc.Native
  alias Valimc.Registry.BlockFacts
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.World.Blocks

  test "a snapshot reads as the store did when it was published" do
    {:ok, blocks} = Blocks.new({0, 0})
    stone = BlockRegistry.default_state("stone")
    glass = BlockRegistry.default_state("glass")
    # 300 distinct states make the section at y 96..111 dense.
    varied =
      Map.new(0..299, fn i -> {{rem(i, 16), 100 + div(i, 256), rem(div(i, 16), 16)}, i + 1} end)

    :ok = Blocks.put(blocks, Map.merge(varied, %{{1, 70, 2} => stone, {3, 200, 4} => glass}))
    [snapshot] = Blocks.snapshots(blocks, [{{0, 0}, nil}], 1)

    positions =
      for x <- [0, 1, 3, 15],
          y <- [-64, 63, 64, 70, 100, 101, 200, 319],
          z <- [0, 2, 4, 15],
          do: {x, y, z}

    stored = Blocks.get_many(blocks, positions)
    packed = for {x, y, z} <- positions, into: <<>>, do: <<x::32, y::32-signed, z::32>>
    read = for <<state::16 <- Native.snapshot_blocks([snapshot], packed, 0)>>, do: state
    assert read == Enum.map(positions, &stored[&1])
    assert Native.snapshot_get(snapshot, 1, 70, 2) == stone
    assert Native.snapshot_get(snapshot, 1, 320, 2) == nil
    # A chunk no handle holds reads as unreadable.
    assert Native.snapshot_blocks([snapshot], <<16::32, 0::32, 0::32>>, 0) == <<0xFFFF::16>>

    {:ok, found} = Native.chunk_find(blocks.ref, 0, 0, [stone, glass])
    assert Native.snapshot_find(snapshot, [stone, glass]) == found
    assert Native.snapshot_highest_filled(snapshot, 24) == {:ok, div(200 + 64, 16)}
    assert Native.snapshot_highest_filled(snapshot, div(200 + 64, 16)) == {:ok, div(101 + 64, 16)}

    for {x, z} <- [{1, 2}, {3, 4}, {15, 15}] do
      motion =
        Enum.find(
          319..-64//-1,
          &BlockFacts.heightmap?(Blocks.get(blocks, {x, &1, z}), :motion_blocking)
        )

      height = (motion || -65) + 1
      assert {:ok, {^height, _sky}} = Native.snapshot_column(snapshot, x, z)
    end

    # The store writes past the snapshot; republishing renews that section only.
    :ok = Blocks.put(blocks, %{{1, 70, 2} => glass})
    assert Native.snapshot_get(snapshot, 1, 70, 2) == stone
    [again] = Blocks.snapshots(blocks, [{{0, 0}, snapshot}], 2)
    assert Native.snapshot_get(again, 1, 70, 2) == glass
    written = div(70 + 64, 16)
    {2, revisions} = Native.snapshot_revisions(again)
    assert revisions == List.replace_at(List.duplicate(1, 24), written, 2)
  end
end
