alias Valimc.Entity.{Body, Combat, Dragon}
alias Valimc.Living.DamageSource

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

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

  Enum.reduce(row["hits"], body, fn expected, body ->
    body = Enum.reduce(1..expected["delay"]//1, body, fn _, b -> elem(Dragon.timers(b), 0) end)

    hit = %{
      source: DamageSource.new(String.to_existing_atom(source)),
      amount: expected["amount"],
      attacker: attacker,
      direct: direct,
      position: {-2.0, 80.0, 3.0},
      dragon_part: row["part"]
    }

    fire = if Dragon.ignites?(body, hit), do: 20, else: 0

    {body, admitted} =
      case Combat.hurt_body(body, %{x: 0.0, y: 80.0, z: 0.0}, hit) do
        :ignored -> {body, false}
        {body, _, _} -> {body, true}
      end

    actual = %{
      "admitted" => admitted,
      "health" => body.mob.living.health.value,
      "cooldown" => body.mob.living.health.cooldown,
      "hurt_time" => body.mob.living.health.hurt_ticks,
      "last_hurt" => body.mob.living.health.last_hurt,
      "sitting_damage" => body.data.sitting_damage,
      "phase" => body.data.phase,
      "projectile_fire" => fire
    }

    for {key, value} <- actual,
        value != expected[key],
        do:
          raise(
            "dragon damage differs #{inspect(Map.drop(row, ["hits"]))} #{inspect(expected)} #{key}=#{inspect(value)}"
          )

    body
  end)
end

for row <- raw["packets"] do
  {:ok, body} = Body.new("minecraft:ender_dragon")
  body = put_in(body.data.phase, row["phase"])

  values =
    for {:dragon_phase, value, default} <- Body.values(body),
        value != default,
        do: {:dragon_phase, value}

  {id, bytes} = Valimc.Protocol.EntityPackets.metadata(300, values)

  actual =
    Base.encode16(IO.iodata_to_binary([Valimc.Protocol.Wire.varint(id), bytes]), case: :lower)

  unless actual == row["wire"],
    do: raise("dragon phase metadata differs #{inspect(row)}: #{actual}")
end

IO.puts(
  "PASS: #{length(raw["cases"])} native multipart dragon damage sequences, #{Enum.sum(Enum.map(raw["cases"], &length(&1["hits"])))} hits"
)
