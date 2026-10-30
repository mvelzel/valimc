# The guardian lives in a native section; each hit goes through its section
# (`mob_section_hurt`), its health and its queued thorns read back from it.
alias Valimc.Entity.{Body, Store}
alias Valimc.Native
Valimc.Entity.MobFacts.install!()
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 36, do: raise("Incomplete guardian hurt fixtures")

for row <- cases do
  {:ok, body} = Body.new(row["type"])
  body = %{body | data: %{body.data | moving: row["moving"]}}
  entity = %{uuid: <<1::128>>, entity_id: 100, x: 0.0, y: 64.0, z: 0.0}

  player = %{
    uuid: <<2::128>>,
    entity_id: 1,
    player: true,
    type: "minecraft:player",
    mainhand: nil
  }

  direct =
    if row["direct"] == "minecraft:player",
      do: player,
      else: %{uuid: <<3::128>>, entity_id: 2, player: false, type: row["direct"], mainhand: nil}

  hit = %{
    source: Valimc.Living.DamageSource.new(String.to_existing_atom(row["source"])),
    amount: 1.0,
    attacker: player,
    direct: direct,
    position: {2.0, 64.0, 0.0}
  }

  section = Native.mob_section_oracle_new()
  record = Store.body_record(body, entity.uuid, {entity.x, entity.y, entity.z})
  {:ok, [_]} = Native.mob_section_insert(section, [{100, record}], false)
  :ok = Native.mob_section_oracle_prepare(section, 100, 0.0, nil)

  for step <- row["trace"] do
    {:ok, {{hurt, _, _, _, _}, _, _}} = Native.mob_section_hurt(section, 100, hit)
    {health, _, _, _, _, _} = Native.mob_section_oracle_health(section, 100)

    thorns =
      case Native.mob_section_oracle_mind(section, 100) do
        %{own: %{thorns: thorns}} -> length(thorns)
        _ -> 0
      end

    actual = %{accepted: hurt, health: health, thorns: thorns}
    expected = %{accepted: step["accepted"], health: step["health"], thorns: step["thorns"]}

    if actual != expected,
      do:
        raise(
          "#{inspect(Map.delete(row, "trace"))}: #{inspect(actual)} != vanilla #{inspect(expected)}"
        )
  end
end

IO.puts(
  "PASS: 36 native guardian/elder hurt, refusal, direct-attacker and thorns-avoidance cases, every hit on a native guardian"
)
