defmodule Valimc.NativeMobScene do
  @moduledoc """
  The think parity harness of the native mob families (VMC-081d): whole
  sections of mobs thinking tick by tick over generated terrain on both
  sides, as `mob_parity_think` runs them natively: the scene's acts,
  `AI.prepare` (with sensed-only statues of types not native yet), each
  mob's `think_mob`, a scripted move toward its wanted position, `settle`,
  the sun and its family's part after the move (`post`), its sensing again
  and `AI.finish`. `compare/3` asserts every mob's record, mind and effects
  and the level random equal every tick.
  """
  import ExUnit.Assertions

  alias Valimc.AI
  alias Valimc.AI.{Mind, Selector, Self, World}
  alias Valimc.Data.{EffectTypes, EntityTypes}
  alias Valimc.Entity.{Animal, Body, Mob, Store}
  alias Valimc.Living.Attributes
  alias Valimc.Native
  alias Valimc.Worldgen.Generator

  @seed 20_261_029
  @zoom_seed -4_172_144_997_902_289_642
  @chunks for cx <- 0..2, cz <- 0..2, do: {cx, cz}

  @doc "The generated terrain, its path view and the record facts (`setup_all`)."
  def setup do
    Valimc.AI.NativeFacts.install!()
    Valimc.Entity.NativeLiving.install!()
    Valimc.AI.Paths.install!()
    images = Valimc.World.Blocks.lit_images(Generator.columns({:vanilla, @seed}, @chunks), true)
    size = Valimc.Data.Grid.region_size()
    absent = for cx <- 0..(size - 1), cz <- 0..(size - 1), {cx, cz} not in @chunks, do: {cx, cz}
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, images, MapSet.new(absent))
    handles = Valimc.World.Blocks.snapshots(blocks, for(c <- @chunks, do: {c, nil}), 1)
    view = {:rows, Enum.reject(handles, &is_nil/1), Valimc.Protocol.Data.block("air")}

    types =
      for name <- EntityTypes.names(), EntityTypes.living?(name) do
        {:ok, body} = Body.generated(name, nil, false)
        {name, true, Mob.base(name, %{}, "minecraft:max_health") * 1.0, Map.keys(body.data)}
      end

    {:ok, facts} =
      Native.mob_record_facts(%{
        effect_count: EffectTypes.count(),
        absorption_effect: EffectTypes.id("absorption"),
        max_absorption: Attributes.max_absorption() * 1.0,
        types: types
      })

    %{blocks: blocks, view: view, facts: facts}
  end

  ## The Elixir side

  defp world(blocks, view, players, time, scene) do
    %World{
      read: &read(blocks, &1),
      light: &Valimc.World.Blocks.light(blocks, &1),
      biome: &Valimc.World.Blocks.biome(blocks, @zoom_seed, &1),
      search: fn request ->
        [result] = Valimc.AI.Paths.find(view, [request])
        result
      end,
      players: players,
      time: time,
      day: scene.day,
      difficulty: scene.difficulty,
      bright: scene.bright,
      monsters_burn: scene.monsters_burn,
      halloween: scene.halloween,
      mob_griefing: scene.rules.mob_griefing,
      mob_drops: scene.rules.mob_drops,
      entity_drops: scene.rules.entity_drops,
      knots: Map.new(scene.knots, fn {x, y, z, id} -> {{x, y, z}, id} end)
    }
  end

  defp sensed_player(p) do
    {x, y, z} = p.position

    %{
      kind: :player,
      uuid: p.uuid,
      id: p.id,
      x: x,
      y: y,
      z: z,
      yaw: p.yaw,
      pitch: p.pitch,
      eye: Valimc.Data.Float32.round(1.62),
      width: Valimc.Data.Float32.round(0.6),
      height: Valimc.Data.Float32.round(1.8),
      mode: p.mode,
      invulnerable: p.mode == :creative,
      alive: true,
      crouching: false,
      swimming: false,
      invisible: false,
      armor_cover: 0.0,
      movement: p.movement,
      velocity: {0.0, 0.0, 0.0},
      health: 20.0,
      effects: MapSet.new(),
      equipment: if(p.mainhand, do: %{mainhand: p.mainhand}, else: %{})
    }
  end

  @doc "The store record of entry `{id, entry}`."
  def entry_record(id, entry),
    do:
      Store.record(%{
        kind: :mob,
        entity: Map.put(entry.entity, :entity_id, id),
        body: entry.body,
        hops: 0
      })

  # The statues: mobs others sense that do not think (types not native yet).
  defp with_statues(world, []), do: world

  defp with_statues(world, statues) do
    rows = for {id, entry} <- statues, do: AI.sensed({id, entry})
    mobs = world.mobs ++ rows

    %{
      world
      | mobs: mobs,
        by_type: Enum.group_by(mobs, & &1.type),
        index: Map.merge(world.index, Map.new(rows, &{&1.uuid, &1})),
        spatial: Valimc.AI.Spatial.new(mobs)
    }
  end

  # One tick of the section as the native parity runs it.
  defp tick(entries, world, scene, tick) do
    entries = act(entries, scene, tick)
    {mobs, world, ctx} = AI.prepare(entries, world)
    world = with_statues(world, scene.statues)
    old = Map.new(mobs)
    collide = Enum.at(scene.collide, tick, [])

    {results, {ctx, world, made}} =
      mobs
      |> Enum.with_index()
      |> Enum.map_reduce({ctx, world, []}, fn {{id, entry}, i}, {ctx, world, made} ->
        {{^id, body, {x, y, z}, effects}, ctx, world} =
          AI.think_mob(ctx, i, {id, entry}, world)

        {nx, nz} =
          case body.mob.motion.control do
            {:move_to, {tx, _, tz}, _} ->
              {dx, dz} = {tx - x, tz - z}
              l = :math.sqrt(dx * dx + dz * dz)

              if l > 0.0 do
                s = min(l, scene.step)
                {x + dx / l * s, z + dz / l * s}
              else
                {x, z}
              end

            _ ->
              {x, z}
          end

        {body, {px, py, pz} = position, settled, world} =
          AI.settle({id, old[id]}, body, {nx, y, nz}, world)

        {body, own} =
          if scene.post, do: post(body, position, world, i in collide), else: {body, []}

        entry = %{entry | body: body, entity: %{entry.entity | x: px, y: py, z: pz}}
        world = AI.resense_entry(world, id, entry)
        {{id, entry}, {ctx, world, made ++ [effects ++ settled ++ own]}}
      end)

    bodies = AI.finish(ctx, Enum.map(results, fn {id, e} -> {id, e.body} end), mobs)

    entries =
      Enum.zip_with(results, bodies, fn {id, e}, {id, body} -> {id, %{e | body: body}} end)

    {entries, world, made}
  end

  # What `MobTicks` runs after the settle that the scene can: the sun
  # (`Daylight.tick`) and the family's part after the move, its move as the
  # record's fluids left it (`collided`: it bumped into a wall).
  defp post(body, position, world, collided) do
    {body, _events} = Valimc.AI.Daylight.tick(body, position, world)
    motion = %{body.mob.motion | horizontal_collision: collided}
    body = put_in(body.mob.motion, motion)

    ticked = %{
      eye_water: motion.eye_water,
      eye_state: elem(motion.eye, 1),
      mob: %{horizontal_collision: collided}
    }

    AI.Mobs.after_move(body, position, ticked)
  end

  defp act(entries, scene, tick) do
    Enum.reduce(scene.acts, entries, fn
      {^tick, i, what}, entries ->
        {id, e} = Enum.at(entries, i)

        body =
          case what do
            :love ->
              elem(Animal.fall_in_love(e.body, nil), 0)

            :feed ->
              Animal.feed_baby(e.body)

            :hurt ->
              [p | _] = scene.players

              put_in(e.body.mob.ai, AI.hurt(e.body.mob.ai, {:player, p.uuid}, :player_attack)).body

            :fire ->
              put_in(e.body.mob.living.fire_ticks, 160)
          end

        List.replace_at(entries, i, {id, %{e | body: body}})

      _, entries ->
        entries
    end)
  end

  defp run(blocks, view, scene, entries) do
    {ticks, _} =
      Enum.map_reduce(0..(scene.ticks - 1), {entries, scene.level_seed}, fn t, {entries, level} ->
        players =
          case Enum.at(scene.moves, t) do
            nil ->
              scene.players

            moved ->
              Enum.zip_with(scene.players, moved, fn p, {at, movement} ->
                %{p | position: at, movement: movement}
              end)
          end

        world =
          blocks
          |> world(view, Enum.map(players, &sensed_player/1), scene.time + t, scene)
          |> Map.put(:random, level)

        {entries, world, made} = tick(entries, world, scene, t)

        records = for {id, e} <- entries, do: entry_record(id, e)
        minds = for {_, e} <- entries, do: mind(e.body)
        effects = for list <- made, do: Enum.map(list, &effect/1)
        {{records, minds, effects, world.random}, {entries, world.random}}
      end)

    ticks
  end

  @doc "What the record leaves out of a mind, as the native parity answers it."
  def mind(%Body{mob: %Mob{ai: %Mind{} = m} = mob}) do
    look = m.look && {m.look.x, m.look.y, m.look.z, m.look.y_max, m.look.x_max, m.look.cooldown}

    path =
      case m.navigation do
        %{path: %{nodes: nodes, index: index}, speed: speed} ->
          {index, Tuple.to_list(nodes), speed}

        _ ->
          nil
      end

    running = for module <- Selector.running(%Self{mind: m}, :goals), do: inspect(module)
    disabled = if :move in m.disabled, do: 1, else: 0

    {m.tick, m.no_action, m.ambient, running, m.target, look, m.body_yaw, path, m.own,
     m.forced_age_timer, m.age_lock_timer, disabled, m.wet, mob.motion.control}
  end

  def mind(_body), do: nil

  @doc "A sound's id (the Elixir's effects may name it)."
  def sound_id(id) when is_integer(id), do: id

  def sound_id(name) do
    Valimc.Data.HostileFacts.sound_id(name) ||
      Valimc.Entity.Animal.sound_id(name)
  end

  @doc "An effect as both sides answer it (sound seeds and bodies left out)."
  def effect({:sound, id, source, volume, pitch, _seed}),
    do: {:sound, sound_id(id), source, volume, pitch}

  def effect({:sound_at, id, _source, at, volume, pitch}),
    do: {:sound_at, sound_id(id), at, volume, pitch}

  def effect({:offspring, type, data, at}),
    do: {:offspring, type, Map.delete(data, :egg_time), at}

  def effect({kind, _} = e)
      when kind in [
             :event,
             :bred,
             :lay,
             :lead,
             :knot_free,
             :make_knot,
             :raid_carrot,
             :attack,
             :convert,
             :jockey,
             :shoot,
             :explode,
             :throw_potion,
             :throw_trident,
             :remove_block
           ],
      do: e

  def effect({:eat_block, _, _} = e), do: e
  def effect({:orb, _, _} = e), do: e
  def effect({:alert, _, _} = e), do: e
  def effect({:attack_extra, _, _} = e), do: e
  def effect({:spawn, _, _} = e), do: e
  def effect({:take_block, _, _} = e), do: e
  def effect({:place_carried, _, _} = e), do: e
  def effect({:level_event, _, _, _} = e), do: e

  def effect({:touch, ref, amount, {id, volume, pitch}}),
    do: {:touch, ref, amount, {id, volume, pitch}}

  # A companion's body: its type and equipment (its uuid and mind are its
  # own).
  def effect({:spawn_body, body, _uuid}), do: {:spawn_body, body.type, body.mob.equipment}

  def effect({:swing, _}), do: {:swing}
  def effect(:discard), do: {:discard}
  def effect(_), do: {:other}

  @doc """
  Runs `scene` over `entries` on both sides and asserts each tick equal:
  every mob's mind, effects and record and the level random. The ticks the
  Elixir observed.
  """
  def compare(%{blocks: blocks, view: view, facts: facts}, scene, entries) do
    records = for {id, e} <- entries, do: {id, entry_record(id, e)}
    statues = for {id, e} <- scene.statues, do: {id, entry_record(id, e)}

    # Both sides start from what the records keep.
    restore = fn entries ->
      for {id, e} <- entries do
        {:ok, body} = Body.restore(entry_record(id, e))
        {id, %{e | body: body}}
      end
    end

    entries = restore.(entries)
    scene = %{scene | statues: restore.(scene.statues)}
    expected = run(blocks, view, scene, entries)

    native =
      Native.mob_parity_think(blocks.ref, @zoom_seed, facts, %{
        scene
        | mobs: records,
          statues: statues
      })

    assert length(native) == scene.ticks

    for {{e, n}, t} <- Enum.with_index(Enum.zip(expected, native)) do
      {er, em, ee, el} = e
      {nr, nm, ne, nl} = n

      for {{a, b}, i} <- Enum.with_index(Enum.zip(em, nm)),
          do: assert({t, i, :mind, b} == {t, i, :mind, a})

      for {{a, b}, i} <- Enum.with_index(Enum.zip(ee, ne)),
          do: assert({t, i, :effects, b} == {t, i, :effects, a})

      for {{a, b}, i} <- Enum.with_index(Enum.zip(er, nr)),
          do: assert({t, i, :record, b} == {t, i, :record, a})

      assert {t, :level, nl} == {t, :level, el}
    end

    expected
  end

  ## Scenes

  @doc "A test uuid."
  def uuid(n), do: <<n::64, n * 7919::64>>

  @doc "The block state at a cell of the terrain."
  def read(blocks, {x, y, z}) do
    case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
      {:ok, <<state::16>>} -> state
      _ -> nil
    end
  end

  @doc "The motion-blocking height of a column."
  def surface(blocks, x, z) do
    world = %World{read: &read(blocks, &1)}
    World.motion_blocking(world, x, z)
  end

  @doc "`count` land columns (the block below the surface is no fluid)."
  def land(blocks, count, rand), do: columns(blocks, count, rand, &(&1 == :empty))

  @doc "`count` water columns (`{x, surface, z}` over water)."
  def water(blocks, count, rand), do: columns(blocks, count, rand, &(&1 == :water))

  defp columns(blocks, count, rand, fluid?) do
    world = %World{read: &read(blocks, &1)}

    Stream.unfold(rand, fn rand ->
      {x, rand} = :rand.uniform_s(24, rand)
      {z, rand} = :rand.uniform_s(24, rand)
      {{x + 11, z + 11}, rand}
    end)
    |> Stream.take(5000)
    |> Stream.map(fn {x, z} -> {x, surface(blocks, x, z), z} end)
    |> Stream.filter(fn {x, y, z} -> fluid?.(World.fluid(world, {x, y - 1, z})) end)
    |> Stream.uniq()
    |> Enum.take(count)
  end

  @doc """
  An entry of mob `n` of `type` at a spot: options `:data`, `:age` (an
  animal's), `:yaw`, `:no_ai`, `:leash`, `:finalize` (a spawn reason),
  `:fire` (fire ticks), `:equipment` (`slot => stack`), `:motion` (fields of
  its motion), `:target`.
  """
  def mob(n, type, {x, y, z}, opts \\ []) do
    {:ok, body} = Body.new(type)
    data = Map.merge(body.data, Map.new(Keyword.get(opts, :data, [])))

    data =
      if Map.has_key?(data, :age) or Keyword.has_key?(opts, :age),
        do: Map.put(data, :age, Keyword.get(opts, :age, 0)),
        else: data

    yaw = Keyword.get(opts, :yaw, 15.0 * n)
    body = %{body | data: data, yaw: yaw, head_yaw: yaw, on_ground: true}
    body = %{body | mob: %{body.mob | no_ai: Keyword.get(opts, :no_ai, false)}}
    body = put_in(body.mob.living.fire_ticks, Keyword.get(opts, :fire, 0))

    body =
      update_in(body.mob.equipment, &Map.merge(&1, Map.new(Keyword.get(opts, :equipment, []))))

    body = update_in(body.mob.motion, &Map.merge(&1, Map.new(Keyword.get(opts, :motion, []))))

    body =
      case Keyword.get(opts, :leash) do
        nil ->
          body

        holder ->
          put_in(body.mob.leash, %{holder: holder, id: nil, momentum: 0.0, restored: false})
      end

    body =
      case Keyword.get(opts, :finalize) do
        nil -> body
        reason -> put_in(body.mob.finalize, reason)
      end

    {x, y, z} = {x + 0.5 + 0.1 * rem(n, 3), y * 1.0, z + 0.5}
    {n, %{entity: %{uuid: uuid(n), x: x, y: y, z: z}, body: body, revision: 1}}
  end

  @doc "A player near a spot."
  def player(n, {x, y, z}, opts \\ []) do
    %{
      uuid: uuid(1000 + n),
      id: 1000 + n,
      position: {x + 0.3, y * 1.0, z + 0.7},
      yaw: Keyword.get(opts, :yaw, 12.5),
      pitch: Keyword.get(opts, :pitch, -3.0),
      mode: Keyword.get(opts, :mode, :survival),
      mainhand: Keyword.get(opts, :mainhand),
      movement: {0.0, 0.0, 0.0}
    }
  end

  @doc """
  A scene of `players`: options `:time`, `:day`, `:ticks`, `:step`,
  `:difficulty`, `:bright`, `:monsters_burn`, `:halloween`, `:knots`,
  `:acts`, `:moves`, `:level` (the level random's seed), `:statues`,
  `:post`, `:collide`, `:loot`.
  """
  def scene(players, opts) do
    %{
      mobs: [],
      players: players,
      time: Keyword.get(opts, :time, 6000),
      day: Keyword.get(opts, :day, 6000),
      ticks: Keyword.get(opts, :ticks, 200),
      step: Keyword.get(opts, :step, 0.2),
      difficulty: Keyword.get(opts, :difficulty, :normal),
      bright: Keyword.get(opts, :bright, true),
      monsters_burn: Keyword.get(opts, :monsters_burn, false),
      halloween: Keyword.get(opts, :halloween, false),
      rules: %{mob_griefing: true, mob_drops: true, entity_drops: true},
      knots: Keyword.get(opts, :knots, []),
      acts: Keyword.get(opts, :acts, []),
      moves: Keyword.get(opts, :moves, []),
      level_seed: AI.Random.new(Keyword.get(opts, :level, 7)),
      statues: Keyword.get(opts, :statues, []),
      post: Keyword.get(opts, :post, false),
      collide: Keyword.get(opts, :collide, []),
      loot: Keyword.get(opts, :loot)
    }
  end
end
