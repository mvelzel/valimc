defmodule Valimc.PackedVelocityTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{PackedVelocity, Wire}

  test "zero shortcut, quantization, continuation and unsigned maximum scale preserve bounded vectors" do
    assert PackedVelocity.encode({0, 0, 0}) == <<0>>
    assert PackedVelocity.encode({1.0e-6, -1.0e-6, 0.0}) == <<0>>
    assert {:ok, zero, <<99>>} = PackedVelocity.take(<<0, 99>>)
    assert zero == {0.0, 0.0, 0.0}
    threshold = 1.0 / 32766.0
    assert byte_size(PackedVelocity.encode({threshold, 0, 0})) == 6

    for vector <- [
          {0.1, 0.2, -0.3},
          {-1.0, 0.0, 0.0},
          {3.0, -2.0, 1.0},
          {4.0, 2.0, -1.0},
          {5.01, -4.5, 0.0},
          {8_589_934_592.0, -17, 0},
          {17_179_869_183.0, -17_179_869_183.0, 0}
        ] do
      bytes = PackedVelocity.encode(vector)
      assert byte_size(bytes) in 6..11
      assert {:ok, decoded} = PackedVelocity.decode(bytes)
      scale = max(1, ceil(vector |> Tuple.to_list() |> Enum.map(&abs/1) |> Enum.max()))

      for {actual, expected} <- Enum.zip(Tuple.to_list(decoded), Tuple.to_list(vector)) do
        assert_in_delta actual, expected, scale / 32766.0
      end

      assert {:ok, ^decoded, <<77>>} = PackedVelocity.take(bytes <> <<77>>)
    end

    assert byte_size(PackedVelocity.encode({17_179_869_183.0, 0, 0})) == 11

    assert PackedVelocity.encode({1.0e100, -1.0e100, 0}) ==
             PackedVelocity.encode({17_179_869_183.0, -17_179_869_183.0, 0})

    assert PackedVelocity.decode(<<255, 255, 255, 255, 255, 255, 0>>) == {:ok, {3.0, 3.0, 3.0}}
  end

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
