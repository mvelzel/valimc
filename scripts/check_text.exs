alias Valimc.Text.Codec
alias Valimc.Protocol.ItemStack
alias Valimc.Data.NBT
[path, output] = System.argv()
facts = :json.decode(File.read!(path))

for fixture <- facts["lore"] do
  bytes = Base.decode16!(fixture["input"], case: :lower)

  result =
    try do
      {lines, <<>>} = Codec.take_lore(bytes)
      length(lines) == fixture["count"]
    catch
      {:text_error, _} -> false
    end

  if result != fixture["accepted"],
    do: raise("Lore line limit differs from Mojang: #{fixture["count"]}")
end

keys =
  for fixture <- facts["fixtures"] do
    {:ok, tag} = fixture["input"] |> Base.decode16!(case: :lower) |> NBT.decode()
    actual = Codec.check(tag)

    cond do
      not fixture["supported"] ->
        :unsupported = actual
        nil

      fixture["accepted"] ->
        {:ok, key} = actual
        {:ok, canonical} = fixture["canonical"] |> Base.decode16!(case: :lower) |> NBT.decode()

        if Codec.identity_key(canonical) != key,
          do: raise("Canonical text identity differs: #{fixture["name"]}")

        key

      true ->
        if not match?({:error, _}, actual), do: raise("Invalid text accepted: #{fixture["name"]}")
        nil
    end
  end

for [a, b, same] <- facts["equality"] do
  if Enum.at(keys, a) == Enum.at(keys, b) != (same == 1),
    do:
      raise(
        "Text equality differs: #{Enum.at(facts["fixtures"], a)["name"]}/#{Enum.at(facts["fixtures"], b)["name"]}"
      )
end

encoded =
  facts["fixtures"]
  |> Enum.with_index()
  |> Enum.flat_map(fn {fixture, index} ->
    if fixture["supported"] and fixture["accepted"] do
      {:ok, tag} = fixture["input"] |> Base.decode16!(case: :lower) |> NBT.decode()

      stack = %{
        ItemStack.new("stone")
        | components: %{
            "minecraft:custom_name" => tag,
            "minecraft:item_name" => tag,
            "minecraft:lore" => [tag, {:string, "lore\0🚀"}]
          }
      }

      hex = fn bytes -> bytes |> IO.iodata_to_binary() |> Base.encode16(case: :lower) end

      for mode <- [:trusted, :untrusted] do
        {:ok, ^stack} = ItemStack.decode(IO.iodata_to_binary(ItemStack.encode(stack, mode)), mode)
      end

      [
        %{
          index: index,
          text: hex.(Codec.encode(tag)),
          stack: hex.(ItemStack.encode(stack)),
          untrusted: hex.(ItemStack.encode(stack, :untrusted))
        }
      ]
    else
      []
    end
  end)

File.write!(output, :json.encode(encoded))

IO.puts(
  "PASS: Elixir text acceptance, canonicalization and #{length(facts["equality"])} Mojang equality pairs; #{length(encoded)} name/lore round trips"
)
