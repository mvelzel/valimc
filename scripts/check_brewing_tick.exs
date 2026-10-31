# The brewing stand's tick (VMC-034o) against vanilla's `serverTick`: each
# script of slot sets and ticks leaves the same slots, times, ingredient,
# `has_bottle_*` states, drops and level events after every step.
alias Valimc.Blocks.Brewing
alias Valimc.Data.PotionTypes
alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

stack = fn
  nil ->
    nil

  [item, count, nil] ->
    %ItemStack{item_id: ItemTypes.id(item), count: count}

  [item, count, potion] ->
    %ItemStack{
      item_id: ItemTypes.id(item),
      count: count,
      components: %{
        "minecraft:potion_contents" => %{PotionContents.empty() | potion: PotionTypes.id(potion)}
      }
    }
end

spec = fn
  nil ->
    nil

  %ItemStack{item_id: id, count: count, components: components} ->
    potion =
      case components["minecraft:potion_contents"] do
        %{potion: p} when is_integer(p) -> PotionTypes.name(p)
        _ -> nil
      end

    [ItemTypes.item(id)["name"], count, potion]
end

for {c, n} <- Enum.with_index(cases) do
  Enum.zip(c["ops"], c["states"])
  |> Enum.reduce({%Brewing{}, %{}, [false, false, false]}, fn {op, expected},
                                                              {stand, slots, bits} ->
    {stand, slots, bits, drops, events} =
      case op do
        ["set", specs] ->
          slots =
            for {s, i} <- Enum.with_index(specs), s != nil, into: %{}, do: {i, stack.(s)}

          {stand, slots, bits, [], []}

        ["tick", count] ->
          Enum.reduce(1..count, {stand, slots, bits, [], []}, fn _,
                                                                 {stand, slots, bits, drops,
                                                                  events} ->
            {stand, slots, made} = Brewing.tick(stand, slots)
            drops = drops ++ for({:drop, d} <- made, do: spec.(d))
            events = events ++ for({:level_event, e} <- made, do: e)
            bits = Enum.find_value(made, bits, fn e -> match?({:bottles, _}, e) && elem(e, 1) end)
            {stand, slots, bits, drops, events}
          end)
      end

    actual = %{
      "brewTime" => stand.brew_time,
      "totalBrewTime" => stand.total_brew_time,
      "fuel" => stand.fuel,
      "totalFuel" => stand.total_fuel,
      "speed" => stand.speed,
      "ingredient" => stand.ingredient && ItemTypes.item(stand.ingredient)["name"],
      "slots" => for(i <- 0..4, do: spec.(slots[i])),
      "bottles" => bits,
      "drops" => drops,
      "events" => events
    }

    unless actual == expected,
      do:
        raise(
          "Brewing script #{n} differs at #{inspect(op)}: #{inspect(actual)} vs #{inspect(expected)}"
        )

    {stand, slots, bits}
  end)
end

IO.puts(
  "PASS: #{length(cases)} brewing stand scripts equal vanilla's serverTick after every step."
)
