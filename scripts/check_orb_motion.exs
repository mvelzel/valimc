alias Valimc.Physics.OrbMotion
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
true = data["version"] == "26.3"
true = data["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
true = length(data["launches"]) == 56 and length(data["ticks"]) == 5184
true = length(data["ages"]) == 5

bits = fn vector ->
  for n <- Tuple.to_list(vector),
      do: Base.encode16(<<n::float-64>>, case: :lower)
end

tuple = fn
  nil -> nil
  list -> List.to_tuple(list)
end

Enum.each(data["launches"], fn row ->
  {:ok, result} =
    OrbMotion.launch(tuple.(row["position"]), tuple.(row["direction"]), tuple.(row["draws"]))

  unless bits.(result.position) == row["position_bits"] and
           bits.(result.velocity) == row["velocity_bits"],
         do: raise("Native launch differs: #{inspect({row, result})}")
end)

Enum.each(data["ticks"] ++ data["ages"], fn row ->
  facts = %OrbMotion{
    eye_water: row["water"],
    embedded: row["embedded"],
    no_gravity: row["no_gravity"],
    lava_draws: tuple.(row["lava_draws"]),
    target: tuple.(row["target"]),
    on_ground: row["ground"],
    below: row["below"],
    friction: row["friction"]
  }

  {:ok, requested} = OrbMotion.prepare(tuple.(row["input"]), facts)
  after_move = tuple.(row["post"]) || requested
  {:ok, result} = OrbMotion.finish(after_move, elem(requested, 1), facts)
  {:ok, age} = OrbMotion.tick_age(row["age"])

  unless bits.(requested) == row["requested_bits"] and bits.(result) == row["velocity_bits"] and
           age.age == row["age_after"] and age.expired == row["expired"] and
           row["draw_calls"] == if(facts.lava_draws, do: 4, else: 0),
         do: raise("Native tick differs: #{inspect({row, requested, result, age})}")
end)

IO.puts(
  "PASS: 56 bit-exact native XP launches, 5,184 supplied-contact/collision ticks and 5 age/expiry boundaries. Live motion/selection/escape/merge/current/storage excluded."
)
