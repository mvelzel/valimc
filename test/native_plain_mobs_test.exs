defmodule Valimc.NativePlainMobsTest do
  @moduledoc """
  VMC-081d: the plain mobs (living types without Elixir AI) simulated whole
  in Rust give, tick by tick, the records the Elixir simulation gives: the
  same scenes run through a store of Elixir bodies and `MobTicks.steps/5`,
  and through a store whose plain mobs live in a native section and
  `MobTicks.native_steps/7` (an Elixir mob among them yielding its turns),
  with the owner's ageing between ticks, compared exactly after every
  tick.

  Exact includes the mobs' own random states where neither side draws on
  them. An Elixir plain mob never thinks, so its mind stays its record's
  `%{random: r}` map, which none of the Elixir rules draws on: its hurt
  sounds and death drops draw `:rand` and it makes no splash or hiss. A
  native one draws all of these from its own random, as vanilla's entity
  random (made from its uuid where its record has none). Scenes where those
  happen compare everything but a plain mob's `ai`.
  """
  use ExUnit.Case, async: true

  alias Valimc.AI
  alias Valimc.Data.{Blocks, EffectTypes}
  alias Valimc.Entity.{Body, MobTicks, NativeMobs, Store}
  alias Valimc.Native

  @key {0, 0}
  @air 0

  setup_all do
    Valimc.Data.BlockFacts.install!()
    NativeMobs.install!()
    :ok
  end

  # A scene's blocks as a supplied view: a stone floor at y 63 over x and z
  # 24..72, a water pool, a ledge, a lava cell and a magma block.
  defp scene do
    stone = Blocks.default_state("stone")
    water = Blocks.default_state("water")
    lava = Blocks.default_state("lava")
    magma = Blocks.default_state("magma_block")

    floor = for x <- 24..72, z <- 24..72, into: %{}, do: {{x, 63, z}, stone}
    pool = for x <- 50..54, y <- 64..66, z <- 30..34, into: %{}, do: {{x, y, z}, water}

    walls =
      for x <- 49..55,
          y <- 64..66,
          z <- 29..35,
          x in [49, 55] or z in [29, 35],
          into: %{},
          do: {{x, y, z}, stone}

    ledge = for x <- 40..41, y <- 64..67, z <- 40..41, into: %{}, do: {{x, y, z}, stone}

    blocks =
      floor
      |> Map.merge(walls)
      |> Map.merge(pool)
      |> Map.merge(ledge)
      |> Map.put({36, 64, 36}, lava)
      |> Map.put({44, 63, 30}, magma)

    packed =
      for x <- 16..80, y <- 56..90, z <- 16..80, into: <<>> do
        <<x::signed-32, y::signed-32, z::signed-32, Map.get(blocks, {x, y, z}, @air)::16>>
      end

    {:states, packed}
  end

  defp body(type, opts) do
    {:ok, body} = Body.new(type)
    mob = body.mob

    mob =
      case Keyword.get(opts, :seed) do
        nil -> mob
        seed -> %{mob | ai: %AI.Mind{random: AI.Random.new(seed)}}
      end

    living = mob.living
    living = %{living | fire_ticks: Keyword.get(opts, :fire, living.fire_ticks)}

    living =
      Enum.reduce(Keyword.get(opts, :effects, []), living, fn {name, rung}, living ->
        %{living | effects: Map.put(living.effects, EffectTypes.id(name), [rung])}
      end)

    living =
      case Keyword.get(opts, :health) do
        nil -> living
        h -> %{living | health: %{living.health | value: h}}
      end

    %{
      body
      | mob: %{mob | living: living},
        velocity: Keyword.get(opts, :velocity, body.velocity),
        yaw: Keyword.get(opts, :yaw, 0.0),
        head_yaw: Keyword.get(opts, :yaw, 0.0)
    }
  end

  # The scene's mobs: `{n, type, position, opts}`; `n` names the uuid.
  defp mobs(:minds) do
    [
      {1, "minecraft:wolf", {40.5, 74.0, 50.5}, seed: 11},
      {2, "minecraft:horse", {45.5, 64.0, 45.5}, seed: 12},
      {3, "minecraft:goat", {52.5, 70.0, 32.5}, seed: 13},
      {4, "minecraft:fox", {30.5, 64.0, 30.5}, seed: 14},
      {5, "minecraft:fox", {30.7, 64.0, 30.6}, seed: 15},
      {6, "minecraft:panda", {36.5, 64.0, 36.5}, seed: 16},
      {7, "minecraft:polar_bear", {60.5, 64.0, 60.5}, seed: 17, velocity: {0.6, 0.2, -0.3}},
      {8, "minecraft:frog", {33.5, 64.0, 60.5}, seed: 18, fire: 120},
      {9, "minecraft:parrot", {41.0, 68.0, 41.0}, seed: 19},
      {10, "minecraft:pillager", {66.5, 64.0, 33.5}, seed: 20, health: 0.0},
      {11, "minecraft:ravager", {28.5, 64.0, 66.5},
       seed: 21,
       effects: [
         {"poison", {80, 1, false, true, true}},
         {"regeneration", {60, 0, false, true, true}}
       ]},
      {12, "minecraft:zombie_horse", {44.5, 64.0, 30.5}, seed: 22},
      {13, "minecraft:camel", {41.5, 68.0, 40.2}, seed: 23},
      {14, "minecraft:allay", {58.5, 72.0, 44.5}, seed: 24},
      {15, "minecraft:armadillo", {47.5, 64.0, 58.5},
       seed: 25, effects: [{"slow_falling", {200, 0, false, true, true}}]}
    ]
  end

  defp mobs(:plain) do
    [
      {21, "minecraft:llama", {35.5, 64.0, 45.5}, []},
      {22, "minecraft:donkey", {35.9, 64.0, 45.7}, []},
      {23, "minecraft:camel", {62.5, 65.5, 52.5}, []},
      {24, "minecraft:armadillo", {48.5, 64.0, 48.5}, velocity: {0.3, 0.0, 0.2}},
      {25, "minecraft:sniffer", {56.5, 64.0, 56.5}, []}
    ]
  end

  # Plain mobs with Elixir mobs among them, whose turns yield.
  defp mobs(:mixed) do
    [
      {31, "minecraft:wolf", {38.5, 64.0, 38.5}, seed: 31},
      {32, "minecraft:zombie", {38.7, 64.0, 38.6}, seed: 32},
      {33, "minecraft:cow", {46.5, 70.0, 46.5}, seed: 33},
      {34, "minecraft:goat", {46.6, 64.0, 46.4}, seed: 34},
      {35, "minecraft:husk", {52.5, 69.0, 32.5}, seed: 35},
      {36, "minecraft:fox", {52.6, 67.0, 32.4}, seed: 36}
    ]
  end

  defp records(scene) do
    for {n, type, position, opts} <- mobs(scene),
        do: Store.body_record(body(type, opts), <<n::128>>, position)
  end

  defp store(records, native) do
    {:ok, store} = Store.restore(@key, records, Store.empty_ledger(), native)
    store
  end

  defp world(players) do
    %AI.World{
      players: players,
      random: AI.Random.new(4242),
      goals: false,
      mob_griefing: true
    }
  end

  @env %{
    monsters_burn: false,
    darken: 0,
    wet: false,
    sea_level: 63,
    zoom_seed: 0,
    mob_griefing: true,
    region: nil
  }

  # One owner tick of the store's bodies and mobs, as `RegionData` runs it:
  # the timers (`Store.age_chunks`), then the mobs' turns, their steps
  # applied in the section.
  defp tick(store, world, view, tick) do
    chunks =
      for {_, %{entity: e}} <- store.entries,
          into: %{},
          do: {Valimc.Data.Grid.chunk_key(e.x, e.z), 1}

    {store, expired} = Store.age_chunks(store, chunks, -64, tick)

    store =
      Enum.reduce(expired, store, fn {epoch, id, revision}, store ->
        {:ok, store} = Store.remove(store, epoch, id, revision)
        store
      end)

    mobs =
      for {id, %{kind: :mob} = entry} <- store.entries,
          not Store.simulated?(entry, tick),
          do: {id, entry}

    {steps, world} =
      if store.native,
        do: MobTicks.native_steps(view, Enum.sort(mobs), world, nil, [], store.native, @env),
        else: MobTicks.steps(view, Enum.sort(mobs), world, nil)

    store = Store.mark_simulated(store, Enum.map(steps, & &1.id), tick)

    steps =
      Enum.reject(steps, fn step ->
        %{entity: e, body: body} = store.entries[step.id]
        step.events == [] and step.body == body and step.position == {e.x, e.y, e.z}
      end)

    store =
      Enum.reduce(Enum.chunk_every(steps, 32), store, fn batch, store ->
        {:ok, store, _} = Store.advance(store, @key, store.epoch, batch)
        store
      end)

    {store, world}
  end

  defp snapshot(store, exact \\ true) do
    store
    |> Store.records()
    |> Enum.map(&Map.delete(&1, :hops))
    |> Enum.map(fn record ->
      if exact or not MapSet.member?(NativeMobs.plain_types(), record.type),
        do: record,
        else: put_in(record.mob.ai, :drawn)
    end)
    |> :erlang.term_to_binary([:deterministic])
  end

  defp compare(scene, ticks, players \\ [], exact \\ false) do
    view = scene()
    records = records(scene)
    native = %NativeMobs{ref: Native.mob_section_new(0, 0), types: NativeMobs.plain_types()}
    elixir_store = store(records, nil)
    native_store = store(records, native)
    assert Enum.any?(native_store.entries, fn {_, e} -> Store.native_entry?(e) end)
    assert snapshot(elixir_store) == snapshot(native_store)

    Enum.reduce(1..ticks, {elixir_store, native_store, world(players), world(players)}, fn t,
                                                                                           {es,
                                                                                            ns,
                                                                                            ew,
                                                                                            nw} ->
      {es, ew} = tick(es, ew, view, t)
      {ns, nw} = tick(ns, nw, view, t)
      elixir = Store.records(es)
      natives = Store.records(ns)

      if snapshot(es, exact) != snapshot(ns, exact) do
        diff =
          for {a, b} <- Enum.zip(elixir, natives),
              exact or not MapSet.member?(NativeMobs.plain_types(), a.type) or
                put_in(a.mob.ai, nil) != put_in(b.mob.ai, nil) do
            {a.type, for({k, v} <- a, Map.get(b, k) != v, do: {k, v, Map.get(b, k)})}
          end

        flunk("#{scene} tick #{t}: records differ #{inspect(diff, limit: :infinity)}")
      end

      assert ew.random == nw.random, "#{scene} tick #{t}: level random"
      assert map_size(es.entries) == map_size(ns.entries)
      {es, ns, ew, nw}
    end)
    |> elem(1)
    |> Store.records()
    |> Map.new(&{&1.uuid, &1})
  end

  defp at(records, n), do: records[<<n::128>>]

  test "plain mobs with minds: falls, water, pushes, lava, fire, effects, death" do
    records = compare(:minds, 200)
    # The wolf fell ten blocks: seven points of its eight.
    assert at(records, 1).y == 64.0 and at(records, 1).mob.living.health.value == 1.0
    # The goat swims in the pool; the panda burned to death in the lava.
    assert at(records, 3).mob.motion.water > 0.0
    assert at(records, 6) == nil
    # The pillager's death animation ended: it is gone.
    assert at(records, 10) == nil
    # The foxes pushed each other apart.
    assert at(records, 4).x != 30.5
  end

  test "plain mobs without minds, pushed by a player" do
    player = %{
      kind: :player,
      uuid: <<9::128>>,
      id: 900_000,
      x: 48.6,
      y: 64.0,
      z: 48.4,
      mode: :survival,
      alive: true
    }

    compare(:plain, 120, [player], true)
  end

  test "plain mobs among Elixir mobs: the Elixir ones yield their turns in id order" do
    compare(:mixed, 120)
  end
end
