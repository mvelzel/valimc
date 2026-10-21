defmodule Valimc.EncryptionTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{Encryption, Wire}

  setup_all do
    %{pair: Encryption.generate_key_pair()}
  end

  defp response(pair, secret, challenge) do
    values =
      Enum.map(
        [secret, challenge],
        &:crypto.public_encrypt(:rsa, &1, pair.public, rsa_padding: :rsa_pkcs1_padding)
      )

    IO.iodata_to_binary(Enum.map(values, &[Wire.varint(byte_size(&1)), &1]))
  end

  test "generated native key, challenge and response; private inspection is redacted", %{
    pair: pair
  } do
    nonce = Encryption.challenge()
    assert byte_size(nonce) == 4
    assert byte_size(pair.encoded) == 162
    assert Enum.map(pair.public, &byte_size/1) == [3, 128]
    secret = :crypto.strong_rand_bytes(16)
    assert {:ok, ^secret} = Encryption.accept_response(pair, nonce, response(pair, secret, nonce))
    refute inspect(pair) =~ "private:"
    refute inspect(pair) =~ "encoded:"
  end

  test "response rejects malformed framing, padding, nonce and decrypted secret length", %{
    pair: pair
  } do
    nonce = <<1, 2, 3, 4>>
    valid = response(pair, <<0::128>>, nonce)

    for body <- [
          <<>>,
          binary_part(valid, 0, byte_size(valid) - 1),
          valid <> <<0>>,
          <<128, 1, 0::1024, 128, 1, 0::1024>>,
          :binary.copy(<<0>>, 267),
          response(pair, <<0::120>>, nonce),
          response(pair, <<0::128>>, <<4, 3, 2, 1>>)
        ] do
      assert {:error, :invalid_encryption_response} =
               Encryption.accept_response(pair, nonce, body)
    end

    assert {:error, :invalid_encryption_response} = Encryption.accept_response(pair, <<1>>, valid)
    assert {:error, :invalid_encryption_response} = Encryption.accept_response(pair, nonce, nil)
    # Native VarInt accepts noncanonical five-byte lengths; bound the total work.
    <<128, 1, a::binary-size(128), 128, 1, b::binary-size(128)>> = valid
    expanded = <<128, 129, 128, 128, 0, a::binary, 128, 129, 128, 128, 0, b::binary>>
    assert {:ok, <<0::128>>} = Encryption.accept_response(pair, nonce, expanded)
  end

  test "continuous encryption is independent of fragmentation and stream direction" do
    secret = <<37::128>>
    {:ok, whole} = Encryption.new(secret)
    {:ok, split} = Encryption.new(secret)
    plaintext = :binary.copy(<<0, 1, 2, 255>>, 128)
    assert {:ok, expected} = Encryption.encrypt(whole, plaintext)

    actual =
      for <<a, b, c, d <- plaintext>>, into: <<>> do
        {:ok, bytes} = Encryption.encrypt(split, <<a, b, c, d>>)
        bytes
      end

    assert actual == expected
    assert {:ok, receiver} = Encryption.new(secret)

    decoded =
      for <<byte <- actual>>, into: <<>> do
        {:ok, plain} = Encryption.decrypt(receiver, <<byte>>)
        plain
      end

    assert decoded == plaintext
    assert {:ok, ^plaintext} = Encryption.decrypt(whole, expected)
    assert {:ok, <<>>} = Encryption.encrypt(split, <<>>)
  end

  test "cross-owner and oversize rejection do not advance a cipher" do
    secret = <<0::128>>
    {:ok, context} = Encryption.new(secret)
    task = Task.async(fn -> Encryption.encrypt(context, <<1>>) end)
    assert Task.await(task, 60_000) == {:error, :cipher_owner_mismatch}

    assert {:error, :invalid_cipher_chunk} =
             Encryption.encrypt(context, :binary.copy(<<0>>, Encryption.max_chunk() + 1))

    assert {:error, :invalid_cipher_chunk} = Encryption.decrypt(context, [<<1>>])
    {:ok, reference} = Encryption.new(secret)
    assert Encryption.encrypt(context, <<1, 2, 3>>) == Encryption.encrypt(reference, <<1, 2, 3>>)
    assert {:error, :invalid_secret} = Encryption.new(<<0::120>>)
  end
end
