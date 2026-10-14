alias Valimc.Protocol.Encryption
[mode, path] = System.argv()

if mode == "generate" do
  pair = Encryption.generate_key_pair()

  cases =
    for {size, i} <-
          Enum.with_index([
            0,
            1,
            2,
            15,
            16,
            17,
            255,
            256,
            257,
            4096,
            8192,
            3,
            5,
            7,
            31,
            32,
            33,
            63,
            64,
            65,
            127,
            128,
            129,
            511,
            512,
            513,
            1023,
            1024,
            1025,
            2047,
            2048,
            2049
          ]) do
      <<secret::binary-size(16), _::binary>> = :crypto.hash(:sha256, <<i::32>>)

      secret =
        case i do
          x when x in [0, 2] -> <<0::128>>
          x when x in [1, 31] -> :binary.copy(<<255>>, 16)
          _ -> secret
        end

      nonce = Encryption.challenge()

      plain =
        if size == 0,
          do: <<>>,
          else: for(j <- 0..(size - 1), into: <<>>, do: <<rem(j * 37 + i, 256)>>)

      {:ok, cipher} = Encryption.new(secret)
      {:ok, encrypted} = Encryption.encrypt(cipher, plain)
      {_, hello} = Encryption.hello(pair, nonce, rem(i, 2) == 0)

      %{
        public: Base.encode16(pair.encoded, case: :lower),
        secret: Base.encode16(secret, case: :lower),
        nonce: Base.encode16(nonce, case: :lower),
        plaintext: Base.encode16(plain, case: :lower),
        ciphertext: Base.encode16(encrypted, case: :lower),
        hash: Encryption.server_hash(secret, pair.encoded),
        hello: Base.encode16(IO.iodata_to_binary(hello), case: :lower),
        authenticate: rem(i, 2) == 0
      }
    end

  File.write!(path, JSON.encode!(cases))
  File.write!(path <> ".private", :erlang.term_to_binary(pair))
  IO.puts("Generated 32 synthetic encryption cases; private key stays in the temporary fixture.")
else
  pair = File.read!(path <> ".private") |> :erlang.binary_to_term()
  cases = path |> File.read!() |> JSON.decode!()
  native = (path <> ".native") |> File.read!() |> JSON.decode!()
  true = length(cases) == length(native) and length(cases) == 32

  for {c, n} <- Enum.zip(cases, native) do
    secret = Base.decode16!(c["secret"], case: :lower)
    nonce = Base.decode16!(c["nonce"], case: :lower)
    body = Base.decode16!(n["response"], case: :lower)
    {:ok, ^secret} = Encryption.accept_response(pair, nonce, body)
    if n["hash"] != c["hash"], do: raise("Native signed hash differs")
    {:ok, cipher} = Encryption.new(secret)
    ciphertext = Base.decode16!(n["ciphertext"], case: :lower)

    plain =
      for <<byte <- ciphertext>>, into: <<>> do
        {:ok, decoded} = Encryption.decrypt(cipher, <<byte>>)
        decoded
      end

    if plain != Base.decode16!(c["plaintext"], case: :lower), do: raise("Native stream differs")
  end

  IO.puts("PASS: 32 native RSA/DER/hello/hash/AES cases and byte-fragmented decryption.")
end
