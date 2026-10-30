# Each dragon lives in a native section; its timers
# (`Native.dragon_oracle_actor/4`), hits (`mob_section_hurt`, the part
# decoded from the hit), arrow ignition and phase metadata (its row's shown
# values) are the native dragon's, its health and data read back from it.
alias Valimc.Entity.{Body, Store}
alias Valimc.Living.DamageSource
alias Valimc.Native

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()
Valimc.Entity.MobFacts.install!()

# A native dragon of `body` at the check's position: its section.
native_dragon = fn body ->
  ref = Native.mob_section_oracle_new()
  record = Store.body_record(body, <<4507::128>>, {0.0, 80.0, 0.0})
  {:ok, [{1, _, row}]} = Native.mob_section_insert(ref, [{1, record}], false)
  health = body.mob.living.health

  {_, _} =
    Native.mob_section_oracle_put(ref, 1, record, {health.cooldown, health.last_hurt * 1.0})

  {ref, row}
end

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

for row <- raw["cases"] do
  {:ok, body} = Body.new("minecraft:ender_dragon")
  scene = row["scene"]

  health = %{
    body.mob.living.health
    | value: if(scene == 0, do: 200.0, else: 4.0),
      cooldown: if(scene == 0, do: 0, else: 20),
      last_hurt: if(scene == 0, do: 0.0, else: 3.0)
  }

  body = %{
    body
    | mob: %{body.mob | living: %{body.mob.living | health: health}},
      data: %{
        body.data
        | phase: row["phase"],
          sitting_damage: if(scene == 0, do: 49.0, else: 0.0)
      }
  }

  source = row["source"]
  player = source in ~w(player_attack arrow trident wind_charge)

  attacker =
    if source in ~w(generic magic in_fire generic_kill explosion),
      do: nil,
      else: %{
        uuid: <<1::128>>,
        entity_id: 1,
        player: player,
        type: if(player, do: "minecraft:player", else: "minecraft:zombie"),
        mainhand: nil
      }

  direct =
    if source in ~w(arrow trident wind_charge),
      do: %{type: "minecraft:" <> source, uuid: <<2::128>>, entity_id: 2, player: false},
      else: attacker

  {section, _} = native_dragon.(body)

  for expected <- row["hits"] do
    :ok = Native.dragon_oracle_actor(section, 1, {:timers, expected["delay"]}, %{})

    hit = %{
      source: DamageSource.new(String.to_existing_atom(source)),
      amount: expected["amount"],
      attacker: attacker,
      direct: direct,
      position: {-2.0, 80.0, 3.0},
      dragon_part: row["part"]
    }

    ignites = Native.dragon_oracle_actor(section, 1, {:ignites, hit}, %{})
    hit = %{hit | amount: hit.amount * 1.0}
    {:ok, {{admitted, _, _, _, _}, _, _}} = Native.mob_section_hurt(section, 1, hit)
    {value, _, hurt, _, cooldown, last} = Native.mob_section_oracle_health(section, 1)
    {:ok, restored} = Body.restore(hd(Native.mob_section_records(section, [1])))

    actual = %{
      "admitted" => admitted,
      "health" => value,
      "cooldown" => cooldown,
      "hurt_time" => hurt,
      "last_hurt" => last,
      "sitting_damage" => restored.data.sitting_damage,
      "phase" => restored.data.phase,
      "projectile_fire" => if(ignites, do: 20, else: 0)
    }

    for {key, value} <- actual,
        value != expected[key],
        do:
          raise(
            "dragon damage differs #{inspect(Map.drop(row, ["hits"]))} #{inspect(expected)} #{key}=#{inspect(value)}"
          )
  end
end

for row <- raw["packets"] do
  {:ok, body} = Body.new("minecraft:ender_dragon")
  body = put_in(body.data.phase, row["phase"])

  {_, %{shown: {shown, _, _, _}}} = native_dragon.(body)

  values =
    for {:dragon_phase, value, default} <- shown,
        value != default,
        do: {:dragon_phase, value}

  {id, bytes} = Valimc.Protocol.EntityPackets.metadata(300, values)

  actual =
    Base.encode16(IO.iodata_to_binary([Valimc.Protocol.Wire.varint(id), bytes]), case: :lower)

  unless actual == row["wire"],
    do: raise("dragon phase metadata differs #{inspect(row)}: #{actual}")
end

IO.puts(
  "PASS: #{length(raw["cases"])} native multipart dragon damage sequences, #{Enum.sum(Enum.map(raw["cases"], &length(&1["hits"])))} hits, every hit on the native dragon"
)
