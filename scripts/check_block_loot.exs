# Block loot parity (VMC-029e): every `LootOracle blocks` case (each block
# state with a table, every break context for a block's default state, one
# random context for its other states) broken through
# `Valimc.Blocks.MiningLoot` names the case's table and drops what vanilla's
# `getDrops` drops, stack for stack, compared through the persistent item
# codec; each block interaction (VMC-039b: berries picked, a block tilled or
# sheared) drops what its table gives.
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
alias Valimc.Blocks.MiningLoot
alias Valimc.Protocol.{ItemData, ItemStack, ItemTypes}

defmodule CheckBlockLoot do
  def plain({:compound, fields}), do: Map.new(fields, fn {k, v} -> {k, plain(v)} end)
  def plain({:list, {type, items}}), do: Enum.map(items, &plain({type, &1}))
  def plain({:double, <<v::float-64>>}), do: v
  def plain({:float, <<v::float-32>>}), do: v
  def plain({_, v}) when is_binary(v) or is_number(v), do: v

  # A named container's name (VMC-032c5), a plain literal.
  def name(%{"name" => name}), do: {:string, name}
  def name(_), do: nil

  # A case's tool: its item and (stored) enchantments, all a table reads.
  def tool(nil), do: nil

  def tool(json) do
    components =
      for key <- ["minecraft:enchantments", "minecraft:stored_enchantments"],
          levels = get_in(json, ["components", key]),
          into: %{},
          do: {key, levels}

    %ItemStack{item_id: ItemTypes.id(json["id"]), count: 1, components: components}
  end
end

true = length(cases) > 50_000

failures =
  Enum.reject(cases, fn
    %{"interact" => true} = row ->
      [x, y, z] = row["origin"]

      {:ok, drops} =
        Valimc.Blocks.Loot.block_drops(row["table"], String.to_integer(row["seed"]), {x, y, z}, %{
          state: row["state"],
          tool: CheckBlockLoot.tool(row["tool"]),
          entity: true
        })

      Enum.map(drops, &CheckBlockLoot.plain(ItemData.tag(&1))) == row["drops"]

    # A shulker box (VMC-032c2): its table yields the plain box, which the
    # owner drops holding the entry's slots (`ShulkerBox.drop/2`).
    %{"contents" => contents} = row ->
      [x, y, z] = row["origin"]

      {:ok, plain} =
        MiningLoot.drops(row["state"], {x, y, z}, seed: String.to_integer(row["seed"]))

      slots =
        Enum.reduce(contents, Tuple.duplicate(nil, 27), fn [slot, id, count], acc ->
          put_elem(acc, slot, ItemStack.new(String.replace_prefix(id, "minecraft:", ""), count))
        end)

      drop = Valimc.Blocks.ShulkerBox.drop(row["state"], slots, CheckBlockLoot.name(row))

      plain == [%ItemStack{item_id: drop.item_id}] and
        MiningLoot.table(row["state"]) == row["table"] and
        [CheckBlockLoot.plain(ItemData.tag(drop))] == row["drops"]

    row ->
      [x, y, z] = row["origin"]

      {:ok, drops} =
        MiningLoot.drops(row["state"], {x, y, z},
          seed: String.to_integer(row["seed"]),
          tool: CheckBlockLoot.tool(row["tool"]),
          entity: row["entity"],
          radius: row["radius"],
          above: row["above"],
          below: row["below"]
        )

      # A named container's own item carries its name (VMC-032c5).
      drops =
        Valimc.World.ContainerSpills.name_drops(drops, row["state"], CheckBlockLoot.name(row))

      MiningLoot.table(row["state"]) == row["table"] and
        Enum.map(drops, &CheckBlockLoot.plain(ItemData.tag(&1))) == row["drops"]
  end)

for row <- Enum.take(failures, 8), do: IO.puts("FAIL #{inspect(row, limit: :infinity)}")

if failures != [] do
  IO.puts("FAIL: #{length(failures)} of #{length(cases)} block breaks differ")
  System.halt(1)
end

states = cases |> Enum.map(& &1["state"]) |> Enum.uniq() |> length()
stacks = cases |> Enum.map(&length(&1["drops"])) |> Enum.sum()

interactions = Enum.count(cases, & &1["interact"])

IO.puts(
  "PASS: #{length(cases) - interactions} block breaks over #{states} states (#{Enum.count(cases, &Map.has_key?(&1, "contents"))} filled shulker boxes, #{Enum.count(cases, &Map.has_key?(&1, "name"))} named containers) and #{interactions} block interactions equal vanilla's drops (#{stacks} stacks)"
)
