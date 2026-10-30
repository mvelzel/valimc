defmodule Valimc.NativeMobWaterTest do
  @moduledoc """
  The native water families (VMC-081d, `valimc_core::mobs::water`) against
  `Valimc.AI.Mobs`: their registered goals against vanilla's, and whole
  sections of them thinking tick by tick over generated terrain
  (`Valimc.NativeMobScene`), every record, mind and effect and the level
  random equal every tick: fish schooling, fleeing, panicking, flopping and
  puffing.
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
          ~w(minecraft:cod minecraft:salmon minecraft:pufferfish minecraft:tropical_fish),
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
    do: mob(n, type, {x, y - 2, z}, [motion: soaked()] ++ opts)

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

    swimming = %{player(0, here) | position: {px + 0.5, py - 1.5, pz + 0.5}}

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

    near = %{player(0, here) | position: {px + 0.5, py - 2.0, pz + 0.5}}
    away = {{px + 40.5, py * 1.0, pz + 0.5}, {0.0, 0.0, 0.0}}
    there = {{px + 0.5, py - 2.0, pz + 0.5}, {0.0, 0.0, 0.0}}
    moves = for t <- 0..299, do: [if(t < 120, do: there, else: away)]

    scene = scene([near], ticks: 300, moves: moves, statues: statues, post: true, level: 307)
    observed = compare(ctx, scene, entries)
    records = List.flatten(for {r, _, _, _} <- observed, do: r)
    assert running?(observed, "Valimc.AI.Mobs.Pufferfish.Puff")
    assert Enum.any?(records, &(&1.data[:puff] == 2))
    assert Enum.any?(effects(observed), &match?({:hurt, {:player, _}, :mob_attack, _, _}, &1))
    assert Enum.any?(effects(observed), &match?({:hurt, {:mob, _}, :mob_attack, _, _}, &1))
  end
end
