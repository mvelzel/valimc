alias Valimc.Entity.{Body, EndCrystal, Store}
alias Valimc.Living.DamageSource
alias Valimc.Protocol.{EntityPackets, Wire}

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

for row <- raw["placement"] do
  read = fn
    {-3, 70, 4} -> row["base"]
    {-3, 71, 4} -> row["above"]
    _ -> Valimc.Data.Blocks.default_state("stone")
  end

  result = EndCrystal.placement({-3, 70, 4}, read, [List.to_tuple(row["box"])])
  true = match?({:ok, _}, result) == row["placed"]
  true = row["count"] == if(row["placed"], do: 1, else: 2)
  if row["placed"], do: true = result == {:ok, List.to_tuple(row["position"])}
end

for row <- raw["damage"] do
  {:ok, body} = Body.new(EndCrystal.type())
  body = put_in(body.data.invulnerable, row["invulnerable"])
  store = Store.new()

  {:ok, store, {_, id, _}} =
    Store.create_record(store, {0, 0}, Store.body_record(body, <<1::128>>, {1.5, 80.0, 2.5}))

  source =
    case row["source"] do
      "dragon" -> :mob_attack
      mode when mode in ["creative", "survival"] -> :player_attack
      source -> String.to_existing_atom(source)
    end

  hit = %{source: DamageSource.new(source), amount: row["amount"]}

  hit =
    if row["source"] == "dragon",
      do: Map.put(hit, :attacker, %{type: "minecraft:ender_dragon"}),
      else: hit

  hit = if row["source"] == "creative", do: Map.put(hit, :attacker, %{creative: true}), else: hit

  {:ok, next, outcome} = Valimc.Entity.Combat.hurt(store, id, hit)

  unless outcome.hurt == row["hurt"],
    do: raise("crystal damage differs: #{inspect({row, outcome})}")

  true = next.entries[id] == nil == row["removed"]
  true = if(outcome[:explode], do: 1, else: 0) == row["explosions"]

  if outcome[:explode],
    do: true = Valimc.World.Explosion.crystal(outcome.crystal).radius == row["power"]
end

for row <- raw["packets"] do
  {:ok, body} = Body.new(EndCrystal.type())
  beam = if row["beam"], do: row["beam"] |> Enum.map(&trunc/1) |> List.to_tuple()
  body = %{body | data: %{body.data | bottom: row["bottom"], beam: beam}}
  values = for {key, value, default} <- Body.values(body), value != default, do: {key, value}
  {id, bytes} = EntityPackets.metadata(300, values)
  true = Base.encode16(IO.iodata_to_binary([Wire.varint(id), bytes]), case: :lower) == row["wire"]
end

IO.puts(
  "PASS: #{length(raw["placement"])} crystal placements, #{length(raw["damage"])} native damage cases and #{length(raw["packets"])} packets"
)
