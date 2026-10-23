# Loot parity (VMC-072a, entity drops VMC-037n): every LootOracle case (each
# container table over many seeds, luck values, biomes and origins, synthetic
# tables for the entry kinds and nesting the pack's container tables leave
# out, and the modelled mobs' death drops over victims, killers and weapons)
# made by `Valimc.Blocks.Loot` equals vanilla's, slot for slot, compared
# through the persistent item codec (enchantment maps compare as maps, since
# their network order follows a hash map).
[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.Loot
alias Valimc.Protocol.ItemData

defmodule CheckLoot do
  def plain({:compound, fields}), do: Map.new(fields, fn {k, v} -> {k, plain(v)} end)
  def plain({:list, {type, items}}), do: Enum.map(items, &plain({type, &1}))
  def plain({:double, <<v::float-64>>}), do: v
  def plain({:float, <<v::float-32>>}), do: v
  def plain({_, v}) when is_binary(v) or is_number(v), do: v
  def plain({type, items}) when type in [:int_array, :long_array, :byte_array], do: items

  def same?(a, b) when is_map(a) and is_map(b),
    do:
      map_size(a) == map_size(b) and
        Enum.all?(a, fn {k, v} -> same?(v, Map.get(b, k, :missing)) end)

  def same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  def same?(a, b) when is_number(a) and is_number(b), do: a == b
  def same?(a, b), do: a == b

  # The oracle's stand-in structure search: a third of seeds find nothing.
  def destination(seed) do
    if Integer.mod(seed, 3) == 0,
      do: nil,
      else: {Integer.mod(seed, 4001) - 2000, 64, Integer.mod(div(seed, 4001), 4001) - 2000}
  end
end

true = length(raw["cases"]) == 3160
tables = raw["cases"] |> Enum.map(& &1["table"]) |> Enum.uniq()
true = length(tables) == 71

read = fn name ->
  Application.app_dir(:valimc, "priv/loot/#{name}.json") |> File.read!() |> JSON.decode!()
end

{:ok, synthetic} =
  Valimc.Native.loot_registry(
    Map.merge(read.("tables"), raw["synthetic_tables"]),
    Loot.registries()
  )

{stacks, failures} =
  Enum.reduce(raw["cases"], {0, []}, fn row, {stacks, failures} ->
    seed = String.to_integer(row["seed"])
    [x, y, z] = row["origin"]

    opts = [
      luck: row["luck"],
      biome: row["biome"],
      structure: CheckLoot.destination(seed),
      next_map: 0
    ]

    opts =
      if Map.has_key?(raw["synthetic_tables"], row["table"]),
        do: [{:registry, synthetic} | opts],
        else: opts

    actual =
      case row["size"] do
        0 ->
          {:ok, items, _} = Loot.items(row["table"], seed, {x, y, z}, opts)
          items

        size ->
          {:ok, slots, _} = Loot.fill(row["table"], seed, {x, y, z}, [{:size, size} | opts])
          Tuple.to_list(slots)
      end

    actual = Enum.map(actual, &(&1 && CheckLoot.plain(ItemData.tag(&1))))
    expected = row["slots"]

    if CheckLoot.same?(actual, expected),
      do: {stacks + Enum.count(expected, & &1), failures},
      else: {stacks, [{row, actual} | failures]}
  end)

for {row, actual} <- failures |> Enum.reverse() |> Enum.take(5) do
  IO.puts("FAIL #{row["table"]} seed=#{row["seed"]} luck=#{row["luck"]} biome=#{row["biome"]}")
  IO.puts("  vanilla: #{inspect(row["slots"] |> Enum.reject(&is_nil/1), limit: :infinity)}")
  IO.puts("  valimc:  #{inspect(actual |> Enum.reject(&is_nil/1), limit: :infinity)}")
end

if failures != [] do
  IO.puts("FAIL: #{length(failures)} of 3160 container fills differ")
  System.halt(1)
end

# A case's weapon: its item and enchantments (all the tables read of it).
weapon = fn
  nil ->
    nil

  json ->
    %Valimc.Protocol.ItemStack{
      item_id: Valimc.Protocol.ItemTypes.id(json["id"]),
      count: 1,
      components: %{
        "minecraft:enchantments" => get_in(json, ["components", "minecraft:enchantments"]) || %{}
      }
    }
end

deaths = raw["entity_cases"]
# 1500 deaths per modelled mob's table (zombie, chicken, endermite, pig).
true = length(deaths) == 1500 * 4

death_failures =
  Enum.reject(deaths, fn row ->
    [x, y, z] = row["origin"]
    hand = weapon.(row["weapon"])

    {:ok, drops} =
      Loot.entity_drops(row["table"], String.to_integer(row["seed"]), {x, y, z}, %{
        on_fire: row["on_fire"],
        baby: row["baby"],
        vehicle: row["vehicle"],
        killed_by_player: row["killed_by_player"],
        attacker: hand,
        direct_attacker: hand
      })

    CheckLoot.same?(Enum.map(drops, &CheckLoot.plain(ItemData.tag(&1))), row["drops"])
  end)

for row <- Enum.take(death_failures, 5), do: IO.puts("FAIL death #{inspect(row)}")

if death_failures != [] do
  IO.puts("FAIL: #{length(death_failures)} of #{length(deaths)} entity deaths differ")
  System.halt(1)
end

IO.puts(
  "PASS: 3160 container fills over 69 pack and 2 synthetic loot tables and #{length(deaths)} zombie, chicken, endermite and pig deaths equal vanilla (#{stacks} stacks)"
)
