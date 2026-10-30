# Each dragon lives in a native section and ticks as the native actor
# (`Native.dragon_oracle_actor/4`: its timers, then its tick; a destroyed
# crystal) over a hand-built env (graph heights, podium, the player, sight,
# blocks and ground, its contact targets, crystals and rules); its phases
# start through `dragon_oracle_phases/3`, and the checks read its body from
# its record. Its actor is the term the record keeps (maps tagged
# `Valimc.Entity.Dragon.Actor`, `.Phases` and `.Flight`).
alias Valimc.Data.JavaRandom
alias Valimc.Entity.{Body, Dragon, Store}
alias Valimc.Native

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()
Valimc.Entity.MobFacts.install!()
end_stone = Valimc.Data.Blocks.default_state("end_stone")

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

defmodule DragonActorCheck do
  def equal(a, b, label) when is_tuple(b), do: equal(a, Tuple.to_list(b), label)
  def equal(a, b, label) when is_tuple(a), do: equal(Tuple.to_list(a), b, label)

  def equal(a, b, label) when is_list(a) and is_list(b) do
    if length(a) != length(b), do: raise("#{label}: lengths #{inspect({a, b})}")
    Enum.zip(a, b) |> Enum.each(fn {a, b} -> equal(a, b, label) end)
  end

  def equal(a, b, label) when is_number(a) and is_number(b) do
    if abs(a - b) > 1.0e-9, do: raise("#{label}: #{inspect(a)} != #{inspect(b)}")
  end

  def equal(a, a, _), do: :ok
  def equal(a, b, label), do: raise("#{label}: #{inspect(a)} != #{inspect(b)}")

  def bits(n) do
    <<b::signed-32>> = <<n::float-32>>
    b
  end

  # The phases term of a fresh dragon flying from `position` at yaw 25.
  def phases(position, random) do
    flight = %{
      __struct__: Valimc.Entity.Dragon.Flight,
      position: position,
      velocity: {0.0, 0.0, 0.0},
      yaw: 25.0,
      turn: 0.0,
      history: nil,
      parts: Tuple.duplicate({0.0, 0.0, 0.0}, 8)
    }

    %{
      __struct__: Valimc.Entity.Dragon.Phases,
      phase: 10,
      flight: flight,
      random: random,
      target: nil,
      leaving: nil,
      path: nil,
      clockwise: %{0 => false, 1 => false},
      ticks: 0,
      flames: 0,
      attack: nil,
      charge: 0,
      first: true,
      flame_live: false,
      head_yaw: 0.0,
      pitch: 0.0,
      effects: []
    }
  end

  # The actor term holding `phases`.
  def actor(phases) do
    %{
      __struct__: Valimc.Entity.Dragon.Actor,
      phases: phases,
      tick: 0,
      ambient: 0,
      body_yaw: 0.0,
      stable_head: 0.0,
      stable_time: 0,
      wall: false,
      crystal: nil,
      flame: nil,
      graph: nil,
      world_tick: nil
    }
  end
end

