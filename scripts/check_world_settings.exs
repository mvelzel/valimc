# VMC-028a: ValiMC's world generation settings equal vanilla's
# (WorldSettingsOracle cases). For each case (`level-type`,
# `generator-settings`, seed, `generate-structures`), the settings ValiMC
# creates equal the JSON vanilla's codec writes, ValiMC's
# `world_gen_settings.dat` root equals vanilla's NBT, and ValiMC reads vanilla's
# file back to the same settings.
[cases_path] = System.argv()
alias Valimc.Worldgen.GenSettings

cases = cases_path |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")

failures =
  for row <- cases,
      settings = row["generator_settings"],
      ours =
        GenSettings.create(
          row["level_type"],
          if(settings == "", do: nil, else: settings),
          String.to_integer(row["seed"]),
          row["generate_structures"]
        ),
      {:ok, vanilla} = Valimc.Data.NBT.read(Base.decode64!(row["nbt"])),
      want = row["json"],
      failure <- [
        if(ours != want, do: {:json, ours, want}),
        case GenSettings.to_nbt(ours) do
          {:ok, ^vanilla} -> nil
          other -> {:nbt, other, vanilla}
        end,
        case GenSettings.from_nbt(vanilla) do
          {:ok, ^want} -> nil
          other -> {:read, other}
        end
      ],
      failure != nil,
      do: {row["level_type"], row["generator_settings"], failure}

if failures != [] do
  for failure <- Enum.take(failures, 10), do: IO.inspect(failure, limit: 30)
  IO.puts("FAIL: #{length(failures)} of #{3 * length(cases)} world generation settings checks")
  System.halt(1)
end

IO.puts(
  "PASS: #{length(cases)} world generation settings equal vanilla's (created, written and read)"
)
