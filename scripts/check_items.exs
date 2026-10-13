alias Valimc.Protocol.ItemStack
[input, output] = System.argv()

fixtures = :json.decode(File.read!(input))

encoded =
  Enum.map(fixtures, fn fixture ->
    decode = fn mode ->
      bytes = Base.decode16!(fixture[Atom.to_string(mode)], case: :lower)

      case ItemStack.decode(bytes, mode) do
        {:ok, stack} -> stack
        error -> raise("#{fixture["name"]} #{mode} failed: #{inspect(error)}")
      end
    end

    trusted = decode.(:trusted)
    untrusted = decode.(:untrusted)
    if trusted != untrusted, do: raise("Mojang fixture formats disagree")

    Map.new([
      {"name", fixture["name"]}
      | Enum.map([:trusted, :untrusted], fn mode ->
          # Cross-convert rather than returning a captured input packet.
          stack = if mode == :trusted, do: untrusted, else: trusted
          bytes = ItemStack.encode(stack, mode) |> IO.iodata_to_binary()
          {Atom.to_string(mode), Base.encode16(bytes, case: :lower)}
        end)
    ])
  end)

File.write!(output, :json.encode(encoded))
IO.puts("PASS: Elixir decoded and cross-converted #{length(fixtures)} Mojang stack cases")
