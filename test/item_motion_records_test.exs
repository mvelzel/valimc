defmodule Valimc.ItemMotionRecordsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.ItemRecords
  @key {-1, -1}
  @source <<19::128>>
  @receipts %{@source => %{sequence: 1, digest: <<23::256>>}}

  defp record(n \\ 37),
    do: %{uuid: <<n::128>>, x: -0.5, y: 64.25, z: -128.0, stack: ItemStack.new("stone", 7)}

  test "legacy v1/v2 bytes retain the pre-motion checkpoint hashes used by receipts" do
    for {receipts, hash} <- [
          {%{}, "b4265dc7cf297772bd43d2687007c71029e3d871e8ab190591427585572e1556"},
          {@receipts, "c82a4c3f3eccfae6fb5f6a8113faffc2d0fbe0f1dd40401c9d3552644e9d05ad"}
        ] do
      assert {:ok, bytes} = ItemRecords.encode(@key, [record()], receipts)
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
      assert ItemRecords.decode(bytes, @key) == {:ok, %{records: [record()], receipts: receipts}}
    end
  end
end
