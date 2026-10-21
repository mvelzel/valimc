# VMC-028a: ValiMC worlds exported for vanilla (WorldSettingsOracle verify).
# Each case creates a world as `Generator.create/3` does (or ValiMC's flat
# profile, which records no settings) and exports it into OUT/<case>; the
# oracle then runs the pinned server on each export and checks that vanilla
# keeps the generation settings and the spawn ValiMC wrote.
[out] = System.argv()
alias Valimc.World.{Generator, Spawn}

Valimc.Protocol.Data.load!()
Valimc.World.Blocks.init!()

cases = [
  {"normal", &Generator.create(&1, 20_261_020, features: false)},
  {"no_structures", &Generator.create(&1, -3, features: false, structures: false)},
  {"decorated", &Generator.create(&1, 12_345)},
  {"flat_profile", &Spawn.write(&1, {0, 64, 0}, 0.0)}
]

for {name, make} <- cases do
  base =
    Path.join(System.tmp_dir!(), "valimc-settings-#{name}-#{System.unique_integer([:positive])}")

  File.mkdir_p!(base)
  :ok = make.(base)
  {:ok, _} = Valimc.Anvil.Export.run(base, Path.join(out, name))
  File.rm_rf!(base)
end

IO.puts("PASS: #{length(cases)} ValiMC worlds exported with their generation settings")
