defmodule Valimc.NativeMobAnimalTest do
  @moduledoc """
  The native farm animals and think step (VMC-081d,
  `valimc_core::mobs::{kinds, animals, ai::think}`) against `Valimc.AI` and
  `Valimc.Entity.Animal`: the families' registered goals against vanilla's;
  whole sections of animals thinking tick by tick over generated terrain
  (the scene's acts, `AI.prepare`, each mob's `think_mob`, a scripted move
  toward its wanted position, `settle`, its sensing again, `AI.finish`),
  every mob's record, mind and effects and the level random equal every
  tick; and the interactions (milk, stew, shear, dye, feed, golden
  dandelion) on both sides.
  """
  use ExUnit.Case, async: true

  alias Valimc.AI
  alias Valimc.AI.{Mind, Selector, Self, World}
  alias Valimc.Data.{EffectTypes, EntityTypes}
  alias Valimc.Entity.{Animal, Body, Mob, Store}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Living.Attributes
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.Worldgen.Generator

  @seed 20_261_029
  @zoom_seed -4_172_144_997_902_289_642
  @chunks for cx <- 0..2, cz <- 0..2, do: {cx, cz}

  setup_all do
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

  test "the farm animals are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    assert types ==
             ~w(minecraft:chicken minecraft:cow minecraft:mooshroom minecraft:pig minecraft:rabbit minecraft:sheep)
  end

  ## The Elixir side

  defp world(blocks, view, players, time, scene) do
    read = fn {x, y, z} ->
      case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
        {:ok, <<state::16>>} -> state
        _ -> nil
      end
    end

    %World{
      read: read,
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

  defp entry_record(id, entry),
    do:
      Store.record(%{
        kind: :mob,
        entity: Map.put(entry.entity, :entity_id, id),
        body: entry.body,
        hops: 0
      })

  # One tick of the section as the native parity runs it.
  defp tick(entries, world, scene, tick) do
    entries = act(entries, scene, tick)
    {mobs, world, ctx} = AI.prepare(entries, world)
    old = Map.new(mobs)

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

        {body, {px, py, pz}, settled, world} =
          AI.settle({id, old[id]}, body, {nx, y, nz}, world)

        entry = %{entry | body: body, entity: %{entry.entity | x: px, y: py, z: pz}}
        world = AI.resense_entry(world, id, entry)
        {{id, entry}, {ctx, world, made ++ [effects ++ settled]}}
      end)

    bodies = AI.finish(ctx, Enum.map(results, fn {id, e} -> {id, e.body} end), mobs)

    entries =
      Enum.zip_with(results, bodies, fn {id, e}, {id, body} -> {id, %{e | body: body}} end)

    {entries, world, made}
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

  defp mind(%Body{mob: %Mob{ai: %Mind{} = m} = mob}) do
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

  defp mind(_body), do: nil

  defp sound_id(id) when is_integer(id), do: id
  defp sound_id(name), do: Animal.sound_id(name)

  defp effect({:sound, id, source, volume, pitch, _seed}), do: {:sound, id, source, volume, pitch}

  defp effect({:sound_at, id, _source, at, volume, pitch}),
    do: {:sound_at, sound_id(id), at, volume, pitch}

  defp effect({:offspring, type, data, at}),
    do: {:offspring, type, Map.delete(data, :egg_time), at}

  defp effect({kind, _} = e)
       when kind in [:event, :bred, :lay, :lead, :knot_free, :make_knot, :raid_carrot, :attack],
       do: e

  defp effect({:eat_block, _, _} = e), do: e
  defp effect({:orb, _, _} = e), do: e
  defp effect({:alert, _, _} = e), do: e
  defp effect({:swing, _}), do: {:swing}
  defp effect(_), do: {:other}

  defp compare(%{blocks: blocks, view: view, facts: facts}, scene, entries) do
    records = for {id, e} <- entries, do: {id, entry_record(id, e)}

    # Both sides start from what the records keep.
    entries =
      for {id, e} <- entries do
        {:ok, body} = Body.restore(entry_record(id, e))
        {id, %{e | body: body}}
      end

    expected = run(blocks, view, scene, entries)
    native = Native.mob_parity_think(blocks.ref, @zoom_seed, facts, %{scene | mobs: records})
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

  defp uuid(n), do: <<n::64, n * 7919::64>>

  defp surface(blocks, x, z) do
    world = %World{read: &read(blocks, &1)}
    World.motion_blocking(world, x, z)
  end

  defp read(blocks, {x, y, z}) do
    case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
      {:ok, <<state::16>>} -> state
      _ -> nil
    end
  end

  # Land columns: the block below the surface is no fluid.
  defp land(blocks, count, rand) do
    world = %World{read: &read(blocks, &1)}

    Stream.unfold(rand, fn rand ->
      {x, rand} = :rand.uniform_s(24, rand)
      {z, rand} = :rand.uniform_s(24, rand)
      {{x + 11, z + 11}, rand}
    end)
    |> Stream.map(fn {x, z} -> {x, surface(blocks, x, z), z} end)
    |> Stream.filter(fn {x, y, z} -> World.fluid(world, {x, y - 1, z}) == :empty end)
    |> Enum.take(count)
  end

  defp animal(n, type, {x, y, z}, opts \\ []) do
    {:ok, body} = Body.new(type)
    data = Map.merge(body.data, Map.new(Keyword.get(opts, :data, [])))
    data = Map.put(data, :age, Keyword.get(opts, :age, 0))
    yaw = Keyword.get(opts, :yaw, 15.0 * n)
    body = %{body | data: data, yaw: yaw, head_yaw: yaw, on_ground: true}
    body = %{body | mob: %{body.mob | no_ai: Keyword.get(opts, :no_ai, false)}}

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

  defp player(n, {x, y, z}, opts \\ []) do
    %{
      uuid: uuid(1000 + n),
      id: 1000 + n,
      position: {x + 0.3, y * 1.0, z + 0.7},
      yaw: 12.5,
      pitch: -3.0,
      mode: Keyword.get(opts, :mode, :survival),
      mainhand: Keyword.get(opts, :mainhand),
      movement: {0.0, 0.0, 0.0}
    }
  end

  defp scene(players, opts) do
    %{
      mobs: [],
      players: players,
      time: Keyword.get(opts, :time, 6000),
      day: Keyword.get(opts, :day, 6000),
      ticks: Keyword.get(opts, :ticks, 200),
      step: Keyword.get(opts, :step, 0.2),
      difficulty: :normal,
      bright: true,
      rules: %{mob_griefing: true, mob_drops: true, entity_drops: true},
      knots: Keyword.get(opts, :knots, []),
      acts: Keyword.get(opts, :acts, []),
      moves: Keyword.get(opts, :moves, []),
      level_seed: AI.Random.new(Keyword.get(opts, :level, 7))
    }
  end

  @types ~w(minecraft:cow minecraft:pig minecraft:sheep minecraft:chicken minecraft:mooshroom minecraft:rabbit)

  test "farm animals wander, graze, follow, look and tempt", ctx do
    spots = land(ctx.blocks, 16, :rand.seed_s(:exsss, 91))
    wheat = ItemTypes.id("minecraft:wheat")
    {[here, there], rest} = Enum.split(spots, 2)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@types)), 1) do
        animal(n, type, spot, age: if(rem(n, 4) == 0, do: -24_000, else: 0))
      end

    players = [player(0, here, mainhand: wheat), player(1, there)]
    observed = compare(ctx, scene(players, ticks: 240), entries)
    flat = List.flatten(for {_, minds, _, _} <- observed, do: minds)
    assert Enum.any?(flat, &(is_tuple(&1) and "Valimc.AI.Goals.RandomStroll" in elem(&1, 3)))
  end

  test "animals spawn, fall in love, breed and grow", ctx do
    [base | _] = land(ctx.blocks, 1, :rand.seed_s(:exsss, 92))
    {x, y, z} = base

    entries =
      for {type, k} <- Enum.with_index(@types), side <- [0, 1] do
        animal(1 + 2 * k + side, type, {x + side, y, z + 2 * k},
          finalize: :natural,
          data: if(type == "minecraft:sheep", do: [color: 4 + side], else: [])
        )
      end

    baby = animal(30, "minecraft:cow", {x + 1, y, z + 1}, age: -1200)
    entries = entries ++ [baby]
    acts = for(i <- 0..11, do: {2, i, :love}) ++ [{5, 12, :feed}, {6, 12, :feed}]
    observed = compare(ctx, scene([], ticks: 160, acts: acts, level: 11), entries)
    effects = List.flatten(for {_, _, e, _} <- observed, do: e)
    assert Enum.any?(effects, &match?({:offspring, _, _, _}, &1))
    assert Enum.any?(effects, &match?({:orb, _, _}, &1))
  end

  test "rabbits hop, flee players and panic", ctx do
    spots = land(ctx.blocks, 6, :rand.seed_s(:exsss, 93))
    {[here], rest} = Enum.split(spots, 1)
    entries = for {spot, n} <- Enum.with_index(rest, 1), do: animal(n, "minecraft:rabbit", spot)
    acts = for i <- 0..4, do: {20 + 10 * i, i, :hurt}

    observed =
      compare(ctx, scene([player(0, here, mode: :creative)], ticks: 200, acts: acts), entries)

    flat = List.flatten(for {_, minds, _, _} <- observed, do: minds)
    assert Enum.any?(flat, &(is_tuple(&1) and is_map(elem(&1, 8))))

    assert Enum.any?(
             flat,
             &(is_tuple(&1) and "Valimc.Entity.Animals.Rabbit.Panic" in elem(&1, 3))
           )
  end

  test "sheep and lambs graze; hurt animals panic", ctx do
    spots = land(ctx.blocks, 14, :rand.seed_s(:exsss, 95))
    {[here], rest} = Enum.split(spots, 1)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        type = if n <= 9, do: "minecraft:sheep", else: Enum.at(@types, n - 10)
        animal(n, type, spot, age: if(rem(n, 2) == 0, do: -24_000, else: 0))
      end

    acts = for i <- 9..12, do: {30, i, :hurt}
    observed = compare(ctx, scene([player(0, here)], ticks: 400, acts: acts), entries)
    effects = List.flatten(for {_, _, e, _} <- observed, do: e)
    flat = List.flatten(for {_, minds, _, _} <- observed, do: minds)
    assert Enum.any?(effects, &match?({:eat_block, _, _}, &1))
    assert Enum.any?(flat, &(is_tuple(&1) and "Valimc.AI.Goals.Panic" in elem(&1, 3)))
  end

  test "leads walk, pull, break and tether", ctx do
    [a, b] = land(ctx.blocks, 2, :rand.seed_s(:exsss, 94))
    {ax, ay, az} = a
    holder = player(0, a)
    knot = {elem(b, 0), elem(b, 1) + 1, elem(b, 2)}

    entries = [
      animal(1, "minecraft:cow", {ax + 2, ay, az}, leash: {:player, holder.uuid}),
      animal(2, "minecraft:pig", b, leash: {:knot, knot}),
      animal(3, "minecraft:sheep", {ax - 2, ay, az}, leash: {:player, holder.uuid})
    ]

    # The holder walks away along x, faster and faster, until the leads break.
    moves =
      for t <- 0..119 do
        dx = t * t * 0.002
        [{{ax + 0.3 + dx, ay * 1.0, az + 0.7}, {0.004 * t, 0.0, 0.0}}]
      end

    {kx, ky, kz} = knot

    observed =
      compare(ctx, scene([holder], ticks: 120, moves: moves, knots: [{kx, ky, kz, 77}]), entries)

    effects = List.flatten(for {_, _, e, _} <- observed, do: e)
    assert Enum.any?(effects, &match?({:lead, _}, &1))
  end

  ## Interactions

  @holder {2.5, 64.0, 0.5}

  # `{player uuid, at, id}` of the player using the item (a holder for leads).
  defp interact(ctx, body, item, opts \\ []) do
    body = put_in(body.mob.ai, AI.mind(body.type, uuid(1), nil, body.data))
    at = {0.5, 64.0, 0.5}
    record = entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})
    {:ok, restored} = Body.restore(record)
    player = uuid(2000)
    infinite = Keyword.get(opts, :infinite, false)
    leash_id = Keyword.get(opts, :held)

    # A lead held now (a record's looks for its holder).
    restored =
      if leash_id,
        do: update_in(restored.mob.leash, &%{&1 | restored: false, id: leash_id}),
        else: restored

    {native, native_record} =
      Native.mob_parity_interact(
        ctx.facts,
        record,
        item || nil,
        {player, @holder, 2000},
        infinite,
        leash_id,
        []
      )

    {hx, hy, hz} = @holder
    w = Valimc.Data.Float32.round(0.6)
    h = Valimc.Data.Float32.round(1.8)

    request = %{
      item: item,
      infinite: infinite,
      player: player,
      holder: %{id: 2000, x: hx, y: hy, z: hz, width: w, height: h}
    }

    elixir =
      with :pass <- Valimc.Entity.Leashes.interact(restored, at, request),
           do: Interaction.interact(restored, request)

    seedless = fn events ->
      Enum.map(events, fn
        {kind, id, source, volume, pitch, _seed} -> {kind, sound(id), source, volume, pitch}
        e -> e
      end)
    end

    case {native, elixir} do
      {:pass, :pass} ->
        :pass

      {:consume, :consume} ->
        :consume

      {{:done, hand, swing, events, others, drops, convert, free}, {:ok, body, outcome}} ->
        assert hand == outcome.hand
        assert swing == outcome.swing
        assert events == seedless.(outcome.events)
        assert others == outcome.others
        assert free == outcome.free

        assert Enum.map(drops, &elem(&1, 0)) == Enum.map(outcome.drops, &elem(&1, 0))

        if convert != nil,
          do:
            assert(
              convert ==
                entry_record(1, %{
                  entity: Map.take(record, [:uuid, :x, :y, :z]),
                  body: outcome.convert
                })
            )

        assert native_record ==
                 entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})

        :done
    end
  end

  defp sound(id) when is_integer(id), do: id
  defp sound(name), do: Animal.sound_id(name)

  test "leads tie, untie, snip and move from knots", ctx do
    stack = &ItemStack.new/1
    {:ok, cow} = Body.new("minecraft:cow")
    lead = stack.("minecraft:lead")
    assert interact(ctx, cow, lead) == :done

    held =
      put_in(cow.mob.leash, %{
        holder: {:player, uuid(2000)},
        id: 2000,
        momentum: 0.25,
        restored: false
      })

    assert interact(ctx, held, stack.("minecraft:stick"), held: 2000) == :done
    assert interact(ctx, held, stack.("minecraft:stick"), held: 2000, infinite: true) == :done
    assert interact(ctx, held, stack.("minecraft:shears"), held: 2000) == :done

    knotted =
      put_in(cow.mob.leash, %{holder: {:knot, {3, 64, 0}}, id: 9, momentum: 0.0, restored: false})

    assert interact(ctx, knotted, lead, held: 9) == :done
    assert interact(ctx, knotted, stack.("minecraft:shears"), held: 9) == :done

    restored =
      put_in(cow.mob.leash, %{holder: {:knot, {3, 64, 0}}, id: nil, momentum: 0.0, restored: true})

    assert interact(ctx, restored, lead) == :done
    assert interact(ctx, held, stack.("minecraft:stick")) == :pass
  end

  test "milk, stew, dye, food and the golden dandelion", ctx do
    stack = &ItemStack.new/1
    {:ok, cow} = Body.new("minecraft:cow")
    assert interact(ctx, cow, stack.("minecraft:bucket")) == :done
    assert interact(ctx, cow, stack.("minecraft:wheat")) == :done
    assert interact(ctx, cow, stack.("minecraft:stone")) == :pass
    calf = %{cow | data: %{cow.data | age: -2000}}
    assert interact(ctx, calf, stack.("minecraft:wheat")) == :done
    assert interact(ctx, calf, stack.("minecraft:golden_dandelion")) == :done
    {:ok, pig} = Body.new("minecraft:pig")
    assert interact(ctx, pig, stack.("minecraft:carrot")) == :done
    {:ok, moo} = Body.new("minecraft:mooshroom")
    brown = %{moo | data: %{moo.data | type: "brown"}}
    assert interact(ctx, moo, stack.("minecraft:bowl")) == :done
    assert interact(ctx, brown, stack.("minecraft:allium")) == :done
    stewed = %{brown | data: %{brown.data | stew: [{"minecraft:fire_resistance", 60}]}}
    assert interact(ctx, stewed, stack.("minecraft:bowl")) == :done
    {:ok, sheep} = Body.new("minecraft:sheep")
    assert interact(ctx, sheep, stack.("minecraft:red_dye")) == :done
    assert interact(ctx, sheep, stack.("minecraft:white_dye")) == :pass
    sheared = %{sheep | data: %{sheep.data | sheared: true}}
    assert interact(ctx, sheared, stack.("minecraft:shears")) == :consume
  end
end
