defmodule Valimc.Protocol.Encryption do
  @moduledoc "Minecraft-only crypto primitives. Stream resources belong to one socket owner and mutate in place."
  alias Valimc.Protocol.{Packets, Wire}
  import Bitwise

  defmodule KeyPair do
    @derive {Inspect, only: []}
    defstruct [:public, :private, :encoded]
  end

  alias __MODULE__.KeyPair
  @rsa_bytes 128
  @max_chunk 2_097_152
  defstruct [:owner, :incoming, :outgoing]
  def max_chunk, do: @max_chunk

  # Invoke at startup or in a bounded crypto job, never on a gameplay hot path.
  def generate_key_pair do
    {[exponent, modulus] = public, private} = :crypto.generate_key(:rsa, {1024, 65537})
    key = {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}
    # X.509 SubjectPublicKeyInfo DER, as the client expects.
    {:SubjectPublicKeyInfo, encoded, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, key)

    %KeyPair{public: public, private: private, encoded: encoded}
  end

  def challenge, do: :crypto.strong_rand_bytes(4)

  def hello(%{encoded: encoded}, <<_::32>> = challenge, authenticate)
      when is_boolean(authenticate) do
    Packets.packet(
      "hello",
      [
        Wire.string(""),
        Wire.varint(byte_size(encoded)),
        encoded,
        <<4>>,
        challenge,
        <<if(authenticate, do: 1, else: 0)>>
      ],
      :login
    )
  end

  def accept_response(%{private: private}, <<_::32>> = challenge, body)
      when is_binary(body) and byte_size(body) <= 2 * (@rsa_bytes + 5) do
    {encrypted_secret, rest} = take_cipher(body)
    {encrypted_challenge, <<>>} = take_cipher(rest)

    secret =
      :crypto.private_decrypt(:rsa, encrypted_secret, private, rsa_padding: :rsa_pkcs1_padding)

    nonce =
      :crypto.private_decrypt(:rsa, encrypted_challenge, private, rsa_padding: :rsa_pkcs1_padding)

    if byte_size(secret) == 16 and nonce == challenge,
      do: {:ok, secret},
      else: {:error, :invalid_encryption_response}
  rescue
    _ -> {:error, :invalid_encryption_response}
  end

  def accept_response(_, _, _), do: {:error, :invalid_encryption_response}

  defp take_cipher(bytes) do
    {@rsa_bytes, rest} = Wire.take_varint(bytes)
    <<cipher::binary-size(@rsa_bytes), rest::binary>> = rest
    {cipher, rest}
  end

  def server_hash(<<_::128>> = secret, encoded)
      when is_binary(encoded) and byte_size(encoded) <= 2048 do
    <<first, _::binary>> = digest = :crypto.hash(:sha, [secret, encoded])
    unsigned = :binary.decode_unsigned(digest)
    signed = if first >= 128, do: unsigned - (1 <<< 160), else: unsigned
    signed |> Integer.to_string(16) |> String.downcase()
  end

  def new(<<_::128>> = secret) do
    {:ok,
     %__MODULE__{
       owner: self(),
       incoming: :crypto.crypto_init(:aes_128_cfb8, secret, secret, false),
       outgoing: :crypto.crypto_init(:aes_128_cfb8, secret, secret, true)
     }}
  end

  def new(_), do: {:error, :invalid_secret}

  def encrypt(%__MODULE__{} = context, bytes), do: update(context, context.outgoing, bytes)
  def decrypt(%__MODULE__{} = context, bytes), do: update(context, context.incoming, bytes)

  defp update(%{owner: owner}, _, _) when owner != self(), do: {:error, :cipher_owner_mismatch}

  defp update(_, state, bytes) when is_binary(bytes) and byte_size(bytes) <= @max_chunk,
    do: {:ok, :crypto.crypto_update(state, bytes)}

  defp update(_, _, _), do: {:error, :invalid_cipher_chunk}
end
