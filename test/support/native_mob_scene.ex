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

  @doc """
  The generated terrain, its path view and the record facts (`setup_all`).
  `edit` gives the blocks a scene builds on the terrain before its views are
  published: `{%{position => state}, info}`, `info` kept as `:info`.
  """
  def setup, do: setup_with(fn _blocks -> {%{}, nil} end)

  @doc "`setup/0` with the blocks `edit` gives the terrain (see `setup/0`)."
  def setup_with(edit) do
    Valimc.AI.NativeFacts.install!()
    Valimc.Entity.NativeLiving.install!()
    Valimc.AI.Paths.install!()
    images = Valimc.World.Blocks.lit_images(Generator.columns({:vanilla, @seed}, @chunks), true)
    size = Valimc.Data.Grid.region_size()
    absent = for cx <- 0..(size - 1), cz <- 0..(size - 1), {cx, cz} not in @chunks, do: {cx, cz}
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, images, MapSet.new(absent))
    {edits, info} = edit.(blocks)
    _ = Valimc.World.Blocks.put(blocks, edits)
    view = view(blocks, 1)

    # `World.find` over the region's store, as the native side's finder
    # reads it (the owner's `find_blocks` reads its published snapshots of
    # the same blocks).
    finder = fn {x0, y0, z0, x1, y1, z1}, states ->
      list = Enum.to_list(states)

      for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
          cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
          {:ok, found} <- [Native.chunk_find(blocks.ref, cx, cz, list)],
          <<x::32-signed, y::32-signed, z::32-signed, state::16 <- found>>,
          x in x0..x1 and y in y0..y1 and z in z0..z1,
          do: {{x, y, z}, state}
    end

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

    %{blocks: blocks, view: view, facts: facts, finder: finder, info: info}
  end

  @doc """
  The Elixir side's path view of the terrain at `revision`: the path
  searches read the region's every chunk, as the native side reads its
  store (the chunks beyond the generated ones are the store's own fill). A
  scene that edits the terrain (from the region's owner, `setup_all`)
  takes a new one.
  """
  def view(blocks, revision) do
    size = Valimc.Data.Grid.region_size()
    region = for cx <- 0..(size - 1), cz <- 0..(size - 1), do: {{cx, cz}, nil}
    handles = Valimc.World.Blocks.snapshots(blocks, region, revision)
    {:rows, Enum.reject(handles, &is_nil/1), Valimc.Protocol.Data.block("air")}
  end

  ## The Elixir side

  defp world(blocks, view, players, time, scene) do
    %World{
      read: &read(blocks, &1),
      find: scene[:finder],
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
      darken: scene.darken,
      mob_griefing: scene.rules.mob_griefing,
      mob_drops: scene.rules.mob_drops,
      entity_drops: scene.rules.entity_drops,
      universal_anger: scene.rules.universal_anger,
      villages: scene.villages && MapSet.new(scene.villages),
      knots: Map.new(scene.knots, fn {x, y, z, id} -> {{x, y, z}, id} end),
      items: scene.items,
      locate: locate(scene.treasure)
    }
  end

  # Structure queries find `treasure` at once (nil: deferred, as live).
  defp locate(nil), do: :deferred
  defp locate(at), do: fn _query -> {:ok, at} end

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
      swimming: Map.get(p, :swimming, false),
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
              put_in(e.body.mob.living.fire_ticks, 160).body

            # A player's blow as its family takes it before it lands (an
            # axolotl playing dead), then its mind's hurt.
            :blow ->
              [p | _] = scene.players
              hit = %{source: :player_attack, amount: 2.0, attacker: %{type: "minecraft:player"}}
              body = AI.Mobs.hook(e.body.type, :before_hurt, [e.body, hit], e.body)
              put_in(body.mob.ai, AI.hurt(body.mob.ai, {:player, p.uuid}, :player_attack))

            # A family's part of a hurt it turned away (an arrow) or took
            # without a living attacker (a cactus).
            :shot ->
              hit = %{source: :arrow, amount: 4.0}
              AI.Mobs.hook(e.body.type, :repelled, [e.body, hit], e.body)

            :poked ->
              hit = %{source: :cactus, amount: 1.0}
              AI.Mobs.hook(e.body.type, :hurt, [e.body, hit], e.body)

            :magic ->
              hit = %{source: :magic, amount: 1.0}
              AI.Mobs.hook(e.body.type, :hurt, [e.body, hit], e.body)

            # A shulker bullet's hit, as its family takes it.
            :bullet ->
              hit = %{
                source: :mob_projectile,
                amount: 4.0,
                direct: %{type: "minecraft:shulker_bullet"}
              }

              AI.Mobs.hook(e.body.type, :hurt, [e.body, hit], e.body)

            # The first player's melee hit beside its damage: the mind's
            # hurt, then its family's (a squid's ink, a guardian's thorns, a
            # bat waking).
            :struck ->
              [p | _] = scene.players
              ai = AI.hurt(e.body.mob.ai, {:player, p.uuid}, :player_attack)
              body = put_in(e.body.mob.ai, ai).body
              who = %{uuid: p.uuid, entity_id: p.id, player: true, type: "minecraft:player"}

              hit = %{
                source: Valimc.Living.DamageSource.new(:player_attack),
                amount: 1.0,
                attacker: who,
                direct: who
              }

              case AI.Mobs.hook(body.type, :hurt, [body, hit], body) do
                {body, _events} -> body
                body -> body
              end
          end

        List.replace_at(entries, i, {id, %{e | body: body}})

      _, entries ->
        entries
    end)
  end

  # The POI tickets the scene's villagers hold (the owner's `store_claims`).
  defp claims(entries) do
    entries
    |> Enum.map(fn {id, e} -> {id, Map.put(e, :kind, :mob)} end)
    |> Valimc.AI.Pois.store_claims(:overworld)
  end

  # What players did this tick that brain mobs react to:
  # `{tick, player index, seen}` angers piglins near the player.
  defp events(scene, players, t) do
    for {^t, i, seen} <- scene.events,
        p = Enum.at(players, i),
        do: {:anger, {:player, p.uuid}, seen}
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
          |> Map.put(:pois, claims(entries))
          |> Map.put(:loot_seeds, scene.loot_seeds)
          |> Map.put(:events, events(scene, players, t))

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
     m.forced_age_timer, m.age_lock_timer, disabled, m.wet, mob.motion.control, brain(m)}
  end

  def mind(_body), do: nil

  # A brain's memories (by name, a path as `{:path, index, nodes}`), its
  # active activities, running behaviours and sensors' countdowns.
  defp brain(%Mind{brain: %Valimc.AI.Brain{} = b} = m) do
    memories =
      b.memories
      |> Enum.map(fn {k, {v, ttl}} -> {Atom.to_string(k), memory(v), ttl} end)
      |> Enum.sort()

    {memories, b.active, Valimc.AI.Brain.running(%Self{mind: m}), Enum.map(b.sensors, & &1.time)}
  end

  defp brain(_mind), do: nil

  defp memory(%{nodes: nodes, index: index}), do: {:path, index, Tuple.to_list(nodes)}
  defp memory(v), do: v

  @doc "A sound's id (the Elixir's effects may name it)."
  def sound_id(id) when is_integer(id), do: id

  def sound_id(name) do
    Valimc.Data.HostileFacts.sound_id(name) || ai_sound(name) || combat_sound(name) ||
      Valimc.Entity.Animal.sound_id(name)
  end

  # The hurt and death sounds of the living rules (`combat_facts`).
  defp combat_sound(name) do
    key = {__MODULE__, :combat_sounds}

    sounds =
      case :persistent_term.get(key, nil) do
        nil ->
          sounds = Valimc.Data.Facts.read!("registry/combat_facts.json")["sounds"]
          :persistent_term.put(key, sounds)
          sounds

        sounds ->
          sounds
      end

    sounds[name]
  end

  defp ai_sound(name) do
    Valimc.AI.Facts.sound_id(name)
  rescue
    KeyError -> nil
  end

  @doc "An effect as both sides answer it (sound seeds and bodies left out)."
  # A source by name (a shulker's) as its id, which the owner's packet reads.
  def effect({:sound, id, source, volume, pitch, seed}) when is_binary(source),
    do: effect({:sound, id, Valimc.Protocol.CombatPackets.source(source), volume, pitch, seed})

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
  def effect({:hurt, _, _, _, _} = e), do: e
  def effect({:elder_curse, _} = e), do: e
  def effect({:lay_eggs, _, _} = e), do: e
  def effect({:gift, _, _} = e), do: e

  def effect({:sound_block, id, source, volume, pitch, _seed}),
    do: {:sound_block, sound_id(id), source, volume, pitch}

  def effect({:effect, _, _} = e), do: e
  def effect({:throw, _, _, _, _} = e), do: e
  def effect({:pickup, {:item, uuid}, count}), do: {:pickup, uuid, count}
  def effect({:orb, _, _} = e), do: e
  def effect({:alert, _, _} = e), do: e
  def effect({:attack_extra, _, _} = e), do: e
  def effect({:spawn, _, _} = e), do: e
  def effect({:take_block, _, _} = e), do: e
  def effect({:place_carried, _, _} = e), do: e
  def effect({:level_event, _, _, _} = e), do: e
  def effect({:infest, _, _} = e), do: e
  def effect({:wake_infested, _, _, _} = e), do: e
  def effect({:projectile, _, _, _, _} = e), do: e
  def effect({:shoot_bullet, _, _, _} = e), do: e
  def effect({:spawn_mob, _, _, _} = e), do: e
  def effect({:shulker_push, _, _} = e), do: e

  def effect({:touch, ref, amount, {id, volume, pitch}}),
    do: {:touch, ref, amount, {id, volume, pitch}}

  # A companion's body: its type and equipment (its uuid and mind are its
  # own).
  def effect({:spawn_body, body, _uuid}), do: {:spawn_body, body.type, body.mob.equipment}

  def effect({:swing, _}), do: {:swing}
  def effect(:discard), do: {:discard}
  def effect(_), do: {:other}

  @doc "The Elixir side's ticks of `scene` over `entries` (for a look at a difference)."
  def elixir(%{blocks: blocks, view: view} = ctx, scene, entries) do
    restore = fn entries ->
      for {id, e} <- entries do
        {:ok, body} = Body.restore(entry_record(id, e))
        {id, %{e | body: body}}
      end
    end

    scene = Map.put(%{scene | statues: restore.(scene.statues)}, :finder, ctx[:finder])
    run(blocks, view, scene, restore.(entries))
  end

  @doc """
  Runs `scene` over `entries` on both sides and asserts each tick equal:
  every mob's mind, effects and record and the level random. The ticks the
  Elixir observed.
  """
  def compare(%{blocks: blocks, view: view, facts: facts} = ctx, scene, entries) do
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
    expected = run(blocks, view, Map.put(scene, :finder, ctx[:finder]), entries)

    native =
      Native.mob_parity_think(blocks.ref, @zoom_seed, facts, %{
        scene
        | mobs: records,
          statues: statues,
          events: for({t, i, seen} <- scene.events, do: {t, i, seen})
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
  `:fire` (fire ticks), `:health`, `:equipment` (`slot => stack`), `:motion`
  (fields of its motion), `:target`, `:pick_up` (`canPickUpLoot`), `:air` (its
  air supply).
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
    loot = Keyword.get(opts, :pick_up, body.mob.can_pick_up_loot)
    body = %{body | mob: %{body.mob | can_pick_up_loot: loot}}
    body = put_in(body.mob.living.fire_ticks, Keyword.get(opts, :fire, 0))
    body = put_in(body.mob.living.air_supply, Keyword.get(opts, :air, body.mob.living.air_supply))

    body =
      case Keyword.get(opts, :health) do
        nil -> body
        health -> put_in(body.mob.living.health.value, health * 1.0)
      end

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
      movement: {0.0, 0.0, 0.0},
      swimming: Keyword.get(opts, :swimming, false)
    }
  end

  @doc """
  A sensed item `n` of `item` (a name) at a point: options `:count`,
  `:pickup_delay`, `:in_water`.
  """
  def item(n, item, {x, y, z}, opts \\ []) do
    %{
      kind: :item,
      uuid: uuid(3000 + n),
      x: x * 1.0,
      y: y * 1.0,
      z: z * 1.0,
      width: 0.25,
      height: 0.25,
      eye: 0.2125000059604645,
      item: Valimc.Protocol.ItemTypes.id(item),
      count: Keyword.get(opts, :count, 1),
      components: %{},
      pickup_delay: Keyword.get(opts, :pickup_delay, 0),
      in_water: Keyword.get(opts, :in_water, true),
      alive: true
    }
  end

  @doc """
  A scene of `players`: options `:time`, `:day`, `:ticks`, `:step`,
  `:difficulty`, `:bright`, `:monsters_burn`, `:halloween`, `:darken`, `:knots`,
  `:acts`, `:moves`, `:level` (the level random's seed), `:statues`,
  `:post`, `:collide`, `:loot`, `:griefing` (`mobGriefing`),
  `:universal_anger`, `:items` (sensed item rows, `item/4`), `:treasure`
  (where structure queries find it at once), `:villages` (the sections
  holding an occupied village POI), `:events` (`{tick, player index,
  seen}`: a player angering piglins), `:loot_seeds` (each tick's loot
  rolls).
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
      darken: Keyword.get(opts, :darken, 0),
      rules: %{
        mob_griefing: Keyword.get(opts, :griefing, true),
        mob_drops: true,
        entity_drops: true,
        universal_anger: Keyword.get(opts, :universal_anger, false)
      },
      knots: Keyword.get(opts, :knots, []),
      acts: Keyword.get(opts, :acts, []),
      moves: Keyword.get(opts, :moves, []),
      level_seed: AI.Random.new(Keyword.get(opts, :level, 7)),
      statues: Keyword.get(opts, :statues, []),
      post: Keyword.get(opts, :post, false),
      collide: Keyword.get(opts, :collide, []),
      loot: Keyword.get(opts, :loot),
      items: Keyword.get(opts, :items, []),
      treasure: Keyword.get(opts, :treasure),
      villages: Keyword.get(opts, :villages),
      events: Keyword.get(opts, :events, []),
      loot_seeds: Keyword.get(opts, :loot_seeds, [])
    }
  end
end
