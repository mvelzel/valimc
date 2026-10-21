alias Valimc.Living.Effects
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  {:ok, request} = Effects.instant(row["id"], row["amplifier"])

  expected =
    case request do
      {:heal, amount} -> [["heal", amount]]
      {:hurt, source, amount} -> [["hurt", Atom.to_string(source), amount]]
    end

  unless row["actions"] == expected,
    do: raise("Native instant drink request differs #{inspect(row)}; got #{inspect(expected)}")
end

IO.puts(
  "PASS: #{length(rows)} native instant drink requests/source; downstream live behavior excluded."
)
