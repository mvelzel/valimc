alias Valimc.Data.ComponentTypes
alias Valimc.Protocol.{ItemStack, TooltipDisplay}
[path, output] = System.argv()
facts = :json.decode(File.read!(path))
true = ComponentTypes.names() == facts["registry"]

values =
  for fixture <- facts["fixtures"] do
    result =
      try do
        {value, rest} = TooltipDisplay.take(Base.decode16!(fixture["input"], case: :lower))
        if rest == <<>>, do: {:ok, value}, else: {:error, :trailing}
      rescue
        _ in [ArgumentError, MatchError] -> {:error, :malformed}
      catch
        {:tooltip_error, reason} -> {:error, reason}
      end

    cond do
      not fixture["bounded"] ->
        {:error, :tooltip_count_limit} = result
        nil

      fixture["accepted"] ->
        expected = %TooltipDisplay{hide: fixture["hide"], hidden: MapSet.new(fixture["hidden"])}
        if result != {:ok, expected}, do: raise("Tooltip decode differs: #{fixture["name"]}")
        shows = Enum.map(ComponentTypes.names(), &TooltipDisplay.shows?(expected, &1))
        if shows != fixture["shows"], do: raise("Tooltip shows differs: #{fixture["name"]}")
        expected

      true ->
        if not match?({:error, _}, result),
          do: raise("Invalid tooltip accepted: #{fixture["name"]}")

        nil
    end
  end

for [i, j, same] <- facts["equality"] do
  if TooltipDisplay.identity_key(Enum.at(values, i)) ==
       TooltipDisplay.identity_key(Enum.at(values, j)) != (same == 1),
     do: raise("Tooltip equality differs: #{i}/#{j}")
end

hex = fn data -> data |> IO.iodata_to_binary() |> Base.encode16(case: :lower) end

encoded =
  values
  |> Enum.with_index()
  |> Enum.flat_map(fn
    {nil, _} ->
      []

    {value, index} ->
      stack = %{ItemStack.new("stone", 2) | components: %{"minecraft:tooltip_display" => value}}

      for mode <- [:trusted, :untrusted],
          do:
            {:ok, ^stack} =
              ItemStack.decode(IO.iodata_to_binary(ItemStack.encode(stack, mode)), mode)

      [
        %{
          index: index,
          value: hex.(TooltipDisplay.encode(value)),
          stack: hex.(ItemStack.encode(stack)),
          untrusted: hex.(ItemStack.encode(stack, :untrusted))
        }
      ]
  end)

File.write!(output, :json.encode(encoded))

IO.puts(
  "PASS: Elixir tooltip decoding/shows, #{length(facts["equality"])} native equality pairs and #{length(encoded)} stack round trips"
)
