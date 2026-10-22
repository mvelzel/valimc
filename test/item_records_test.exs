defmodule Valimc.ItemRecordsTest do
  use ExUnit.Case, async: true
  alias Valimc.World.ItemRecords
  alias Valimc.Protocol.ItemStack

  defp record,
    do: %{
      uuid: <<37::128>>,
      x: -0.5,
      y: 64.25,
      z: -128.0,
      stack: %{
        ItemStack.new("stone", 7)
        | components: %{
            "minecraft:enchantment_glint_override" => true,
            "minecraft:custom_data" => {:compound, %{"persist" => {:string, "item"}}}
          },
          removed: MapSet.new(["minecraft:rarity"])
      }
    }

  test "version 2 stores bounded receipts and version 1 loads an empty inbox" do
    source = <<19::128>>
    receipt = %{sequence: 18_446_744_073_709_551_615, digest: <<23::256>>}
    receipts = %{source => receipt}

    assert {:ok, <<"VMCITEMS", 2, _::binary>> = bytes} =
             ItemRecords.encode({-1, -1}, [record()], receipts)

    assert {:ok, %{records: [restored], receipts: ^receipts}} =
             ItemRecords.decode(bytes, {-1, -1})

    assert restored == record()
    assert {:ok, old} = ItemRecords.encode({-1, -1}, [record()])
    assert ItemRecords.decode(old, {-1, -1}) == {:ok, %{records: [record()], receipts: %{}}}
    all = Map.new(1..4096, &{<<&1::128>>, receipt})
    assert {:ok, full} = ItemRecords.encode({-1, -1}, [], all)
    assert byte_size(full) == 57 + 4096 * 56
    assert {:ok, %{records: [], receipts: ^all}} = ItemRecords.decode(full, {-1, -1})

    for bad <- [
          %{source => %{receipt | sequence: 0}},
          %{source => %{receipt | sequence: 18_446_744_073_709_551_616}},
          %{source => %{receipt | digest: <<0>>}},
          %{<<0>> => receipt},
          []
        ],
        do: assert({:error, :invalid_item_records} == ItemRecords.encode({-1, -1}, [], bad))
  end
end
