alias Valimc.Entity.{Body, Combat, Projectile, ShulkerBullet}
alias Valimc.Physics.Kernel
alias Valimc.Protocol.{CombatPackets, Data, Wire}
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 18, do: raise("Incomplete bullet feedback fixtures")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

point = fn list -> list |> Enum.map(double) |> List.to_tuple() end
sound_id = Data.id(:play, :clientbound, "sound")
sound_ids = Valimc.Data.Facts.read!("registry/ai_facts.json")["sounds"]

for row <- rows do
  at = {x, y, z} = point.(row["position"])
  {:ok, body} = Body.new("minecraft:shulker_bullet")
  entity = %{entity_id: 42, uuid: <<1::128>>, x: x, y: y, z: z}
  entry = %{kind: :object, entity: entity, body: body}

  events =
    case row["mode"] do
      "hurt" ->
        {:remove, outcome} = Combat.resolve(entry, %{amount: row["amount"]})
        true = outcome.hurt == row["accepted"]
        Map.get(outcome, :feedback, [])

      "block" ->
        ShulkerBullet.feedback(:block, at)

      "block_tick" ->
        states =
          for a <- (floor(x) - 4)..(floor(x) + 4),
              b <- (floor(y) - 4)..(floor(y) + 4),
              c <- (floor(z) - 4)..(floor(z) + 4),
              into: %{},
              do: {{a, b, c}, 0}

        states =
          Map.put(
            states,
            {floor(x + 1), floor(y), floor(z)},
            Valimc.Data.Blocks.default_state("stone")
          )

        view = Valimc.World.View.of(states)
        body = %{body | no_gravity: true, velocity: {0.8, 0.0, 0.0}}
        input = Projectile.input(body, at, {0.0, 0.0, 0.0})

        {:ok, [result]} =
          Valimc.Native.physics_projectiles(
            Kernel.native(view, {x - 3, y - 3, z - 3, x + 4, y + 4, z + 4}),
            [input],
            [],
            nil,
            false
          )

        {:remove, effects} =
          Valimc.World.Projectiles.plan(%{entry | body: body}, result, %{}, %{
            read: fn p -> states[p] end,
            difficulty: :normal
          })

        effects
    end

  packets =
    Enum.map(events, fn event ->
      {id, payload} =
        case event do
          {:sound, name, source, position, volume, pitch} ->
            CombatPackets.sound(
              Map.fetch!(sound_ids, name),
              source,
              position,
              volume,
              pitch,
              0
            )

          _ ->
            Body.event_packet(42, event, entity)
        end

      payload = IO.iodata_to_binary(payload)

      payload =
        if id == sound_id,
          do: binary_part(payload, 0, byte_size(payload) - 8) <> <<0::64>>,
          else: payload

      IO.iodata_to_binary([Wire.varint(id), payload]) |> Base.encode16(case: :lower)
    end)

  unless packets == row["packets"],
    do: raise("#{row["mode"]} feedback #{inspect(packets)} != native #{inspect(row["packets"])}")

  true = row["removed"]
end

IO.puts(
  "PASS: 18 native bullet hurt/block callbacks and exact feedback packets, including the actual impact tick's feedback position"
)
