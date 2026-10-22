defmodule Valimc.NBTTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.NBT
  defp bytes(tag), do: IO.iodata_to_binary(NBT.encode(tag))

  test "all tag payloads, nested compounds/lists and dense primitive arrays round trip" do
    tag =
      {:compound,
       %{
         "byte" => {:byte, -128},
         "short" => {:short, -32768},
         "int" => {:int, -2_147_483_648},
         "long" => {:long, -9_223_372_036_854_775_808},
         "float" => {:float, <<0x7FC00000::32>>},
         "double" => {:double, <<0x7FF0000000000000::64>>},
         "bytes" => {:byte_array, <<0, 128, 255>>},
         "ints" => {:int_array, <<-1::signed-32, 7::signed-32>>},
         "longs" => {:long_array, <<-1::signed-64, 77::signed-64>>},
         "text" => {:string, "Hello"},
         "list" => {:list, {:string, ["a", "b"]}},
         "nested" => {:list, {:compound, [%{"number" => {:int, 1}}, %{}]}}
       }}

    assert NBT.decode(bytes(tag)) == {:ok, tag}
    assert NBT.decode(<<0>>) == {:ok, {:end, nil}}
    assert NBT.decode(bytes({:list, {:end, []}})) == {:ok, {:list, {:end, []}}}
    assert {:ok, ^tag, <<99>>} = NBT.take(bytes(tag) <> <<99>>)
  end

  test "Java modified UTF-8 encodes NUL and UTF-16 surrogate pairs" do
    value = <<0>> <> "😀é"
    encoded = <<8, 0, 10, 0xC0, 0x80, 0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80, 0xC3, 0xA9>>
    assert bytes({:string, value}) == encoded
    assert NBT.decode(encoded) == {:ok, {:string, value}}
    assert NBT.decode(<<8, 0, 4, 0xF0, 0x9F, 0x98, 0x80>>) == {:error, :invalid_nbt_utf}
    assert NBT.decode(<<8, 0, 3, 0xED, 0xA0, 0xBD>>) == {:error, :invalid_nbt_utf}
    assert NBT.decode(<<8, 0, 2, 0xC0, 0x41>>) == {:error, :invalid_nbt_utf}
    assert NBT.decode(<<8, 0, 1, 0>>) == {:ok, {:string, <<0>>}}
  end

  test "unknown types, duplicate names, illegal lists and negative/truncated lengths fail" do
    assert NBT.decode(<<13>>) == {:error, :unknown_nbt_tag}
    assert NBT.decode(<<10, 1, 0, 1, ?x, 1, 1, 0, 1, ?x, 2, 0>>) == {:error, :duplicate_nbt_name}
    assert NBT.decode(<<9, 0, 1::signed-32, 0>>) == {:error, :invalid_nbt_list}
    assert NBT.decode(<<7, -1::signed-32>>) == {:error, :invalid_nbt_array_length}
    assert NBT.decode(<<8, 0, 2, ?x>>) == {:error, :truncated_nbt}
    assert NBT.decode(<<10, 0, 99>>) == {:error, :trailing_nbt_bytes}
    tag = bytes({:compound, %{"data" => {:long_array, <<42::64>>}}})

    for size <- 0..(byte_size(tag) - 1),
        do: assert(match?({:error, _}, NBT.decode(binary_part(tag, 0, size))))

    assert catch_throw(NBT.encode({:byte, 128})) == {:nbt_error, :invalid_nbt_value}
    assert catch_throw(NBT.encode({:int_array, <<0, 0>>})) == {:nbt_error, :invalid_nbt_value}
  end

  test "byte/node/depth budgets apply independently and retained slices do not pin large packets" do
    assert NBT.decode(<<7, 65_537::signed-32>>) == {:error, :nbt_byte_limit}
    assert NBT.decode(<<9, 1, 1024::signed-32>>) == {:error, :nbt_node_limit}

    deep =
      IO.iodata_to_binary([
        <<10>>,
        List.duplicate(<<10, 0, 1, ?x>>, 33),
        List.duplicate(<<0>>, 34)
      ])

    assert NBT.decode(deep) == {:error, :nbt_depth_limit}
    tag = Enum.reduce(1..33, {:compound, %{}}, fn _, child -> {:compound, %{"x" => child}} end)
    assert catch_throw(NBT.encode(tag)) == {:nbt_error, :nbt_depth_limit}
    payload = :binary.copy(<<42>>, 128)
    packet = bytes({:byte_array, payload}) <> :binary.copy(<<0>>, 100_000)
    assert {:ok, {:byte_array, ^payload}, _} = NBT.take(packet)
    {:ok, {:byte_array, retained}, _} = NBT.take(packet)
    assert :binary.referenced_byte_size(retained) <= 65_536
  end
end
