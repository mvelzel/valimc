alias Valimc.Living.FoodItems
alias Valimc.Player.{GameMode, Food}
alias Valimc.Protocol.{ItemStack, ItemTypes, FoodProperties}
[facts_path, input, output] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == "priv/protocol/food_items.json" |> File.read!() |> JSON.decode!(),
  do: raise("Pinned food facts changed")

for {name, row} <- facts["items"] do
  id = ItemTypes.id(name)
  unless id == row["item_id"], do: raise("Food registry ID differs #{name}")
  defaults = FoodItems.defaults(id)

  unless defaults.food == nil or FoodProperties.valid?(defaults.food),
    do: raise("Invalid native food facts #{name}")

  if defaults.consumable do
    unless FoodItems.duration(defaults.consumable["seconds"]) == defaults.consumable["ticks"],
      do: raise("Default use duration differs #{name}")
  end
end

cases = input |> File.read!() |> JSON.decode!()

encoded =
  for c <- cases["codecs"] do
    values =
      for mode <- [:trusted, :untrusted], into: %{} do
        bytes = Base.decode16!(c[Atom.to_string(mode)], case: :mixed)
        {:ok, stack} = ItemStack.decode(bytes, mode)
        props = stack.components["minecraft:food"]

        unless props.nutrition == c["food"]["nutrition"] and
                 props.saturation == c["food"]["saturation"] and
                 props.can_always_eat == c["food"]["can_always_eat"] and
                 FoodProperties.valid?(props),
               do: raise("Native food codec mismatch #{inspect(c)}")

        wire =
          stack |> ItemStack.encode(mode) |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

        unless wire == c[Atom.to_string(mode)], do: raise("Native food bytes differ #{c["name"]}")
        {Atom.to_string(mode), wire}
      end

    Map.put(values, "name", c["name"])
  end

File.write!(output, JSON.encode!(encoded))

for c <- cases["eligibility"] do
  properties = %{food: if(c["food"], do: %{can_always_eat: c["always"]})}
  mode = GameMode.new(String.to_existing_atom(c["mode"]))

  unless FoodItems.eligible?(
           properties,
           %Food{level: c["level"]},
           GameMode.abilities(mode, false)
         ) == c["allowed"],
         do: raise("Native consumption eligibility differs #{inspect(c)}")
end

for c <- cases["durations"],
    do:
      unless(FoodItems.duration(c["seconds"]) == c["ticks"],
        do: raise("Native consume duration differs #{inspect(c)}")
      )

describe = fn
  nil -> %{"item_id" => 0, "count" => 0}
  stack -> %{"item_id" => stack.item_id, "count" => stack.count}
end

for c <- cases["remainders"] do
  count = c["old"] - c["consumed"]
  remaining = if count > 0, do: ItemStack.new("stone", count)
  {result, extra} = FoodItems.remainder(remaining, c["old"], c["infinite"], ItemStack.new("bowl"))

  unless describe.(result) == c["result"] and Enum.map(extra, describe) == c["extra"],
    do: raise("Native use remainder differs #{inspect(c)}")
end

IO.puts(
  "PASS: #{map_size(facts["items"])} defaults, #{length(cases["codecs"])} food codec pairs, #{length(cases["eligibility"])} native gates, #{length(cases["durations"])} durations and #{length(cases["remainders"])} remainder conversions."
)
