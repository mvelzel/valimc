defmodule Valimc.CodecPropertyTest do
  @moduledoc "Untrusted-input decoders: round trips and never-crash/bounded properties."
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag timeout: 300_000
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.Data.NBT

  property "VarInts round-trip across the signed and unsigned 32-bit range" do
    check all(n <- integer(-2_147_483_648..4_294_967_295)) do
      bytes = IO.iodata_to_binary(Wire.varint(n))
      assert byte_size(bytes) in 1..5
      assert {:ok, decoded, <<>>} = Wire.read_varint(bytes)
      assert decoded == Bitwise.band(n, 0xFFFFFFFF)
    end
  end

  property "framing round-trips with and without compression" do
    check all(
            id <- integer(0..200),
            payload <- binary(max_length: 2048),
            threshold <- one_of([constant(nil), integer(0..512)])
          ) do
      frame = Wire.frame(id, payload, threshold)
      assert {:ok, ^id, ^payload, <<>>} = Wire.next_frame(frame, 2_097_152, threshold)
    end
  end

  property "arbitrary bytes never crash framing and respect the size limit" do
    check all(
            bytes <- binary(max_length: 512),
            threshold <- one_of([constant(nil), constant(64)])
          ) do
      case Wire.next_frame(bytes, 256, threshold) do
        {:ok, id, payload, rest} ->
          assert is_integer(id) and is_binary(payload) and is_binary(rest)
          assert byte_size(payload) <= 256

        other ->
          assert other == :more or match?({:error, _}, other)
      end
    end
  end

  property "arbitrary bytes never crash NBT or item stack decoding" do
    check all(bytes <- binary(max_length: 256)) do
      assert match?({:ok, _}, NBT.decode(bytes)) or match?({:error, _}, NBT.decode(bytes))

      result =
        try do
          ItemStack.decode(bytes, :untrusted)
        rescue
          # Untrusted item stacks surface malformed input as ArgumentError to the
          # connection's packet boundary, which closes the session.
          ArgumentError -> {:error, :malformed}
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result) or
               match?({:unsupported, _}, result)
    end
  end
end
