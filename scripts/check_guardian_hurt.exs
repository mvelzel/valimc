alias Valimc.AI.{Self, World}
alias Valimc.Entity.{Body, Combat}
[path] = System.argv()
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

  Enum.reduce(row["trace"], body, fn step, body ->
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
  end)
end

IO.puts(
  "PASS: 36 native guardian/elder hurt, refusal, direct-attacker and thorns-avoidance cases"
)
