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
  countdown is kept in the group's MobWorld by position, starting from the
  `Delay` its block entity saved; a restart, another group, a new compound
  or a chunk that stops simulating starts it there again. Its spawn
  potentials, a spawn data's own position and entity data are not
  modelled: it spawns the type its spawn data names.

  The kernel's inputs stay resident in the group's MobWorld
  (`Valimc.World.SpawnInputs`, VMC-081g2): the native sections' censuses
  give the counts toward the caps, and the owner pushes a section's inputs
  only when they change.
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
  A group's spawning state: its level random, its mobs' random, its cat
  spawner's countdown (`Valimc.World.CatSpawner`), its trader spawner's
  (`Valimc.World.TraderSpawner`) and its phantom spawner's countdown
  (`Valimc.World.PhantomSpawner`); `seen` is what its MobWorld holds of
  its sections (`Valimc.World.SpawnInputs.sync/3`).
  """
  def new,
    do: %{
      random: JavaRandom.create(),
      mobs: JavaRandom.create(),
      seen: nil,
      cats: 0,
      phantoms: 0,
      traders: Valimc.World.TraderSpawner.new()
    }

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
  def dark?(dimension), do: sky(dimension) |> then(&(&1 != nil and &1 >= 4))

  @doc """
  The sky's darkening in `dimension` now (`skyDarken`), nil where its time
  is fixed (`isBrightOutside` and `isDarkOutside` are both false there).
  """
  def sky(dimension) do
    if Valimc.Data.SleepFacts.dimension(dimension).fixed_time do
      nil
    else
      %{rain_level: rain, thunder_level: thunder} = weather(dimension)
      darken(Dimension.name(dimension), Clock.day_ticks(), rain, Float32.round(thunder * rain))
    end
  end

  @doc "The surface slime chance at `ticks` of the dimension's clock (the moon timeline)."
  def slime_chance(dimension, ticks) do
    case SpawnFacts.dimension(dimension)["tracks"]["surface_slime_spawn_chance"] do
      nil -> 0.0
      track -> max(0.0, sample(track, ticks))
    end
  end

  @doc """
  `EnvironmentAttributes.TURTLE_EGG_HATCH_CHANCE` at `ticks` of the
  dimension's clock: the timeline's value (the night's 1.0) or its default
  0.002, whichever is greater (VMC-043e).
  """
  def turtle_hatch_chance(dimension, ticks) do
    default = Float32.round(0.002)

    case SpawnFacts.dimension(dimension)["tracks"]["turtle_egg_hatch_chance"] do
      nil -> default
      track -> max(default, sample(track, ticks))
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
  MobWorld (`world`), its `sections` (`%{key => resource}`), `players`
  (`{x, y, z, spectator, creative}`), its `spawning` state and the tick's
  `environment`. Its sections' inputs stay resident in the world
  (`Valimc.World.SpawnInputs`, VMC-081g2). Returns `{spawning, %{key =>
  {records, discards, resets, events}}}`, the events the level events of
  the section's spawner blocks.
  """
  def plan(%{players: []} = group), do: {group.spawning, %{}}

  def plan(group) do
    env = group.environment

    {seen, simulated} =
      Valimc.World.SpawnInputs.sync(group.world, group.sections, Map.get(group.spawning, :seen))

    request = %{
      environment: env,
      players: group.players,
      respawn: respawn(env.dimension),
      spawn_mobs: GameRules.get(:spawn_mobs),
      enemies: env.difficulty != 0 and GameRules.get(:spawn_monsters),
      persistent: rem(group.game_time, 400) == 0,
      random: group.spawning.random,
      finalize: group.spawning.mobs,
      spawners: GameRules.get(:spawner_blocks_work),
      spawner_state: spawner_state()
    }

    {:ok, {spawned, discarded, reset, random, finalize, ticked}} =
      Native.dispatch(:mob_world_spawn, simulated, [group.world, request])

    from_spawners = for {_, list} <- ticked, spawn <- list, do: spawn
    by_section = spawned |> Enum.with_index() |> Enum.reduce(%{}, &add_spawn(&1, &2, :natural))

    by_section =
      from_spawners |> Enum.with_index() |> Enum.reduce(by_section, &add_spawn(&1, &2, :spawner))

    # Each spawn of a spawner block is a level event (2004) at the block.
    by_section =
      for {{x, _, z} = position, list} <- ticked, _ <- list, reduce: by_section do
        acc ->
          key = Grid.region_key(Grid.chunk_key(x, z))
          event = {position, 2004, 0}

          Map.update(acc, key, {[], [], [], [event]}, fn {r, d, s, e} ->
            {r, d, s, [event | e]}
          end)
      end

    by_section =
      by_section
      |> distribute(Enum.reverse(discarded), 1)
      |> distribute(Enum.reverse(reset), 2)

    # The village's cats (`CatSpawner`, VMC-044a3), after the chunks' spawns.
    {cats, random, made} = Valimc.World.CatSpawner.tick(group, random)

    by_section =
      Enum.reduce(made, by_section, fn {key, record}, acc ->
        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)
      end)

    # Wandering traders (`WanderingTraderSpawner`, VMC-044a4).
    {traders, random, made} = Valimc.World.TraderSpawner.tick(group, random)

    by_section =
      Enum.reduce(made, by_section, fn {key, record}, acc ->
        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)
      end)

    # Phantoms (`PhantomSpawner`, VMC-043b6).
    {phantoms, random, made} = Valimc.World.PhantomSpawner.tick(group, random)

    by_section =
      Enum.reduce(made, by_section, fn {key, record}, acc ->
        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)
      end)

    spawning =
      group.spawning
      |> Map.put(:seen, seen)
      |> Map.put(:cats, cats)
      |> Map.put(:traders, traders)
      |> Map.put(:phantoms, phantoms)

    {%{spawning | random: random, mobs: finalize}, by_section}
  end

  # The mobs `{key, id}` that despawn (`field` 1) or whose idle time
  # restarts (2), into their sections' plans in the kernel's order.
  defp distribute(plan, ids, field) do
    Enum.reduce(ids, plan, fn {key, id}, acc ->
      Map.update(acc, key, put_elem({[], [], [], []}, field, [id]), fn row ->
        put_elem(row, field, [id | elem(row, field)])
      end)
    end)
  end

  @doc """
  The stores a custom spawner's position checks read (cats, traders): the
  first section's region handle and the others' of the sections beside the
  simulated ones (every section when none simulates), with their absent
  chunks: `{region, siblings, absent}`.
  """
  def stores(group) do
    active =
      for {{sx, sz}, r} <- group.sections, MapSet.size(r.tickets.simulated) > 0, do: {sx, sz}

    near =
      for {{sx, sz}, r} <- group.sections,
          Enum.any?(active, fn {ax, az} -> abs(ax - sx) <= 1 and abs(az - sz) <= 1 end),
          do: r

    near = if near == [], do: Map.values(group.sections), else: near
    [region | siblings] = for r <- near, do: r.blocks.ref
    {region, siblings, Enum.flat_map(near, &MapSet.to_list(&1.generation.absent))}
  end

  # The spawner block's state (it has no properties).
  defp spawner_state do
    case :persistent_term.get({__MODULE__, :spawner_state}, nil) do
      nil ->
        state = Valimc.Data.Blocks.default_state("spawner")
        :persistent_term.put({__MODULE__, :spawner_state}, state)
        state

      state ->
        state
    end
  end

  defp add_spawn({{kind, x, y, z, yaw, school, pack}, order}, acc, reason) do
    case Body.spawned(Valimc.Data.EntityTypes.name(kind), reason) do
      {:ok, body} ->
        body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}
        record = Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y, z})
        record = pack_record(record, pack, order, school, reason)
        key = Grid.region_key(Grid.chunk_key(x, z))

        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)

      {:error, _} ->
        acc
    end
  end

  defp pack_record(record, pack, order, school, reason) do
    if pack != nil and Valimc.AI.SpawnGroup.handles?(record.type),
      do:
        Map.merge(record, %{spawn_pack: {reason, pack}, spawn_order: order, spawn_school: school}),
      else: record
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

      for {chunk, list} <- spawned,
          {{kind, x, y, z, yaw, school, pack}, order} <- Enum.with_index(list),
          {:ok, body} <- [Body.spawned(Valimc.Data.EntityTypes.name(kind), :chunk_generation)] do
        body = %{body | yaw: yaw * 1.0, head_yaw: yaw * 1.0}

        Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y, z})
        |> pack_record({chunk, pack}, {chunk, order}, school, :chunk_generation)
      end
    end
  end

  defp respawn(dimension) do
    if Dimension.name(Valimc.World.Spawn.dimension()) == dimension,
      do: Valimc.World.Spawn.position()
  end
end
