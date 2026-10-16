alias Valimc.PlayerResistance
alias Valimc.Protocol.EffectTypes
Code.ensure_loaded!(PlayerResistance)
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()
id = EffectTypes.id("resistance")

for row <- rows do
  effects =
    if row["amplifier"] < 0,
      do: %{},
      else: %{id => [{row["duration"], row["amplifier"], false, true, true}]}

  {:ok, actual} =
    PlayerResistance.reduce(row["amount"], String.to_existing_atom(row["source"]), effects)

  expected = if row["reduced"] == "infinity", do: 3.4028234663852886e38, else: row["reduced"]
  unless actual == expected, do: raise("Native resistance differs #{inspect(row)}; got #{actual}")
end

IO.puts(
  "PASS: #{length(rows)} native Resistance/source contexts; finite bits exact, native lethal infinity saturated for bounded health. Owner/gear/statistics excluded."
)
