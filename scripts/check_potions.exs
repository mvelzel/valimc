alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}
alias Valimc.Data.PotionTypes
[facts_path, cases_path, output_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == "priv/protocol/potions.json" |> File.read!() |> JSON.decode!(),
  do: raise("Pinned potion facts differ")

effect = fn row -> {row["id"], Enum.map(row["rungs"], &List.to_tuple/1)} end

for row <- facts["potions"] do
  unless PotionTypes.id(row["name"]) == row["id"] and
           PotionTypes.effects(row["id"]) == Enum.map(row["effects"], effect),
         do: raise("Native potion holder differs #{row["name"]}")
end

for {id, bytes} <- facts["default_contents"] do
  unless Base.encode16(
           ItemTypes.defaults(String.to_integer(id)).values["minecraft:potion_contents"],
           case: :lower
         ) == bytes,
         do: raise("Native default potion contents differ #{id}")
end

cases = cases_path |> File.read!() |> JSON.decode!()

encoded =
  for row <- cases do
    value = row["contents"]

    contents = %{
      potion: value["potion"],
      color: value["color"],
      effects: Enum.map(value["effects"], effect),
      name: value["name"]
    }

    components = if row["patched"], do: %{"minecraft:potion_contents" => contents}, else: %{}
    stack = %ItemStack{item_id: row["item"], components: components}

    values =
      for mode <- [:trusted, :untrusted], into: %{} do
        key = Atom.to_string(mode)

        wire =
          stack |> ItemStack.encode(mode) |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

        unless wire == row[key], do: raise("Native potion bytes differ #{row["name"]}/#{key}")

        unless {:ok, stack} == row[key] |> Base.decode16!(case: :lower) |> ItemStack.decode(mode),
          do: raise("Native potion stack decode differs #{row["name"]}/#{key}")

        {key, wire}
      end

    for scaled <- row["scaled"] do
      unless PotionContents.effects(contents, scaled["scale"]) ==
               Enum.map(scaled["effects"], effect),
             do: raise("Native scaled delivery differs #{row["name"]}/#{scaled["scale"]}")
    end

    Map.put(values, "name", row["name"])
  end

File.write!(output_path, JSON.encode!(encoded))

IO.puts(
  "PASS: #{PotionTypes.count()} native potion holders, #{length(cases)} dual-format stacks and #{Enum.sum(Enum.map(cases, &length(&1["scaled"])))} scaled deliveries. No application/consumption claim."
)
