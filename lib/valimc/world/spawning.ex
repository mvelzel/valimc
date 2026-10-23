defmodule Valimc.World.Spawning do
  @moduledoc """
  Natural spawning and despawning (VMC-042a): vanilla's `NaturalSpawner`,
  run by each group over its simulated chunks once a tick, and
  `Mob.checkDespawn` for its mobs there.

  The spawn kernel (`valimc_core::spawning`, one NIF call per tick) reads the
  group's sections. Its caps count what the group holds: every mob that is
  not persistent counts toward its category, a mob near a player toward
  that player's local cap, and the global cap scales with the chunks near
  the group's players. Groups keep their loaded chunks at least 24 chunks
  apart, so a player's spawning chunks and the mobs near it are always in
  its own group and no process counts mobs across groups.

  Per tick, `plan/1` gives what each section adopts and loses: the mobs that
  spawned (plain bodies of their type), the mobs that despawn and those
  whose idle time restarts. A group's level random and its mobs' random are
  its own; the generated chunks' creatures (`generated/3`) draw from each
  chunk's decoration seed, as vanilla's do.

  The sky darkening (`darken/4`) follows vanilla's environment attributes:
  the dimension's sky light level, the day timeline and the weather.
  """
  alias Valimc.Data.{Float32, Grid, JavaRandom, SpawnFacts}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Native
  alias Valimc.Protocol.Data
  alias Valimc.World.{Clock, Dimension, GameRules}

  @doc "Install the spawn kernel's facts once per VM (after the block facts)."
  def install! do
    if not :persistent_term.get({__MODULE__, :installed}, false) do
      Valimc.Data.BlockFacts.install!()
      biomes = Data.registries()["minecraft:worldgen/biome"]
      ids = Map.new(biomes, &{&1, Data.registry_id("minecraft:worldgen/biome", &1)})
      tags = Data.tags()["minecraft:worldgen/biome"]
      {:ok, _} = Native.spawn_facts_install(SpawnFacts.native(ids, tags))
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  @doc """
  Whether an owner of `scope` (a section key) spawns naturally: on unless
  the `:natural_spawning` setting says otherwise (the test suite turns it off,
  and tests turn it on per scope).
  """
  def enabled?(scope) do
    if Application.get_env(:valimc, :natural_spawning) == nil,
      do: true,
      else: Valimc.config(:natural_spawning, scope)
  end

  @doc "A group's spawning state: its level random and its mobs' random."
  def new, do: %{random: JavaRandom.create(), mobs: JavaRandom.create()}

  ## The sky

  @doc """
  `skyDarken` (`updateSkyBrightness`): 15 less the dimension's sky light
  level after its day timeline at `ticks` of its clock and the weather's
  `rain` and `thunder` levels (vanilla's `getRainLevel` and
  `getThunderLevel`, the latter already scaled by the rain).
  """
  def darken(dimension, ticks, rain, thunder) do
    facts = SpawnFacts.dimension(dimension)
    level = Float32.round(facts["sky_light_level"])

    level =
      case facts["tracks"]["sky_light_level"] do
        nil -> level
        track -> Float32.round(level * sample(track, ticks))
      end

    rain = Float32.round(rain - thunder)
    level = if rain > 0, do: lerp(rain, level, lerp(0.3125, level, 4.0)), else: level
    level = if thunder > 0, do: lerp(thunder, level, lerp(0.52734375, level, 4.0)), else: level
    trunc(Float32.round(15.0 - level))
  end

  @doc "The surface slime chance at `ticks` of the dimension's clock (the moon timeline)."
  def slime_chance(dimension, ticks) do
    case SpawnFacts.dimension(dimension)["tracks"]["surface_slime_spawn_chance"] do
      nil -> 0.0
      track -> max(0.0, sample(track, ticks))
    end
  end

  # `Mth.lerp(float, float, float)`.
  defp lerp(delta, a, b),
    do: Float32.round(a + Float32.round(delta * Float32.round(b - a)))

  # `KeyframeTrackSampler.sample` over a looping track.
  defp sample(%{"keyframes" => frames, "period" => period, "ease" => ease}, ticks) do
    [{first_t, first} | _] = frames = Enum.map(frames, fn [t, v] -> {t, Float32.round(v)} end)
    {last_t, last} = List.last(frames)

    segments =
      [{last, last_t - period, first, first_t}] ++
        (frames
         |> Enum.chunk_every(2, 1, :discard)
         |> Enum.map(fn [{a, x}, {b, y}] -> {x, a, y, b} end)) ++
        [{last, last_t, first, first_t + period}]

    t = Integer.mod(ticks, period)

    {from_v, from, to_v, to} =
      Enum.find(segments, List.last(segments), fn {_, _, _, b} -> t < b end)

    cond do
      t <= from ->
        from_v

      t >= to ->
        to_v

      true ->
        alpha = Float32.round(Float32.round((t - from) * 1.0) / (to - from))
        eased = if ease == "constant", do: 0.0, else: alpha
        lerp(eased, from_v, to_v)
    end
  end

  ## A tick

  @doc """
  The environment of a tick in `dimension` (an atom), from the published
  clock, weather and difficulty.
  """
  def environment(dimension) do
    name = Dimension.name(dimension)
    facts = Dimension.facts(dimension)
    ticks = Clock.day_ticks()
    %{rain_level: rain, thunder_level: thunder} = weather(dimension)
    thunder = Float32.round(thunder * rain)
    {difficulty, _} = Clock.difficulty()
    {x0, z0, x1, z1} = Valimc.World.Border.bounds(Clock.border(name))
    {zoom, seed} = seeds(dimension)

    %{
      dimension: name,
      zoom_seed: zoom,
      seed: seed,
      sea_level: facts.sea_level,
      max_y: facts.min_y + facts.height - 1,
      darken: darken(name, ticks, rain, thunder),
      thundering: dimension == :overworld and thunder > 0.9,
      difficulty: difficulty.level,
      slime_chance: slime_chance(name, ticks),
      border: {x0, z0, x1, z1}
    }
  end

  defp weather(:overworld), do: Clock.weather()
  defp weather(_dimension), do: %{rain_level: 0.0, thunder_level: 0.0}

  defp seeds(dimension) do
    {zoom, _} = Valimc.World.Spec.client_info(Valimc.World.Spec.current(), dimension)
    {zoom, Valimc.World.Spec.current().seed}
  end

  @doc """
  One tick of spawning and despawning for a group: `group` holds its
  `sections` (`%{key => resource}`), its `stores` (the first section's region
  handle and the others'), `absent` chunks, `players` (`{x, y, z, spectator,
  creative}`), its `spawning` state and the tick's `environment`. Returns
  `{spawning, %{key => {records, discards, resets}}}`.
  """
  def plan(%{players: []} = group), do: {group.spawning, %{}}

  def plan(group) do
    env = group.environment

    {mobs, bodies, simulated} =
      Enum.reduce(group.sections, {[], [], []}, fn {_key, resource}, {mobs, bodies, chunks} ->
        ticking = resource.tickets.simulated

        Enum.reduce(
          resource.entities.store.entries,
          {mobs, bodies, MapSet.to_list(ticking) ++ chunks},
          fn
            {id, %{kind: :mob, entity: e, body: %{type: type, mob: mob}} = entry},
            {mobs, bodies, chunks} ->
              alive = Valimc.Entity.Mob.alive?(mob)

              flags =
                if(mob.persistent, do: 1, else: 0) +
                  if(alive and MapSet.member?(ticking, Grid.chunk_key(e.x, e.z)), do: 2, else: 0)

              idle = Map.get(entry, :idle, 0)
              lived = Map.get(entry, :lived, 0)

              {[
                 {id, Valimc.Data.EntityTypes.id(type), {e.x, e.y, e.z}, flags, idle, lived}
                 | mobs
               ], [box(type, e) | bodies], chunks}

            # Primed TNT and falling blocks block a spawn too (`blocksBuilding`).
            {_, %{kind: :object, entity: e, body: %{type: type}}}, {mobs, bodies, chunks} ->
              {mobs, [box(type, e) | bodies], chunks}

            _, acc ->
              acc
          end
        )
      end)

    bodies =
      bodies ++
        for {x, y, z, _, _} <- group.players, do: {x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3}

    rules = GameRules.get(:spawn_mobs)

    request = %{
      environment: env,
      players: group.players,
      bodies: bodies,
      mobs: mobs,
      chunks: if(rules, do: Enum.uniq(simulated), else: []),
      respawn: respawn(env.dimension),
      enemies: env.difficulty != 0 and GameRules.get(:spawn_monsters),
      persistent: rem(group.game_time, 400) == 0,
      random: group.spawning.random,
      finalize: group.spawning.mobs
    }

    [region | siblings] = group.stores
    units = max(1, length(request.chunks)) * 7

    {:ok, {spawned, discarded, reset, random, finalize}} =
      Native.dispatch(:natural_spawn, units, [region, siblings, group.absent, request])

    by_section =
      Enum.reduce(spawned, %{}, fn {kind, x, y, z, yaw, _school}, acc ->
        case Body.new(Valimc.Data.EntityTypes.name(kind)) do
          {:ok, body} ->
            body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}
            record = Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y, z})
            key = Grid.region_key(Grid.chunk_key(x, z))
            Map.update(acc, key, {[record], [], []}, fn {r, d, s} -> {[record | r], d, s} end)

          {:error, _} ->
            acc
        end
      end)

    by_section =
      Enum.reduce(group.sections, by_section, fn {key, resource}, acc ->
        entries = resource.entities.store.entries
        discards = for id <- discarded, Map.has_key?(entries, id), do: id
        resets = for id <- reset, Map.has_key?(entries, id), do: id

        if discards == [] and resets == [],
          do: acc,
          else:
            Map.update(acc, key, {[], discards, resets}, fn {r, _, _} -> {r, discards, resets} end)
      end)

    {%{group.spawning | random: random, mobs: finalize}, by_section}
  end

  @doc """
  The records of the creatures that generated `chunks` of section `state`
  (a `RegionData`) get with them (`spawnMobsForChunkGeneration`), unless the
  `spawn_mobs` rule is off. Their positions and yaws are vanilla's for the
  world seed; what their `finalizeSpawn` decides is their families'.
  """
  def generated(state, chunks) do
    if chunks == [] or not GameRules.get(:spawn_mobs) do
      []
    else
      env = environment(state.dimension)
      absent = MapSet.to_list(state.generation.absent)

      {:ok, spawned} =
        Native.spawn_generated(state.blocks.ref, [], absent, env, Enum.sort(chunks))

      for {_chunk, list} <- spawned,
          {kind, x, y, z, yaw, _} <- list,
          {:ok, body} <- [Body.new(Valimc.Data.EntityTypes.name(kind))] do
        body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}
        Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y, z})
      end
    end
  end

  defp box(type, %{x: x, y: y, z: z}) do
    %{width: w, height: h} = Valimc.Data.EntityTypes.fetch(type)
    {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
  end

  defp respawn(dimension) do
    if Dimension.name(Valimc.World.Spawn.dimension()) == dimension,
      do: Valimc.World.Spawn.position()
  end
end
