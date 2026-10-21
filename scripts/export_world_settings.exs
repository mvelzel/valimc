# VMC-028a: ValiMC worlds exported for vanilla (WorldSettingsOracle verify).
# Each case creates a world as `Generator.create/3` does (or ValiMC's flat
# profile, which records no settings) and exports it into OUT/<case>; the
# oracle then runs the pinned server on each export and checks that vanilla
# keeps the generation settings and the spawn ValiMC wrote.
[out] = System.argv()
alias Valimc.World.Generator

Valimc.Protocol.Data.load!()
Valimc.Registry.BlockFacts.install!()

# A flat world without structures (VMC-025f places them): vanilla generates its spawn chunks
# from the exported settings, and they must hold ValiMC's flat column (VMC-028b).
flat =
  ~s({"layers":[{"block":"minecraft:bedrock","height":1},{"block":"minecraft:deepslate","height":40},) <>
    ~s({"block":"minecraft:sandstone","height":20},{"block":"minecraft:sand","height":3}],"biome":"minecraft:desert"})

cases = [
  {"flat",
   &Generator.create(&1, 7,
     level_type: "minecraft:flat",
     generator_settings: flat,
     structures: false
   )},
  {"normal", &Generator.create(&1, 20_261_020, features: false)},
  {"no_structures", &Generator.create(&1, -3, features: false, structures: false)},
  {"decorated", &Generator.create(&1, 12_345)},
  {"flat_profile", &Valimc.World.Spec.write(&1, %{"type" => "flat"})}
]

for {name, make} <- cases do
  base =
    Path.join(
      System.tmp_dir!(),
      "valimc-settings-#{name}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    )

  File.mkdir_p!(base)
  :ok = make.(base)
  {:ok, _} = Valimc.Anvil.Export.run(base, Path.join(out, name))

  # ValiMC's chunk (0, 0) for the oracle: each Y's state id and the biome.
  world = Valimc.World.Spec.fetch(base)

  with {:ok, %{kind: :flat} = spec} <- Valimc.World.Spec.generation(world, :overworld) do
    %{{0, 0} => image} = Generator.columns(spec, [{0, 0}])
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, %{{0, 0} => image})
    states = for y <- -64..319, do: Valimc.World.Blocks.get(blocks, {5, y, 9})
    settings = world.settings
    biome = Valimc.World.GenSettings.overworld(settings)["settings"]["biome"]

    File.write!(
      Path.join(out, name <> ".expected.json"),
      JSON.encode!(%{states: states, biome: biome})
    )
  end

  File.rm_rf!(base)
end

IO.puts("PASS: #{length(cases)} ValiMC worlds exported with their generation settings")
