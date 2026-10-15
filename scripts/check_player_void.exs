alias Valimc.{PlayerInput, PlayerVoid}
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
cases = data["boundaries"]

for c <- cases do
  damage = PlayerVoid.damage(c["y"], c["minimum"])
  calls = if damage > 0, do: 2, else: 0
  source = if damage > 0, do: "minecraft:out_of_world", else: nil

  unless c["calls"] == calls and c["amount"] == damage and c["source"] == source,
    do: raise("Native void threshold/callback differs #{inspect({c, damage})}")
end

for c <- data["loading"] do
  input =
    Enum.reduce(List.duplicate(nil, c["ticks"]), %PlayerInput{}, fn _, input ->
      PlayerInput.tick(input)
    end)

  loaded = PlayerInput.loaded?(input)

  unless loaded == c["loaded"] and c["immune"] == not loaded and not c["marked_immune"],
    do: raise("Native void loading immunity differs #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(cases)} native below-world thresholds/callbacks and #{length(data["loading"])} ServerPlayer loading-immunity cases."
)
