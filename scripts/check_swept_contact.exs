alias Valimc.Data.Box
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

for c <- cases["sweeps"] do
  boxes = Enum.map(c["boxes"], &List.to_tuple/1)
  actual = Box.collided_along?(List.to_tuple(c["body"]), List.to_tuple(c["movement"]), boxes)
  unless actual == c["hit"], do: raise("Native swept contact mismatch #{inspect(c)} #{actual}")
end

for c <- cases["clips"] do
  actual = Box.clip(List.to_tuple(c["box"]), List.to_tuple(c["from"]), List.to_tuple(c["to"]))

  expected = if c["clip"] == :null, do: nil, else: c["clip"]

  unless if(actual, do: Tuple.to_list(actual)) == expected,
    do: raise("Native segment clip mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts(
  "PASS: #{length(cases["sweeps"])} native swept contacts and #{length(cases["clips"])} segment entries."
)
