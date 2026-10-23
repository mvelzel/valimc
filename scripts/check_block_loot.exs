# Block loot parity (VMC-029e): every `LootOracle blocks` case (each block
# state with a table, every break context for a block's default state, one
# random context for its other states) broken through
# `Valimc.Blocks.MiningLoot` names the case's table and drops what vanilla's
# `getDrops` drops, stack for stack, compared through the persistent item
# codec.
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
  Enum.reject(cases, fn row ->
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

IO.puts(
  "PASS: #{length(cases)} block breaks over #{states} states equal vanilla's drops (#{stacks} stacks)"
)
