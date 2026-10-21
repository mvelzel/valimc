defmodule Valimc.PackedVelocityTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{PackedVelocity, Wire}

  test "truncated packed fields and malformed continuation VarInts remain bounded" do
    bytes = PackedVelocity.encode({5.0, 2.0, 1.0})

    for length <- 0..(byte_size(bytes) - 1) do
      assert PackedVelocity.decode(binary_part(bytes, 0, length)) == {:error, :malformed_velocity}
    end

    <<head::binary-size(6), _::binary>> = bytes

    assert PackedVelocity.decode(head <> <<128, 128, 128, 128, 16>>) ==
             {:error, :malformed_velocity}

    assert PackedVelocity.decode(head <> Wire.varint(1) <> <<1>>) ==
             {:error, :trailing_velocity_bytes}

    for vector <- [nil, [], {1, 2}, {1, 2, :nan}] do
      assert_raise ArgumentError, fn -> PackedVelocity.encode(vector) end
    end
  end
end
