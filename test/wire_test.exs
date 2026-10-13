defmodule Valimc.WireTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Wire

  test "VarInts round trip at boundaries and random 32-bit values" do
    for n <-
          [0, 1, 127, 128, 255, 2_097_151, 2_147_483_647, 4_294_967_295] ++
            Enum.map(1..1000, fn _ -> :rand.uniform(4_294_967_296) - 1 end) do
      assert {:ok, ^n, <<1>>} = Wire.read_varint(Wire.varint(n) <> <<1>>)
    end

    assert {:ok, 4_294_967_295, <<>>} = Wire.read_varint(Wire.varint(-1))
    assert {:error, :invalid_varint} = Wire.read_varint(<<128, 128, 128, 128, 16>>)
    assert :more = Wire.read_varint(<<128>>)
  end

  test "framing preserves fragmentation and coalesced packets with compression" do
    for threshold <- [nil, 32], size <- [0, 1, 31, 32, 255, 32768] do
      payload = :crypto.strong_rand_bytes(size)
      bytes = Wire.frame(5, payload, threshold)

      assert :more =
               Wire.next_frame(binary_part(bytes, 0, byte_size(bytes) - 1), 100_000, threshold)

      assert {:ok, 5, ^payload, <<1, 0>>} = Wire.next_frame(bytes <> <<1, 0>>, 100_000, threshold)
    end
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
end
