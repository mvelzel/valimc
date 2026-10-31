# VMC-038a: every `EnchantingTableOracle` case through ValiMC's table
# (`Valimc.Menus.Enchanting`): the bookshelves its layout powers it with, the
# three offers of the seed, and the item each affordable button makes.
alias Valimc.Data.Blocks
alias Valimc.Menus.Enchanting
alias Valimc.Protocol.{Enchantments, ItemStack, ItemTypes}

[path] = System.argv()
cases = :json.decode(File.read!(path))
air = Blocks.id("air")
table = {0, 64, 0}

failures =
  Enum.flat_map(cases, fn c ->
    blocks =
      Map.new(c["layout"], fn [x, y, z, "minecraft:" <> name] ->
        {{x, 64 + y, z}, Blocks.id(name)}
      end)

    shelves = Enchanting.bookcases(table, &Map.get(blocks, &1, air))
    stack = ItemStack.new(c["item"])

    offers =
      for {cost, clue} <- Enchanting.offers(stack, shelves, c["seed"]) do
        case clue do
          nil -> [cost, :null, -1]
          {id, level} -> [cost, Enchantments.name(id), level]
        end
      end

    pressed =
      for p <- c["pressed"] do
        button = p["button"]
        {cost, _} = Enum.at(Enchanting.offers(stack, shelves, c["seed"]), button)

        case Enchanting.enchant(stack, c["seed"], button, cost) do
          :none ->
            %{"button" => button, "done" => true, "result" => c["item"], "enchantments" => []}

          {:ok, result} ->
            component =
              if ItemTypes.item(result.item_id)["name"] == "minecraft:enchanted_book",
                do: "minecraft:stored_enchantments",
                else: "minecraft:enchantments"

            %{
              "button" => button,
              "done" => true,
              "result" => ItemTypes.item(result.item_id)["name"],
              "enchantments" =>
                result.components[component] |> Enum.sort() |> Enum.map(&Tuple.to_list/1)
            }
        end
      end

    expected =
      for p <- c["pressed"],
          do: Map.take(p, ["button", "done", "result", "enchantments"])

    # A button that enchants spends its number in lapis and levels; one
    # whose list is empty spends nothing.
    spent =
      Enum.all?(c["pressed"], fn p ->
        n = if p["enchantments"] == [], do: 0, else: p["button"] + 1
        p["lapis"] == 3 - n and p["levels"] == 30 - n
      end)

    if offers == c["offers"] and pressed == expected and spent,
      do: [],
      else: [{c, offers, pressed}]
  end)

case failures do
  [] ->
    IO.puts("PASS: #{length(cases)} enchanting table cases")

  _ ->
    for {c, offers, pressed} <- Enum.take(failures, 8),
        do: IO.puts("FAIL: #{inspect(c)}\n  got offers #{inspect(offers)} pressed #{inspect(pressed)}")

    raise "#{length(failures)} of #{length(cases)} enchanting table cases differ"
end
