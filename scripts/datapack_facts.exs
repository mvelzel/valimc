# VMC-028c: the worldgen facts of a world's data packs, as `mix
# valimc.worldgen_packs WORLD` extracts them (the fact oracles with the packs);
# fails if ValiMC cannot generate them, or if the sample pack's changes (sea
# level 70, emerald ore in plains) do not reach the facts and the terrain.
[world] = System.argv()
alias Valimc.Worldgen.{Datapacks, GenSettings, Generator}
Mix.Tasks.Valimc.WorldgenPacks.run([world])
{:ok, dir} = Datapacks.facts(world)
read = &(dir |> Path.join("#{&1}.json") |> File.read!() |> JSON.decode!())

70 = get_in(read.("noise_settings"), ["minecraft:overworld", "sea_level"])
true = "minecraft:ore_emerald" in Enum.at(read.("biomes")["minecraft:plains"]["features"], 6)

settings = GenSettings.create("minecraft:normal", nil, 20_261_020, true)
{:ok, packed} = Generator.spec_of(settings, dir)
{:ok, vanilla} = Generator.spec_of(settings)
chunks = for x <- -4..3, z <- -4..3, do: {x, z}

if Generator.columns(packed, chunks) == Generator.columns(vanilla, chunks),
  do: raise("the sample pack's terrain equals vanilla's around chunk (0, 0)")

IO.puts(
  "PASS: worldgen facts of #{length(Datapacks.packs(world))} data packs in #{dir}; their terrain differs from vanilla's"
)
