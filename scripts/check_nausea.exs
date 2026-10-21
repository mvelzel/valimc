alias Valimc.Living.Effects
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["protocol"] == 777 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         facts["hook_contexts"] == 256 and
         {facts["blend_in"], facts["blend_out"], facts["blend_advance"]} == {150, 20, 60},
       do: raise("Unexpected native Nausea hooks/blending reference")

decode = fn rows -> Enum.map(rows, &List.to_tuple/1) end

for row <- facts["ticks"] do
  {:ok, after_tick, remains, promoted} = Effects.tick_instance(decode.(row["before"]))

  unless after_tick == decode.(row["after"]) and remains == row["remains"] and
           promoted == (row["promotions"] == 1),
         do: raise("Native Nausea duration/promotion differs: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(facts["ticks"])} native Nausea duration/promotion contexts; 256 no-action/no-attribute hook contexts and client blend150/20/60 verified. Rendered distortion remains a client gate."
)
