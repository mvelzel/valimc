# The merchant menu (VMC-044b2): MerchantMenuOracle's scenarios (selecting
# trades, taking results by pickup, shift, swap, throw and clone, payments
# by hand, out-of-stock and demand-priced offers, a full inventory, drags
# and collects, the selection hint) through `Valimc.Menus.Merchant`, whose
# trade counts the use as the oracle's merchant does. After every step the
# menu's 39 slots, the cursor, each offer's uses and the drops so far must
# equal vanilla's.
alias Valimc.Menus.{Inventory, Merchant}
alias Valimc.Protocol.ItemStack

[path] = System.argv()
raw = JSON.decode!(File.read!(path))
cases = raw["cases"]
unless length(cases) >= 7, do: raise("Incomplete merchant menu scenarios")

inputs = [:pickup, :quick_move, :swap, :clone, :throw, :quick_craft, :pickup_all]

# `[id, count, glint override, damage]`, as `TableMenuOracle.stack` shows
# them (a damageable item's damage is its default 0).
stack = fn
  nil -> nil
  [id, count, nil, damage] when damage in [nil, 0] -> %ItemStack{item_id: id, count: count}
end

shown = fn
  nil ->
    nil

  %ItemStack{item_id: id, count: count} = s ->
    [
      id,
      count,
      ItemStack.component(s, "minecraft:enchantment_glint_override"),
      ItemStack.component(s, "minecraft:damage")
    ]
end

# Java inventory index i: 0..8 the hotbar (window 30..38), 9..35 the rest.
slot = fn i -> if i < 9, do: 36 + i, else: i end

{steps, failures} =
  Enum.reduce(cases, {0, []}, fn c, {steps, failures} ->
    inventory =
      c["inventory"]
      |> Enum.with_index()
      |> Enum.reduce(%Inventory{payments: {nil, nil}, infinite_materials: c["creative"]}, fn {s,
                                                                                              i},
                                                                                             inv ->
        Inventory.put(inv, slot.(i), stack.(s))
      end)

    offers =
      Enum.map(c["offers"], fn [a, b, result, uses, max, demand, multiplier, special] ->
        %{
          buy: stack.(a),
          buy_b: stack.(b),
          sell: stack.(result),
          uses: uses,
          max_uses: max,
          reward_exp: true,
          special_price: special,
          demand: demand,
          price_multiplier: Valimc.Data.Float32.round(multiplier * 1.0),
          xp: 1
        }
      end)

    {_, _, _, _, steps, failures} =
      Enum.reduce(c["steps"], {inventory, offers, 0, [], steps, failures}, fn [step, expected],
                                                                              {inv, offers, hint,
                                                                               drops, steps,
                                                                               failures} ->
        trade = fn index, offers ->
          {:ok, List.update_at(offers, index, &%{&1 | uses: &1.uses + 1}), %{}}
        end

        {inv, offers, hint, drops} =
          case step do
            [-1, index, 0] ->
              {Merchant.select(inv, offers, index), offers, index, drops}

            [input, s, button] ->
              click = %{action: Enum.at(inputs, input), slot: s, button: button}

              case Merchant.click(inv, offers, hint, click, trade) do
                {:ok, inv, offers, more, _} -> {inv, offers, hint, drops ++ more}
                {:error, _} -> {inv, offers, hint, drops}
              end
          end

        {a, b} = inv.payments
        result = elem(Merchant.sell(offers, inv.payments, hint), 0)

        actual = [
          Enum.map([a, b, result] ++ Enum.map(9..44, &Inventory.get(inv, &1)), shown),
          shown.(inv.carried),
          Enum.map(offers, & &1.uses),
          Enum.map(drops, shown)
        ]

        failures =
          if actual == expected,
            do: failures,
            else: [{c["name"], step, expected, actual} | failures]

        {inv, offers, hint, drops, steps + 1, failures}
      end)

    {steps, failures}
  end)

# The offers packet (the scenarios' offers and one asking for a water
# bottle) and the screen's open packet, byte for byte.
packet_offers =
  Enum.map(hd(cases)["offers"], fn [a, b, result, uses, max, demand, multiplier, special] ->
    %{
      buy: stack.(a),
      buy_b: stack.(b),
      sell: stack.(result),
      uses: uses,
      max_uses: max,
      special_price: special,
      demand: demand,
      price_multiplier: Valimc.Data.Float32.round(multiplier * 1.0),
      xp: 1
    }
  end) ++
    [
      %{
        buy:
          elem(
            Valimc.Protocol.ItemData.stack(
              {:compound,
               %{
                 "id" => {:string, "minecraft:potion"},
                 "count" => {:int, 1},
                 "components" =>
                   {:compound,
                    %{
                      "minecraft:potion_contents" =>
                        {:compound, %{"potion" => {:string, "minecraft:water"}}}
                    }}
               }}
            ),
            1
          ),
        buy_b: nil,
        sell: ItemStack.new("emerald"),
        uses: 3,
        max_uses: 12,
        special_price: -1,
        demand: 2,
        price_multiplier: Valimc.Data.Float32.round(0.05),
        xp: 1
      }
    ]

hex = fn {_id, payload} -> payload |> IO.iodata_to_binary() |> Base.encode16(case: :lower) end

packet = hex.(Valimc.Menus.Packets.merchant_offers(7, packet_offers, 3, 25, true, true))
unless packet == raw["packets"]["offers"], do: raise("merchant offers packet differs: #{packet}")

title = Valimc.Text.translatable("entity.minecraft.villager.librarian")
open = hex.(Valimc.Menus.Packets.open_merchant(7, title))
unless open == raw["packets"]["open"], do: raise("merchant screen packet differs: #{open}")

case Enum.reverse(failures) do
  [] ->
    IO.puts(
      "merchant_menu: #{length(cases)} scenarios, #{steps} steps equal vanilla's; the offers and screen packets are vanilla's bytes"
    )

  [first | _] = all ->
    {name, step, [es, ec, eu, ed], [as, ac, au, ad]} = first

    diff =
      for {{e, a}, i} <- Enum.with_index(Enum.zip(es, as)), e != a, do: {i, e, a}

    IO.inspect({name, step, diff, {ec, ac}, {eu, au}, {ed, ad}},
      label: "first mismatch (slot, vanilla, ours), cursor, uses, drops",
      limit: :infinity
    )

    for {n, st, _, _} <- Enum.reverse(failures), do: IO.puts("  #{n} #{inspect(st)}")
    raise "#{length(all)} of #{steps} merchant menu steps differ"
end
