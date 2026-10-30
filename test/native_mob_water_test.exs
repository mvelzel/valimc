defmodule Valimc.NativeMobWaterTest do
  @moduledoc """
  The native water and ambient families (VMC-081d,
  `valimc_core::mobs::{water, ambient}`) against `Valimc.AI.Mobs`: their
  registered goals against vanilla's, and whole sections of them thinking
  tick by tick over generated terrain (`Valimc.NativeMobScene`), every
  record, mind and effect and the level random equal every tick: fish
  schooling, fleeing, panicking, flopping and puffing; squid stroking,
  fleeing and inking; guardians beaming, paying back hits with thorns and
  elders cursing; bats roosting, waking and flying. Dolphins have their
  own test (`native_mob_dolphin_test`).
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Native

  setup_all do
    setup()
  end

  test "the water families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <-
          ~w(minecraft:cod minecraft:salmon minecraft:pufferfish minecraft:tropical_fish
             minecraft:squid minecraft:glow_squid minecraft:guardian minecraft:elder_guardian
             minecraft:bat),
        do: assert(type in types)
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  defp owns(observed), do: for(m <- minds(observed), is_tuple(m), do: elem(m, 8))

  # `count` water columns near each other: the nearest to the first of many.
  defp pool(blocks, count, seed) do
    [{x0, _, z0} | _] = spots = water(blocks, 60, :rand.seed_s(:exsss, seed))

    spots
    |> Enum.sort_by(fn {x, _, z} -> (x - x0) * (x - x0) + (z - z0) * (z - z0) end)
    |> Enum.take(count)
  end

  defp soaked do
    water = Valimc.Protocol.Data.block("water")
    [water: 1.0, eye_water: true, eye: {true, water}]
  end

  defp swimmer(n, type, {x, y, z}, opts),
    do: mob(n, type, {x, y - 1, z}, [motion: soaked()] ++ opts)

  ## Fish

  test "cod and salmon school behind leaders, flee players and panic", ctx do
    spots = pool(ctx.blocks, 12, 301)
    {[here], rest} = Enum.split(spots, 1)
    {px, py, pz} = here

    entries =
      for {{spot, n}, k} <- Enum.with_index(Enum.with_index(rest, 1)) do
        type = if rem(k, 3) == 0, do: "minecraft:salmon", else: "minecraft:cod"
        swimmer(n, type, spot, finalize: :natural)
      end

    swimming = %{player(0, here) | position: {px + 0.5, py - 1.0, pz + 0.5}}

    scene =
      scene([swimming],
        ticks: 320,
        acts: [{30, 2, :hurt}, {31, 5, :hurt}],
        post: true,
        level: 301
      )

    observed = compare(ctx, scene, entries)
    assert running?(observed, "Valimc.AI.Mobs.Fish.FollowLeader")
    assert running?(observed, "Valimc.AI.Goals.Panic")
    assert Enum.any?(owns(observed), &match?(%{leader: <<_::128>>}, &1))
    assert Enum.any?(owns(observed), &match?(%{school: n} when n > 1, &1))
  end

  test "fish out of water flop, and tropical fish spawn as variants and school", ctx do
    spots = pool(ctx.blocks, 10, 302)
    land = land(ctx.blocks, 4, :rand.seed_s(:exsss, 303))

    tropical =
      for {spot, n} <- Enum.with_index(spots, 1),
          do: swimmer(n, "minecraft:tropical_fish", spot, finalize: :natural)

    stranded =
      for {{spot, type}, n} <-
            Enum.with_index(
              Enum.zip(land, Stream.cycle(~w(minecraft:cod minecraft:salmon
              minecraft:pufferfish minecraft:tropical_fish))),
              20
            ),
          do: mob(n, type, spot, motion: [vertical_collision: true])

    for level <- [304, 305] do
      scene = scene([], ticks: 260, post: true, level: level)
      observed = compare(ctx, scene, tropical ++ stranded)
      records = List.flatten(for {r, _, _, _} <- observed, do: r)
      assert Enum.any?(records, &(&1.data[:variant] not in [nil, 0]))
      assert Enum.any?(effects(observed), &match?({:sound, _, _, _, _}, &1))
      assert running?(observed, "Valimc.AI.Mobs.Fish.FollowLeader")
    end
  end

  test "pufferfish puff at players and mobs near them, sting and deflate", ctx do
    spots = pool(ctx.blocks, 8, 306)
    {[here], rest} = Enum.split(spots, 1)
    {px, py, pz} = here

    entries =
      for {spot, n} <- Enum.with_index([here | rest], 1),
          do: swimmer(n, "minecraft:pufferfish", spot, no_ai: n == 4)

    # A sensed-only villager beside the first is stung too.
    statues = [swimmer(90, "minecraft:villager", here, no_ai: true)]

    near = %{player(0, here) | position: {px + 0.5, py - 1.0, pz + 0.5}}
    away = {{px + 40.5, py * 1.0, pz + 0.5}, {0.0, 0.0, 0.0}}
    there = {{px + 0.5, py - 1.0, pz + 0.5}, {0.0, 0.0, 0.0}}
    moves = for t <- 0..299, do: [if(t < 120, do: there, else: away)]

    scene = scene([near], ticks: 300, moves: moves, statues: statues, post: true, level: 307)
    observed = compare(ctx, scene, entries)
    records = List.flatten(for {r, _, _, _} <- observed, do: r)
    assert running?(observed, "Valimc.AI.Mobs.Pufferfish.Puff")
    assert Enum.any?(records, &(&1.data[:puff] == 2))
    assert Enum.any?(effects(observed), &match?({:hurt, {:player, _}, :mob_attack, _, _}, &1))
    assert Enum.any?(effects(observed), &match?({:hurt, {:mob, _}, :mob_attack, _, _}, &1))
  end

  ## Squid

  test "squid stroke about, flee what hurt them and squirt ink; glow squid darken", ctx do
    spots = pool(ctx.blocks, 9, 311)
    [ashore] = land(ctx.blocks, 1, :rand.seed_s(:exsss, 312))
    {[here], rest} = Enum.split(spots, 1)
    {px, py, pz} = here

    swimming =
      for {{spot, n}, k} <- Enum.with_index(Enum.with_index(rest, 1)) do
        type = if rem(k, 2) == 0, do: "minecraft:glow_squid", else: "minecraft:squid"
        swimmer(n, type, spot, age: if(k == 4, do: -24_000, else: 0), no_ai: k == 5)
      end

    entries = swimming ++ [mob(20, "minecraft:squid", ashore)]
    near = %{player(0, here) | position: {px + 0.5, py - 1.0, pz + 0.5}}
    acts = for i <- [0, 1, 3, 8], do: {12, i, :struck}

    scene = scene([near], ticks: 260, acts: acts, post: true, level: 313)
    observed = compare(ctx, scene, entries)
    records = List.flatten(for {r, _, _, _} <- observed, do: r)
    assert running?(observed, "Valimc.AI.Mobs.Squid.Flee")
    assert running?(observed, "Valimc.AI.Mobs.Squid.RandomMovement")
    assert Enum.any?(records, &((&1.data[:dark] || 0) > 0))
    assert Enum.any?(effects(observed), &match?({:event, 19}, &1))
  end

  ## Guardians

  test "guardians beam squid and players, pay back hits with thorns; elders curse", ctx do
    spots = pool(ctx.blocks, 12, 321)
    {[here, far], rest} = Enum.split(spots, 2)
    {px, py, pz} = here
    [ashore] = land(ctx.blocks, 1, :rand.seed_s(:exsss, 322))

    guardians =
      for {spot, n} <- Enum.with_index(Enum.take(rest, 6), 1),
          do: swimmer(n, "minecraft:guardian", spot, finalize: :natural)

    # An elder whose curse falls inside the scene (its tick plus its id).
    elders = [swimmer(1150, "minecraft:elder_guardian", far, finalize: :natural)]

    squid =
      for {spot, n} <- Enum.with_index(Enum.drop(rest, 6), 30),
          do: swimmer(n, "minecraft:squid", spot, [])

    stranded = [mob(40, "minecraft:guardian", ashore)]
    near = %{player(0, here) | position: {px + 0.5, py - 1.0, pz + 0.5}}
    acts = for i <- [0, 1, 6], do: {3, i, :struck}

    for difficulty <- [:normal, :hard] do
      scene =
        scene([near],
          ticks: 300,
          acts: acts,
          difficulty: difficulty,
          post: true,
          level: 323
        )

      observed = compare(ctx, scene, guardians ++ elders ++ squid ++ stranded)
      effects = effects(observed)
      assert running?(observed, "Valimc.AI.Mobs.Guardian.Attack")
      assert Enum.any?(effects, &match?({:event, 21}, &1))
      assert Enum.any?(effects, &match?({:hurt, _, :indirect_magic, _, _}, &1))
      assert Enum.any?(effects, &match?({:hurt, {:player, _}, :thorns, 2.0, []}, &1))
      assert Enum.any?(effects, &match?({:elder_curse, _}, &1))
    end
  end

  ## Bats

  # Bats over open ground: some hang under the ground's top block (a
  # conductor above them), others fly above it; one resting in the open air
  # wakes at once, one near a player is struck awake.
  test "bats roost under conductors, wake and fly to their spots", ctx do
    spots = land(ctx.blocks, 10, :rand.seed_s(:exsss, 331))
    {[here], rest} = Enum.split(spots, 1)

    bats =
      for {{x, y, z}, n} <- Enum.with_index(rest, 1) do
        if rem(n, 3) != 0,
          do: mob(n, "minecraft:bat", {x, y - 2, z}, data: [resting: true]),
          else: mob(n, "minecraft:bat", {x, y + 2, z}, data: [resting: false])
      end

    {hx, hy, hz} = here
    near = mob(20, "minecraft:bat", {hx, hy - 2, hz}, data: [resting: true])
    open = mob(21, "minecraft:bat", {hx + 1, hy + 3, hz}, data: [resting: true])

    for level <- [332, 333] do
      scene =
        scene([player(0, here)],
          ticks: 300,
          acts: [{40, 9, :struck}],
          post: true,
          level: level
        )

      observed = compare(ctx, scene, bats ++ [near, open])
      records = List.flatten(for {r, _, _, _} <- observed, do: r)
      effects = effects(observed)
      assert Enum.any?(effects, &match?({:level_event, _, 1025, 0}, &1))
      assert Enum.any?(records, &(&1.data.resting == false))
      assert Enum.any?(owns(observed), &match?({_, _, _}, &1))
    end
  end
end
