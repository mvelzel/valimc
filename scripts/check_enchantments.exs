alias Valimc.Protocol.{Enchantments, ItemStack}
[path, output] = System.argv()
facts = :json.decode(File.read!(path))
true = Enchantments.names() == facts["registry"]

values =
  for fixture <- facts["fixtures"] do
    bytes = Base.decode16!(fixture["input"], case: :lower)

    result =
      try do
        {value, rest} = Enchantments.take(bytes)
        if rest == <<>>, do: {:ok, value}, else: {:error, :trailing}
      rescue
        _ in [ArgumentError, MatchError] -> {:error, :malformed}
      catch
        {:enchantment_error, reason} -> {:error, reason}
      end

    cond do
      not fixture["bounded"] ->
        {:error, :enchantment_count_limit} = result
        nil

      fixture["accepted"] ->
        expected = fixture["values"]

        if result != {:ok, expected},
          do: raise("Enchantment decode differs: #{fixture["name"]}: #{inspect(result)}")

        expected

      true ->
        if not match?({:error, _}, result),
          do: raise("Invalid enchantments accepted: #{fixture["name"]}")

        nil
    end
  end

for [i, j, same] <- facts["equality"] do
  if Enum.at(values, i) == Enum.at(values, j) != (same == 1),
    do: raise("Enchantment equality differs: #{i}/#{j}")
end

hex = fn data -> data |> IO.iodata_to_binary() |> Base.encode16(case: :lower) end

encoded =
  values
  |> Enum.with_index()
  |> Enum.flat_map(fn
    {nil, _} ->
      []

    {value, index} ->
      stack = %{
        ItemStack.new("stone", 2)
        | components: %{
            "minecraft:enchantments" => value,
            "minecraft:stored_enchantments" => value
          }
      }

      for mode <- [:trusted, :untrusted] do
        {:ok, ^stack} = ItemStack.decode(IO.iodata_to_binary(ItemStack.encode(stack, mode)), mode)
      end

      [
        %{
          index: index,
          value: hex.(Enchantments.encode(value)),
          stack: hex.(ItemStack.encode(stack)),
          untrusted: hex.(ItemStack.encode(stack, :untrusted))
        }
      ]
  end)

File.write!(output, :json.encode(encoded))

IO.puts(
  "PASS: Elixir enchantments match #{length(facts["fixtures"])} native decode cases, #{length(facts["equality"])} equality pairs and #{length(encoded)} stack round trips"
)
