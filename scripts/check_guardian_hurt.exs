# `--native` (VMC-081d): the guardian lives in a native section; each hit
# goes through its section (`mob_section_hurt`), its health and its queued
# thorns read back from it.
alias Valimc.AI.{Self, World}
alias Valimc.Entity.{Body, Combat, Store}
alias Valimc.Native
{native, argv} = Enum.split_with(System.argv(), &(&1 == "--native"))
native? = native != []
if native?, do: Valimc.Entity.NativeMobs.install!()
[path] = argv
cases = JSON.decode!(File.read!(path))
unless length(cases) == 36, do: raise("Incomplete guardian hurt fixtures")

for row <- cases do
  {:ok, body} = Body.new(row["type"])

  body = %{
    body
    | data: %{body.data | moving: row["moving"]},
      mob: %{body.mob | ai: Valimc.AI.mind(body.type, <<1::128>>, nil)}
  }

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

  section =
    if native? do
      ref = Native.mob_section_oracle_new()
      record = Store.body_record(body, entity.uuid, {entity.x, entity.y, entity.z})
      {:ok, [_]} = Native.mob_section_insert(ref, [{100, record}], false)
      :ok = Native.mob_section_oracle_prepare(ref, 100, 0.0, nil)
      ref
    end

  Enum.reduce(row["trace"], body, fn step, body ->
    if native? do
      {:ok, {{hurt, _, _, _, _}, _, _}} = Native.mob_section_hurt(section, nil, 100, hit)
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
            "#{inspect(Map.delete(row, "trace"))}: #{inspect(actual)} != native #{inspect(expected)}"
          )

      body
    else
      {change, outcome} = Combat.resolve(%{kind: :mob, body: body, entity: entity}, hit)

      body =
        case change do
          :keep -> body
          {:body, next, _} -> next
        end

      thorns =
        case body.mob.ai.own do
          %{thorns: thorns} -> length(thorns)
          _ -> 0
        end

      actual = %{accepted: outcome.hurt, health: body.mob.living.health.value, thorns: thorns}
      expected = %{accepted: step["accepted"], health: step["health"], thorns: step["thorns"]}

      if actual != expected,
        do:
          raise(
            "#{inspect(Map.delete(row, "trace"))}: #{inspect(actual)} != native #{inspect(expected)}"
          )

      # Exercise delivery too; retain the queued body's state for the next hit.
      self =
        Valimc.AI.Mobs.Guardian.tick_start(%Self{
          type: body.type,
          data: body.data,
          mob: body.mob,
          mind: body.mob.ai,
          world: %World{}
        })

      true = length(self.effects) == thorns
      body
    end
  end)
end

IO.puts(
  "PASS: 36 native guardian/elder hurt, refusal, direct-attacker and thorns-avoidance cases" <>
    if(native?, do: ", every hit on a native guardian", else: "")
)
