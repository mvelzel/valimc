# VMC-024: ValiMC's terrain equals vanilla's block for block (TerrainOracle):
# every noise settings entry over three seeds, chunks near the origin and far
# away, filled from the final density and the aquifer (`fill`), then with the
# material rule applied (`surface`, VMC-024b), then carved (`carve`, VMC-024c),
# with the same fluid positions marked for post-processing.
alias Valimc.Registry.Blocks

[mode, path] = System.argv()

source = fn
  "minecraft:end" -> "minecraft:the_end"
  "minecraft:nether" -> "minecraft:nether"
  _ -> "minecraft:overworld"
end

cases = (path |> File.read!() |> JSON.decode!())["cases"]

run_length = fn ids ->
  ids
  |> Enum.chunk_by(& &1)
  |> Enum.flat_map(&[hd(&1), length(&1)])
end

name = fn id -> Blocks.name(Blocks.block_id(id)) end

results =
  cases
  |> Enum.group_by(&{&1["seed"], &1["settings"]})
  |> Enum.flat_map(fn {{seed, settings}, rows} ->
    {:ok, state} = Valimc.Worldgen.new(String.to_integer(seed), settings)

    chunks = Enum.map(rows, &{&1["x"], &1["z"]})

    {:ok, filled} =
      case mode do
        "fill" -> Valimc.Native.worldgen_fill_terrain(state, chunks)
        "surface" -> Valimc.Native.worldgen_build_terrain(state, source.(settings), false, chunks)
        "carve" -> Valimc.Native.worldgen_build_terrain(state, source.(settings), true, chunks)
      end

    Enum.zip(rows, filled)
  end)

for {row, {blocks, updates}} <- results do
  where = "#{row["settings"]} seed #{row["seed"]} chunk #{row["x"]},#{row["z"]}"
  ids = for <<id::16 <- blocks>>, do: id

  if run_length.(ids) != row["runs"] do
    expected =
      row["runs"]
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn [id, n] -> List.duplicate(id, n) end)

    index = Enum.zip(ids, expected) |> Enum.find_index(fn {a, b} -> a != b end)
    height = div(length(expected), 256)
    {y, x, z} = {rem(index, height), rem(div(index, height), 16), div(index, height * 16)}

    raise "#{where}: block #{index} (local x #{x}, z #{z}, y index #{y}) is " <>
            "#{name.(Enum.at(ids, index))}, vanilla has #{name.(Enum.at(expected, index))}"
  end

  ours = updates |> Enum.map(fn {x, y, z} -> "#{x},#{y},#{z}" end) |> Enum.sort() |> Enum.dedup()

  unless ours == Enum.sort(row["fluid_updates"]),
    do:
      raise(
        "#{where}: fluid updates differ: #{length(ours)} vs vanilla's #{length(row["fluid_updates"])}"
      )
end

blocks =
  Enum.sum(
    for {row, _} <- results, do: row["runs"] |> Enum.drop(1) |> Enum.take_every(2) |> Enum.sum()
  )

updates = Enum.sum(for {row, _} <- results, do: length(row["fluid_updates"]))

IO.puts(
  "PASS: #{length(results)} #{%{"fill" => "noise-filled", "surface" => "surfaced", "carve" => "carved"}[mode]} chunks " <>
    "(#{blocks} blocks, #{updates} fluid updates) " <>
    "equal vanilla's block for block"
)
