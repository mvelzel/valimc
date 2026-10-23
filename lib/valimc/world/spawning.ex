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

  Inside structures (VMC-042b) the spawns follow their overrides: the
  starts a chunk references whose structures override spawns stay with the
  chunk from its generation (`RegionData` `structures`), and a fortress's
  nether bricks spawn its enemies.

  Spawner blocks (VMC-042b) tick in the same kernel call, after the
  natural spawns and despawns: each spawner block entity in a simulated
  chunk with a player in range counts down and spawns its type. Its
  countdown is the group's (`spawners`, by position), starting from the
  `Delay` its block entity saved; a restart or another group starts it
  there again. Its spawn potentials, a spawn data's own position and
  entity data are not modelled: it spawns the type its spawn data names.
  """
  alias Valimc.Blocks.BlockEntityTypes
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
      facts = Map.put(SpawnFacts.native(ids, tags), "structures", overrides())
      {:ok, _} = Native.spawn_facts_install(facts)
      :persistent_term.put({__MODULE__, :installed}, true)
    end

    :ok
  end

  # The structures' spawn overrides as the kernel reads them (VMC-042b):
  # per category whether a piece must hold the spawn, and its spawners as
  # the biomes' are listed.
  defp overrides do
    for {name, categories} <- Valimc.Worldgen.Facts.spawn_overrides(), into: %{} do
      {name,
       Map.new(categories, fn {category, %{"bounding_box" => box, "spawns" => spawns}} ->
         {category, %{"piece" => box == "piece", "spawns" => Enum.map(spawns, &spawner/1)}}
       end)}
    end
  end

  defp spawner(%{"type" => type, "weight" => weight, "count" => count}) do
    case count do
      n when is_integer(n) -> [type, weight, "constant", n, n]
      %{"min_inclusive" => min, "max_inclusive" => max} -> [type, weight, "uniform", min, max]
    end
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

  @doc """
  A group's spawning state: its level random, its mobs' random and its
  spawner blocks' countdowns (`position => {nbt, config, delay}`).
  """
  def new, do: %{random: JavaRandom.create(), mobs: JavaRandom.create(), spawners: %{}}

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

  @doc """
  `Level.isDarkOutside` in `dimension` (an atom) now: its time is not fixed
  and the sky darkens by at least 4 (VMC-040a: beds sleep when dark).
  """
  def dark?(dimension) do
    if Valimc.Data.SleepFacts.dimension(dimension).fixed_time do
      false
    else
      %{rain_level: rain, thunder_level: thunder} = weather(dimension)

      darken(Dimension.name(dimension), Clock.day_ticks(), rain, Float32.round(thunder * rain)) >=
        4
    end
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
  `{spawning, %{key => {records, discards, resets, events}}}`, the events
  the level events of the section's spawner blocks.
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
    {cached, spawners} = spawner_blocks(group)

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
      finalize: group.spawning.mobs,
      spawners: spawners,
      structures: kept_starts(group)
    }

    [region | siblings] = group.stores
    units = max(1, length(request.chunks)) * 7 + length(spawners) * 2

    {:ok, {spawned, discarded, reset, random, finalize, ticked}} =
      Native.dispatch(:natural_spawn, units, [region, siblings, group.absent, request])

    from_spawners = for {_, _, list} <- ticked, spawn <- list, do: spawn
    by_section = Enum.reduce(spawned, %{}, &add_spawn(&1, &2, :natural))
    by_section = Enum.reduce(from_spawners, by_section, &add_spawn(&1, &2, :spawner))

    # Each spawn of a spawner block is a level event (2004) at the block.
    by_section =
      for {{x, _, z} = position, _, list} <- ticked, _ <- list, reduce: by_section do
        acc ->
          key = Grid.region_key(Grid.chunk_key(x, z))
          event = {position, 2004, 0}

          Map.update(acc, key, {[], [], [], [event]}, fn {r, d, s, e} ->
            {r, d, s, [event | e]}
          end)
      end

    by_section =
      Enum.reduce(group.sections, by_section, fn {key, resource}, acc ->
        entries = resource.entities.store.entries
        discards = for id <- discarded, Map.has_key?(entries, id), do: id
        resets = for id <- reset, Map.has_key?(entries, id), do: id

        if discards == [] and resets == [],
          do: acc,
          else:
            Map.update(acc, key, {[], discards, resets, []}, fn {r, _, _, e} ->
              {r, discards, resets, e}
            end)
      end)

    cached =
      Enum.reduce(ticked, cached, fn {position, delay, _}, acc ->
        Map.update!(acc, position, fn {nbt, config, _} -> {nbt, config, delay} end)
      end)

    {%{group.spawning | random: random, mobs: finalize, spawners: cached}, by_section}
  end

  # The simulated chunks' kept starts of structures that override spawns.
  defp kept_starts(group) do
    for {_key, resource} <- group.sections,
        {chunk, kept} <- resource.structures,
        MapSet.member?(resource.tickets.simulated, chunk),
        do: {chunk, kept}
  end

  defp add_spawn({kind, x, y, z, yaw, _school}, acc, reason) do
    case Body.spawned(Valimc.Data.EntityTypes.name(kind), reason) do
      {:ok, body} ->
        body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}
        record = Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y, z})
        key = Grid.region_key(Grid.chunk_key(x, z))

        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)

      {:error, _} ->
        acc
    end
  end

  ## Spawner blocks

  @spawner Valimc.Blocks.BlockEntityTypes.type_named("minecraft:mob_spawner")

  # The group's spawner block entities in simulated chunks, by position with
  # their parsed configuration and countdown (kept while their compound is
  # the same), and the request's spawners: those whose block is still a
  # spawner with a player that is not a spectator in range, when spawner
  # blocks work.
  defp spawner_blocks(group) do
    previous = Map.get(group.spawning, :spawners, %{})

    {cached, requested} =
      for {_key, resource} <- group.sections,
          {{x, _, z} = position, %{type: @spawner, nbt: nbt}} <- resource.block_entities.entries,
          MapSet.member?(resource.tickets.simulated, Grid.chunk_key(x, z)),
          {_, config, delay} = entry <- [spawner_entry(previous[position], nbt)],
          reduce: {%{}, []} do
        {cached, requested} ->
          cached = Map.put(cached, position, entry)

          if near?(group.players, position, config.player_range) and
               BlockEntityTypes.type_id(Valimc.World.Blocks.get(resource.blocks, position)) ==
                 @spawner,
             do: {cached, [Map.merge(config, %{position: position, delay: delay}) | requested]},
             else: {cached, requested}
      end

    if GameRules.get(:spawner_blocks_work),
      do: {cached, Enum.sort_by(requested, & &1.position)},
      else: {cached, []}
  end

  defp spawner_entry({nbt, _, _} = entry, nbt), do: entry

  defp spawner_entry(_previous, nbt) do
    case Valimc.Data.NBT.read(nbt) do
      {:ok, {:compound, fields}} ->
        short = fn name, default ->
          case fields[name] do
            {type, v} when type in [:short, :int] -> v
            _ -> default
          end
        end

        config = %{
          kind: spawner_kind(fields["SpawnData"]),
          min_delay: short.("MinSpawnDelay", 200),
          max_delay: short.("MaxSpawnDelay", 800),
          count: short.("SpawnCount", 4),
          max_nearby: short.("MaxNearbyEntities", 6),
          player_range: short.("RequiredPlayerRange", 16),
          spawn_range: short.("SpawnRange", 4)
        }

        {nbt, config, short.("Delay", 20)}

      _ ->
        nil
    end
  end

  # The type a spawn data's entity names, if ValiMC knows it.
  defp spawner_kind({:compound, %{"entity" => {:compound, %{"id" => {:string, id}}}}}) do
    if Valimc.Data.EntityTypes.fetch(id), do: Valimc.Data.EntityTypes.id(id)
  end

  defp spawner_kind(_data), do: nil

  defp near?(players, {x, y, z}, range) do
    Enum.any?(players, fn {px, py, pz, spectator, _} ->
      not spectator and
        (px - x - 0.5) ** 2 + (py - y - 0.5) ** 2 + (pz - z - 0.5) ** 2 < range * range
    end)
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
          {:ok, body} <- [Body.spawned(Valimc.Data.EntityTypes.name(kind), :chunk_generation)] do
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
