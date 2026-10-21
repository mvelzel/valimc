alias Valimc.Living.{Damage, Effects}
[facts_path, cases_path] = System.argv()
facts = :json.decode(File.read!(facts_path))
pinned = :json.decode(File.read!("priv/protocol/status_damage.json"))
unless facts == pinned, do: raise("Wrong native status immunity facts")
cases = :json.decode(File.read!(cases_path))
unless length(cases) == 306, do: raise("Incomplete native status immunity contexts")

for row <- cases do
  effects =
    if row["effect"] == -1 do
      %{}
    else
      {:ok, state} = Effects.new(row["ticks"], row["amplifier"])
      %{row["effect"] => state}
    end

  unless Damage.status_immune?(effects, String.to_atom(row["source"])) == row["rejected"],
    do: raise("Native status immunity differs: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(cases)} native map-presence/status damage gates; no live clock, health, wear or mode immunity claimed."
)
