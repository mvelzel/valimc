defmodule Valimc.WireTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{ClientCommand, UseItem, Wire}

  test "VarInts encode negatives as unsigned and reject overlong or truncated input" do
    assert {:ok, 4_294_967_295, <<>>} = Wire.read_varint(Wire.varint(-1))
    assert {:error, :invalid_varint} = Wire.read_varint(<<128, 128, 128, 128, 16>>)
    assert :more = Wire.read_varint(<<128>>)
  end

  test "rejects oversized frames and decompression bombs before unbounded allocation" do
    assert {:error, :packet_size} = Wire.next_frame(Wire.varint(2_097_153), 2_097_152)
    compressed = :zlib.compress(:binary.copy(<<0>>, 500_000))
    body = IO.iodata_to_binary([Wire.varint(128), compressed])

    assert {:error, _} =
             Wire.next_frame(
               IO.iodata_to_binary([Wire.varint(byte_size(body)), body]),
               1_000_000,
               32
             )

    assert {:error, _} = Wire.next_frame(<<2, 0, 0>>, 100, 1)
  end

  test "positions support negative coordinates and strings are length bounded" do
    for p <- [{0, -64, 0}, {-30_000_000, 319, 30_000_000}, {-1, -1, -1}],
        do: assert({^p, <<>>} = Wire.take_position(Wire.position(p)))

    assert {"☃", <<>>} = Wire.take_string(IO.iodata_to_binary(Wire.string("☃")), 1)
    assert_raise ArgumentError, fn -> Wire.take_string(<<2, "ab">>, 1) end
    assert_raise ArgumentError, fn -> Wire.take_string(<<1, 255>>, 16) end
  end

  test "text components use modified UTF-8 for supplementary Unicode and NUL" do
    text = "Hello 😀" <> <<0>>
    bytes = IO.iodata_to_binary(Wire.text_component(text))
    assert Valimc.NBT.decode(bytes) == {:ok, {:compound, %{"text" => {:string, text}}}}
    assert :binary.match(bytes, <<0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80>>) != :nomatch
  end

  test "client lifecycle commands reject invalid, incomplete, oversized and trailing requests" do
    assert {:ok, :respawn} = ClientCommand.decode(<<0>>)
    assert {:ok, :gamerules} = ClientCommand.decode(<<2>>)
    assert {:ok, :respawn} = ClientCommand.decode(<<128, 0>>)

    for bytes <- [
          <<>>,
          <<128>>,
          <<3>>,
          <<0, 0>>,
          Wire.varint(-1),
          <<128, 128, 128, 128, 16>>,
          <<128, 128, 128, 128, 128, 0>>,
          nil
        ] do
      assert {:error, :invalid_client_command} = ClientCommand.decode(bytes)
    end
  end

  test "use-item requests reject malformed hands, sequences, nonfinite angles and trailing bytes" do
    body = <<0, 0, 0::float-32, 90::float-32>>
    assert {:ok, %{hand: :main, sequence: 0, yaw: +0.0, pitch: 90.0}} = UseItem.decode(body)

    for bytes <- [
          <<>>,
          binary_part(body, 0, 9),
          body <> <<0>>,
          <<2, 0, 0::64>>,
          <<0, 0, 0x7F800000::32, 0::32>>,
          IO.iodata_to_binary([<<0>>, Wire.varint(2_147_483_648), <<0::64>>])
        ] do
      assert {:error, :invalid_use_item} = UseItem.decode(bytes)
    end
  end
end