for row <- raw["cases"] do
  scene = row["scene"] || 0
  dead = row["death"] == true
  initial = List.to_tuple(row["position"])
  {x, y, z} = initial
  {:ok, body} = Body.new("minecraft:ender_dragon")

  body = %{
    body
    | yaw: 25.0,
      head_yaw: 25.0,
      data: %{body.data | phase: row["start_phase"] || 10},
      mob: %{body.mob | no_ai: scene == 1}
  }

  body = put_in(body.mob.living.health.value, if(dead, do: 0.0, else: 180.0))
  entity = %{x: x, y: y, z: z, uuid: <<4505::128>>}

  blocks =
    Map.new(row["blocks"] || [], fn row ->
      {row["position"] |> Enum.map(&trunc/1) |> List.to_tuple(), row["state"]}
    end)

  crystal = if dead, do: nil, else: List.to_tuple(row["crystal_position"])

  crystal_row =
    if crystal do
      {cx, cy, cz} = crystal
      %{uuid: 800, position: crystal, box: {cx - 1, cy, cz - 1, cx + 1, cy + 2, cz + 1}}
    end

  player = %{id: row["player_id"], position: {8.0, 90.0, 2.0}, height: 1.7999999523162842}
  phase_scene = %{height: 90}
  start = DragonActorCheck.phases(initial, JavaRandom.new(7241 + scene))
  {phases, _} = Native.dragon_oracle_phases(start, {:set, body.data.phase}, phase_scene)

  phases =
    cond do
      phases.phase == 1 ->
        elem(Native.dragon_oracle_phases(phases, {:strafe, player}, phase_scene), 0)

      phases.phase == 8 ->
        %{phases | target: player.position}

      true ->
        phases
    end

  body = %{
    body
    | data: %{body.data | brain: DragonActorCheck.actor(phases)},
      mob: %{body.mob | ai: %{random: phases.random}}
  }

  # The native dragon's section.
  section = Native.mob_section_oracle_new()
  record = Store.body_record(body, entity.uuid, initial)
  {:ok, [_]} = Native.mob_section_insert(section, [{1, record}], false)

  crystal_uuid = <<800::128>>

  native_body = fn ->
    {:ok, body} = Body.restore(hd(Native.mob_section_records(section, [1])))
    body
  end

  native_scene = fn blocks, index ->
    %{
      height: 90,
      podium: {0, 90, 0},
      players: if(dead, do: [], else: [player]),
      sees: true,
      blocks: Enum.to_list(blocks),
      floor: 70,
      ground: end_stone,
      targets:
        if(dead,
          do: [],
          else: [
            {:player, <<1::128>>, player.position, index < 2,
             {7.7, 90.0, 1.7, 8.3, 91.79999995231628, 2.3}}
          ]
        ),
      crystal_bodies:
        if(crystal_row && index < 100,
          do: [{crystal_uuid, crystal_row.position, crystal_row.box}],
          else: []
        ),
      crystals: nil,
      mob_griefing: scene != 3,
      mob_drops: true,
      previous_kill: row["previous"] != false
    }
  end

  Enum.with_index(row["ticks"])
  |> Enum.reduce(blocks, fn {tick, index}, blocks ->
    if not dead and index == 100 do
      striker =
        {player.id, player.position, player.height, true,
         %{uuid: <<1::128>>, entity_id: player.id, player: true, type: "minecraft:player"}}

      _ =
        Native.dragon_oracle_actor(
          section,
          1,
          {:crystal, crystal_uuid, {crystal_uuid, 800, crystal}, striker},
          native_scene.(blocks, index)
        )
    end

    {at, events, effects} =
      Native.dragon_oracle_actor(section, 1, :tick, native_scene.(blocks, index))

    body = native_body.()
    actor = body.data.brain

    actor =
      case actor.crystal do
        <<n::128>> -> %{actor | crystal: n}
        _ -> actor
      end

    label = "phase #{row["start_phase"]} scene #{scene} death #{dead} tick #{index + 1}"

    for {key, value} <- [
          {"phase", body.data.phase},
          {"position", at},
          {"velocity", body.velocity},
          {"yaw", body.yaw},
          {"head", body.head_yaw},
          {"body_yaw", actor.body_yaw},
          {"random", body.mob.ai.random},
          {"ambient", actor.ambient},
          {"wall", actor.wall},
          {"death_time", body.data.death_time},
          {"health", body.mob.living.health.value},
          {"crystal", actor.crystal || -1},
          {"removed", :discard in effects}
        ] do
      DragonActorCheck.equal(value, tick[key], label <> " " <> key)
    end

    DragonActorCheck.equal(
      Dragon.boxes(actor.phases.flight.parts),
      tick["parts"],
      label <> " parts"
    )

    removed = for {:dragon_break, cell, _} <- effects, do: cell
    DragonActorCheck.equal(removed, tick["breaks"], label <> " breaks")
    particles = for {:particles, name, at, _, _, _} <- events, do: {name, at}
    expected = for p <- tick["particles"], do: {p["name"], p["position"]}
    DragonActorCheck.equal(particles, expected, label <> " particles")
    xp = for {:dragon_xp, amount, at} <- effects, do: {at, amount}

    expected_xp =
      tick["added"]
      |> Enum.filter(&(&1["type"] == "minecraft:experience_orb"))
      |> Enum.chunk_by(& &1["position"])
      |> Enum.map(fn orbs -> {hd(orbs)["position"], Enum.sum(Enum.map(orbs, & &1["xp"]))} end)

    DragonActorCheck.equal(xp, expected_xp, label <> " xp")

    sounds =
      for {:sound, id, _, volume, pitch, _} <- events,
          do: {id, DragonActorCheck.bits(volume), DragonActorCheck.bits(pitch)}

    expected_sounds =
      for e <- tick["events"],
          e["sound"],
          do: {e["sound"], e["volume"], e["pitch"]}

    DragonActorCheck.equal(sounds, expected_sounds, label <> " sound")
    world_events = for {:level_event, at, id, data} <- effects, do: {id, at, data}
    expected_events = for e <- tick["events"], e["event"], do: {e["event"], e["at"], e["data"]}
    DragonActorCheck.equal(world_events, expected_events, label <> " level events")

    DragonActorCheck.equal(
      for({:global_event, id} <- effects, do: id),
      tick["global"],
      label <> " global events"
    )

    spawned =
      for effect <- actor.phases.effects,
          match?({:fireball, _, _}, effect) or match?({:flame, _}, effect),
          do: effect

    spawned = if dead, do: [], else: spawned
    expected_spawned = Enum.filter(tick["added"], &(&1["type"] != "minecraft:experience_orb"))
    DragonActorCheck.equal(length(spawned), length(expected_spawned), label <> " spawned effects")

    for {effect, expected} <- Enum.zip(spawned, expected_spawned) do
      case effect do
        {:fireball, at, direction} ->
          true = expected["type"] == "minecraft:dragon_fireball"
          DragonActorCheck.equal(at, expected["position"], label <> " fireball origin")
          DragonActorCheck.equal(direction, expected["direction"], label <> " fireball direction")

        {:flame, at} ->
          true =
            expected["type"] == "minecraft:area_effect_cloud" and expected["radius"] == 5.0 and
              expected["duration"] == 200

          DragonActorCheck.equal(at, expected["position"], label <> " flame origin")
      end
    end

    unless dead do
      contacts = for {:dragon_contact, _, push, amount, _} <- effects, do: {push, amount}

      pushed =
        Enum.reduce(contacts, {0.0, 0.0, 0.0}, fn {{x, y, z}, _}, {a, b, c} ->
          {x + a, y + b, z + c}
        end)

      DragonActorCheck.equal(pushed, tick["push"], label <> " contact push")
      hits = for {_, amount} <- contacts, amount > 0.0, do: DragonActorCheck.bits(amount)

      DragonActorCheck.equal(
        hits,
        Enum.map(tick["hits"], & &1["amount"]),
        label <> " contact hits"
      )
    end

    Enum.reduce(removed, blocks, &Map.put(&2, &1, 0))
  end)
end

Valimc.World.Spawning.install!()

for [difficulty, distance, persistent, removed, idle] <- raw["despawn"] do
  {:ok, got} =
    Valimc.Native.spawn_despawn(
      Valimc.Data.EntityTypes.id("minecraft:ender_dragon"),
      difficulty,
      distance * 1.0,
      persistent
    )

  if got != {removed, idle},
    do: raise("dragon despawn: #{inspect(got)} != #{inspect({removed, idle})}")
end

IO.puts(
  "PASS: #{length(raw["cases"])} complete native dragon sequences, #{Enum.sum(Enum.map(raw["cases"], &length(&1["ticks"])))} ticks, crystal healing, wall breaking, inherited rotation/random and death/XP, every tick the native dragon's"
)
