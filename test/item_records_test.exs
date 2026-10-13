defmodule Valimc.ItemRecordsTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{ItemRecords, Items}
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}

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

  defp seal(payload), do: payload <> :crypto.hash(:sha256, payload)

  defp file(count, body, version \\ 1, data \\ 5023),
    do: seal(<<"VMCITEMS", version, data::32, -1::signed-32, -1::signed-32, count::16>> <> body)

  test "file recovery preserves UUID, position and patched stacks with fresh runtime identities" do
    records = [record()]
    assert {:ok, bytes} = ItemRecords.encode({-1, -1}, records)
    assert {:ok, ^records} = ItemRecords.decode(bytes, {-1, -1})
    assert {:ok, first} = Items.restore({-1, -1}, records)
    assert {:ok, second} = Items.restore({-1, -1}, records)
    assert first.epoch != second.epoch
    assert Map.keys(first.entries) != Map.keys(second.entries)
    assert Items.records(first) == records and Items.records(second) == records
    assert {:ok, {epoch, _, 1}} = Items.find(second, record().uuid)
    assert epoch == second.epoch
    assert {:error, :missing_item} = Items.find(second, <<0::128>>)
    assert {:error, :invalid_item_uuid} = Items.find(second, <<0>>)
    assert {:ok, empty} = ItemRecords.encode({-1, -1}, [])
    assert byte_size(empty) == 55 and ItemRecords.decode(empty, {-1, -1}) == {:ok, []}
  end

  test "malformed and checksummed invalid records never partially load" do
    {:ok, bytes} = ItemRecords.encode({-1, -1}, [record()])
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    <<_header::binary-size(23), body::binary>> = payload
    prefix = <<record().uuid::binary-size(16), -0.5::float-64, 64.25::float-64, -128.0::float-64>>

    unsupported =
      [
        <<1>>,
        Wire.varint(ItemTypes.id("stone")),
        <<1, 0>>,
        Wire.varint(ItemTypes.component_id("minecraft:custom_name")),
        <<0>>
      ]
      |> IO.iodata_to_binary()

    for bad <- [
          "bad",
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          payload <> <<0::256>>,
          file(1, body, 2),
          file(1, body, 1, 5024),
          file(257, <<>>),
          file(1, <<>>),
          file(0, body),
          file(2, body <> body),
          file(1, prefix <> <<0>>),
          file(1, prefix <> unsupported),
          file(1, prefix <> Wire.varint(100)),
          file(
            1,
            <<record().uuid::binary-size(16), 0.5::float-64, 64.0::float-64, 0.5::float-64, 0>>
          ),
          :binary.copy(<<0>>, ItemRecords.max_bytes() + 1)
        ] do
      assert {:error, :invalid_item_file} = ItemRecords.decode(bad, {-1, -1})
    end

    assert {:error, :invalid_item_file} = ItemRecords.decode(bytes, {0, 0})
    assert {:error, :invalid_item_file} = Items.restore({0, 0}, [record()])
    assert {:error, :invalid_item_file} = Items.restore({-1, -1}, [record(), record()])
  end

  test "encoding and recovery enforce bounded counts, bytes and supported owned state" do
    for bad <- [
          [record(), record()],
          [%{record() | uuid: <<0>>}],
          [%{record() | x: 0.5}],
          [%{record() | y: 1.0e100}],
          [%{record() | stack: nil}],
          [%{record() | stack: ItemStack.new("air")}]
        ] do
      assert {:error, :invalid_item_records} = ItemRecords.encode({-1, -1}, bad)
    end

    large = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"data" => {:byte_array, :binary.copy(<<12>>, 60_000)}}}
        }
    }

    records = for n <- 1..9, do: %{record() | uuid: <<n::128>>, stack: large}
    assert {:error, :invalid_item_records} = ItemRecords.encode({-1, -1}, records)
    assert {:error, :invalid_item_file} = Items.restore({-1, -1}, records)
    legal = Enum.take(records, 8)
    assert {:ok, bytes} = ItemRecords.encode({-1, -1}, legal)
    assert {:ok, ^legal} = ItemRecords.decode(bytes, {-1, -1})
    many = for n <- 1..257, do: %{record() | uuid: <<n::128>>}
    assert {:error, :invalid_item_records} = ItemRecords.encode({-1, -1}, many)
    assert {:error, :invalid_item_file} = Items.restore({-1, -1}, many)
    assert {:ok, _} = ItemRecords.encode({-1, -1}, Enum.take(many, 256))
  end
end
