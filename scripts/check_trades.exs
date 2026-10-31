# Trade draws (VMC-044b1): TradeOracle's merchants, one after another per
# world seed (every profession and villager type through its five levels,
# then wandering traders), draw their offers from the server's random
# sequences; `Valimc.Menus.Offers` draws the same sets from the same
# sequence states, carrying each sequence from one draw to the next, and
# every offer (costs, result, uses, experience, price multiplier) must equal
# vanilla's, compared through the persistent item codec.
alias Valimc.Menus.Offers
alias Valimc.Protocol.ItemData

[path] = System.argv()
raw = JSON.decode!(File.read!(path))
origin = List.to_tuple(raw["origin"])
cases = raw["cases"]
unless length(cases) >= 1800, do: raise("Incomplete trade draws")

defmodule CheckTrades do
  def plain({:compound, fields}), do: Map.new(fields, fn {k, v} -> {k, plain(v)} end)
  def plain({:list, {type, items}}), do: Enum.map(items, &plain({type, &1}))
  def plain({:double, <<v::float-64>>}), do: v
  def plain({:float, <<v::float-32>>}), do: v
  def plain({_, v}) when is_binary(v) or is_number(v), do: v

  def stack(nil), do: nil
  def stack(stack), do: plain(ItemData.tag(stack))

  # `MerchantOffer.CODEC` leaves defaults out.
  def expected(o) do
    %{
      "buy" => o["buy"],
      "buyB" => o["buyB"],
      "sell" => o["sell"],
      "uses" => Map.get(o, "uses", 0),
      "maxUses" => Map.get(o, "maxUses", 4),
      "rewardExp" => Map.get(o, "rewardExp", true),
      "specialPrice" => Map.get(o, "specialPrice", 0),
      "demand" => Map.get(o, "demand", 0),
      "priceMultiplier" => Valimc.Data.Float32.round(Map.get(o, "priceMultiplier", 0.0) * 1.0),
      "xp" => Map.get(o, "xp", 1)
    }
  end

  def actual(o) do
    %{
      "buy" => stack(o.buy),
      "buyB" => stack(o.buy_b),
      "sell" => stack(o.sell),
      "uses" => o.uses,
      "maxUses" => o.max_uses,
      "rewardExp" => o.reward_exp,
      "specialPrice" => o.special_price,
      "demand" => o.demand,
      "priceMultiplier" => o.price_multiplier,
      "xp" => o.xp
    }
  end

  def same?(a, b) when is_map(a) and is_map(b),
    do:
      map_size(a) == map_size(b) and
        Enum.all?(a, fn {k, v} -> same?(v, Map.get(b, k, :missing)) end)

  def same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  def same?(a, b) when is_number(a) and is_number(b), do: a == b
  def same?(a, b), do: a == b
end

{offers, failures, _} =
  Enum.reduce(cases, {0, [], %{}}, fn row, {offers, failures, states} ->
    seed = String.to_integer(row["seed"])
    profession = row["profession"]
    destination = if d = row["destination"], do: List.to_tuple(d)
    {sequences, next_map} = Map.get(states, seed, {%{}, 0})

    {drawn, sequences, next_map} =
      Enum.reduce(Offers.sets(profession, row["level"]), {[], sequences, next_map}, fn {set, id},
                                                                                       {drawn,
                                                                                        sequences,
                                                                                        next_map} ->
        state = Map.get_lazy(sequences, id, fn -> Offers.sequence(seed, id) end)

        {:ok, more, state, next_map} =
          Offers.draw(set, state, row["type"], origin, [{"*", destination}], next_map)

        {drawn ++ more, Map.put(sequences, id, state), next_map}
      end)

    expected = Enum.map(row["offers"], &CheckTrades.expected/1)
    actual = Enum.map(drawn, &CheckTrades.actual/1)

    failures =
      if CheckTrades.same?(expected, actual),
        do: failures,
        else: [
          {row["seed"], row["merchant"], profession, row["type"], row["level"], expected, actual}
          | failures
        ]

    {offers + length(expected), failures, Map.put(states, seed, {sequences, next_map})}
  end)

case Enum.reverse(failures) do
  [] ->
    IO.puts("trades: #{length(cases)} draws, #{offers} offers equal vanilla's")

  [first | _] = all ->
    IO.inspect(first, label: "first mismatch", limit: :infinity, printable_limit: 400)
    raise "#{length(all)} of #{length(cases)} trade draws differ"
end
