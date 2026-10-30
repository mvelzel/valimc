defmodule Valimc.NativeMobTurtleCatTest do
  @moduledoc """
  The native turtles and cats (VMC-081d, `valimc_core::mobs::animals::{turtle,
  cat}`) against `Valimc.Entity.Animals.Turtle` and `Cat`: their registered
  goals against vanilla's, and whole sections of them thinking tick by
  tick over generated terrain with a sand beach laid along its water
  (`Valimc.NativeMobScene`), every record, mind and effect and the level
  random equal every tick: turtles heading for water, travelling, going
  home, panicking, breeding into eggs, laying them and growing up; cats
  tempted, avoiding players, hunting rabbits, breeding and spawning.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.AI.World
  alias Valimc.Native
  alias Valimc.Protocol.ItemTypes

  setup_all do
    ctx = setup()
    beach(ctx)
  end

  # The land columns within eight blocks of water get a sand top, and the
  # path view is taken again over them.
  defp beach(%{blocks: blocks} = ctx) do
    world = %World{read: &read(blocks, &1)}
    pools = water(blocks, 40, :rand.seed_s(:exsss, 401))
    land = land(blocks, 400, :rand.seed_s(:exsss, 402))

    sand =
      for {x, y, z} <- land,
          Enum.any?(pools, fn {wx, _, wz} -> abs(wx - x) <= 8 and abs(wz - z) <= 8 end),
          World.fluid(world, {x, y - 1, z}) == :empty,
          into: %{},
          do: {{x, y - 1, z}, Valimc.Protocol.Data.block("sand")}

    :ok = Valimc.World.Blocks.put(blocks, sand)
    size = Valimc.Data.Grid.region_size()
    region = for cx <- 0..(size - 1), cz <- 0..(size - 1), do: {{cx, cz}, nil}
    handles = Valimc.World.Blocks.snapshots(blocks, region, 2)
    view = {:rows, Enum.reject(handles, &is_nil/1), Valimc.Protocol.Data.block("air")}
    beach = for {{x, y, z}, _} <- sand, do: {x, y + 1, z}
    Map.merge(ctx, %{view: view, beach: Enum.sort(beach), pools: pools})
  end

  test "turtles and cats are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()
    for type <- ~w(minecraft:turtle minecraft:cat), do: assert(type in types)
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)
  defp records(observed), do: List.flatten(for {r, _, _, _} <- observed, do: r)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  defp soaked do
    water = Valimc.Protocol.Data.block("water")
    [water: 1.0, eye_water: true, eye: {true, water}]
  end

  ## Turtles

  test "turtles head for water, travel, panic, go home and grow up", ctx do
    {land, _} = Enum.split(ctx.beach, 6)
    {[tempting | pools], _} = Enum.split(ctx.pools, 6)
    seagrass = ItemTypes.id("minecraft:seagrass")

    on_land =
      for {{x, y, z} = spot, n} <- Enum.with_index(land, 1) do
        age = Enum.at([0, -24_000, -3, 0, 0, 0], n - 1)
        mob(n, "minecraft:turtle", spot, age: age, data: [home: {x, y, z}])
      end

    swimming =
      for {{x, y, z}, n} <- Enum.with_index(pools, 20) do
        home = {x + 90 * rem(n, 2), y, z - 70}
        mob(n, "minecraft:turtle", {x, y - 2, z}, motion: soaked(), data: [home: home])
      end

    {px, py, pz} = tempting
    player = %{player(0, tempting, mainhand: seagrass) | position: {px + 0.5, py * 1.0, pz}}

    scene =
      scene([player],
        ticks: 360,
        acts: [{20, 0, :hurt}, {25, 3, :hurt}],
        post: true,
        level: 403
      )

    observed = compare(ctx, scene, on_land ++ swimming)
    assert running?(observed, "Valimc.Entity.Animals.Turtle.GoToWater")
    assert running?(observed, "Valimc.Entity.Animals.Turtle.Travel")
    assert running?(observed, "Valimc.AI.Goals.Panic")
    assert Enum.any?(effects(observed), &match?({:gift, "minecraft:gameplay/turtle_grow", _}, &1))
  end

  test "turtles far from home head back", ctx do
    {[_ | pools], _} = Enum.split(ctx.pools, 12)

    entries =
      for {{x, y, z}, n} <- Enum.with_index(pools, 1) do
        mob(n, "minecraft:turtle", {x, y - 2, z},
          motion: soaked(),
          data: [home: {x + 100, y, z + 80}, has_egg: rem(n, 4) == 0]
        )
      end

    observed = compare(ctx, scene([], ticks: 400, post: true, level: 404), entries)
    assert running?(observed, "Valimc.Entity.Animals.Turtle.GoHome")
  end

  test "turtles breed into an egg, take it home and lay it on sand", ctx do
    [{x, y, z} = a | rest] = ctx.beach

    {b, _} =
      Enum.min_by(
        for(s <- rest, s != a, do: {s, dist(s, a)}),
        fn {_, d} -> d end
      )

    entries = [
      mob(1, "minecraft:turtle", a, data: [home: {x, y, z}]),
      mob(2, "minecraft:turtle", b, data: [home: {x, y, z}])
    ]

    scene = scene([], ticks: 520, acts: [{0, 0, :love}, {0, 1, :love}], post: true, level: 405)
    observed = compare(ctx, scene, entries)
    assert Enum.any?(records(observed), &(&1.data[:has_egg] == true))
    assert running?(observed, "Valimc.Entity.Animals.Turtle.LayEgg")
    assert Enum.any?(effects(observed), &match?({:lay_eggs, _, _}, &1))
    assert Enum.any?(effects(observed), &match?({:sound_block, _, "blocks", _, _}, &1))
  end

  ## Cats

  test "cats spawn, are tempted by fish, avoid players, hunt rabbits and breed", ctx do
    spots = land(ctx.blocks, 24, :rand.seed_s(:exsss, 411))
    {[fish, walker | rabbits], rest} = Enum.split(spots, 6)
    cod = ItemTypes.id("minecraft:cod")

    cats =
      for {spot, n} <- Enum.with_index(rest, 1) do
        mob(n, "minecraft:cat", spot,
          age: if(rem(n, 5) == 0, do: -24_000, else: 0),
          finalize: if(rem(n, 3) != 0, do: :natural)
        )
      end

    prey =
      for {spot, n} <- Enum.with_index(rabbits, 40), do: mob(n, "minecraft:rabbit", spot)

    players = [player(0, fish, mainhand: cod), player(1, walker)]
    {wx, wy, wz} = walker

    # The second player walks about; the first stands holding cod.
    moves =
      for t <- 0..299 do
        step = rem(div(t, 40), 2) * 3.0
        {fx, fy, fz} = hd(players).position

        [
          {{fx, fy, fz}, {0.0, 0.0, 0.0}},
          {{wx + 0.3 + step, wy * 1.0, wz + 0.7}, {0.1, 0.0, 0.0}}
        ]
      end

    for {level, day} <- [{412, 6000}, {413, 24_000 * 8 + 6000}] do
      scene =
        scene(players,
          ticks: 300,
          day: day,
          moves: moves,
          acts: [{10, 0, :love}, {10, 1, :love}],
          post: true,
          level: level
        )

      observed = compare(ctx, scene, cats ++ prey)
      assert running?(observed, "Valimc.Entity.Animals.Cat.Tempt")
      assert running?(observed, "Valimc.AI.Goals.AvoidEntity")
      assert Enum.any?(minds(observed), &(is_tuple(&1) and match?({:mob, _}, elem(&1, 4))))
      records = records(observed)
      assert Enum.any?(records, &(&1.data[:variant] not in [nil, "minecraft:black"]))
    end
  end

  test "cats breed, and strays tempted by a player beg", ctx do
    [{x, y, z} = a | rest] = land(ctx.blocks, 40, :rand.seed_s(:exsss, 414))
    near = rest |> Enum.sort_by(&dist(&1, a)) |> Enum.take(3)
    cats = for {spot, n} <- Enum.with_index([a | near], 1), do: mob(n, "minecraft:cat", spot)

    scene = scene([], ticks: 200, acts: [{0, 0, :love}, {0, 1, :love}], post: true, level: 415)
    observed = compare(ctx, scene, cats)
    assert Enum.any?(effects(observed), &match?({:offspring, "minecraft:cat", _, _}, &1))

    cod = ItemTypes.id("minecraft:cod")
    beg = Valimc.Entity.Animal.sound_id("minecraft:entity.cat.beg_for_food")

    holding = %{
      player(0, a, mainhand: cod, yaw: 0.0, pitch: 0.0)
      | position: {x + 3.5, y * 1.0, z + 0.5}
    }

    observed = compare(ctx, scene([holding], ticks: 220, post: true, level: 416), cats)
    assert running?(observed, "Valimc.Entity.Animals.Cat.Tempt")
    assert Enum.any?(effects(observed), &match?({:sound, ^beg, _, _, _}, &1))
  end

  defp dist({x, y, z}, {a, b, c}), do: (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c)
end
