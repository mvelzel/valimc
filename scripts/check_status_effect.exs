alias Valimc.Living.Effects
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["data_version"] == 5023 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
       do: raise("Wrong native status reference")

decode = fn nodes -> Enum.map(nodes, &List.to_tuple/1) end

for row <- facts["cases"] do
  Enum.reduce(row["operations"], decode.(row["initial"]), fn operation, state ->
    {actual, extra} =
      case operation["op"] do
        "update" ->
          {:ok, next, changed} = Effects.refresh(state, decode.(operation["input"]))
          {next, changed == operation["changed"]}

        "tick" ->
          {next, remains, promotions} =
            Enum.reduce(1..operation["count"], {state, false, 0}, fn _,
                                                                     {current, _, promotions} ->
              {:ok, next, remains, promoted} = Effects.tick_instance(current)
              {next, remains, promotions + if(promoted, do: 1, else: 0)}
            end)

          {next, remains == operation["remains"] and promotions == operation["promotions"]}
      end

    unless extra and actual == decode.(operation["state"]) and Effects.valid_instance?(actual),
      do: raise("Native status transition differs: #{inspect({state, operation, actual})}")

    actual
  end)
end

IO.puts(
  "PASS: #{length(facts["cases"])} native refresh/server-duration traces, notification flags and suppressed promotions; no live effects claimed."
)
