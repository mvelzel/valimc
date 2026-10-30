defmodule Valimc.NativeMobNeutralTest do
  @moduledoc """
  The native striders, iron golems and wandering traders (VMC-081d,
  `valimc_core::mobs::animals` and `village`) against `Valimc.AI.Mobs` and
  `Valimc.Entity.Animals`: whole sections of them thinking tick by tick
  over generated terrain (`Valimc.NativeMobScene`), every record, mind and
  effect and the level random equal every tick.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Native
  alias Valimc.Protocol.{Data, ItemTypes}

  setup_all do
    ctx = setup()
    # The region's owner edits it: pools of lava by the striders.
    striders = land(ctx.blocks, 9, :rand.seed_s(:exsss, 401))
    lava = Data.block("lava")

    pools =
      for {x, y, z} <- Enum.take(tl(striders), 3),
          dx <- 2..3,
          dz <- 0..1,
          into: %{},
          do: {{x + dx, y - 1, z + dz}, lava}

    :ok = Valimc.World.Blocks.put(ctx.blocks, pools)
    %{ctx | view: view(ctx.blocks, 2)} |> Map.put(:striders, striders)
  end

  test "these families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <- ~w(minecraft:strider minecraft:iron_golem minecraft:wandering_trader),
        do: assert(type in types)
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)
  defp records(observed), do: List.flatten(for {r, _, _, _} <- observed, do: r)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  ## Striders

  test "striders shiver out of lava, head for it, are tempted, panic and breed", ctx do
    {[here], rest} = Enum.split(ctx.striders, 1)
    fungus = ItemTypes.id("minecraft:warped_fungus")

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        mob(n, "minecraft:strider", spot,
          age: if(n == 6, do: -24_000, else: 0),
          finalize: if(n > 4, do: :natural),
          motion: if(n == 4, do: [lava: 0.4], else: []),
          no_ai: n == 8
        )
      end

    acts = [{2, 1, :love}, {2, 2, :love}, {30, 6, :hurt}, {31, 3, :hurt}]

    scene =
      scene([player(0, here, mainhand: fungus)],
        ticks: 300,
        acts: acts,
        post: true,
        level: 101
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(records(observed), &(&1.data[:suffocating] == true))
    assert Enum.any?(effects, &match?({:offspring, "minecraft:strider", _, _}, &1))
    assert running?(observed, "Valimc.AI.Goals.Tempt")
    assert running?(observed, "Valimc.AI.Goals.Panic")
    assert running?(observed, "Valimc.Entity.Animals.Strider.GoToLava")
  end

  ## Iron golems

  test "iron golems guard: hunt monsters, keep their anger, throw what they hit", ctx do
    spots = land(ctx.blocks, 16, :rand.seed_s(:exsss, 411))
    {[here, villager], rest} = Enum.split(spots, 2)
    {golems, monsters} = Enum.split(rest, 8)

    entries =
      for {spot, n} <- Enum.with_index(golems, 1),
          do: mob(n, "minecraft:iron_golem", spot, data: [player_created: n == 2])

    # Zombies by some golems (one inside a golem's box), a creeper.
    {gx, gy, gz} = hd(golems)

    enemies =
      [mob(20, "minecraft:zombie", {gx, gy, gz}), mob(21, "minecraft:creeper", hd(monsters))] ++
        for {spot, n} <- Enum.with_index(tl(monsters), 22), do: mob(n, "minecraft:zombie", spot)

    {vx, vy, vz} = villager
    village = {Integer.floor_div(vx, 16), Integer.floor_div(vy, 16), Integer.floor_div(vz, 16)}

    observed =
      for {villages, level} <- [{nil, 131}, {[village], 132}] do
        scene =
          scene([player(0, here)],
            ticks: 300,
            bright: true,
            statues: [mob(90, "minecraft:villager", villager, no_ai: true)],
            acts: [{3, 2, :hurt}, {4, 1, :hurt}],
            villages: villages,
            post: true,
            level: level
          )

        compare(ctx, scene, entries ++ enemies)
      end

    ticks = Enum.concat(observed)
    effects = effects(ticks)
    assert Enum.any?(effects, &match?({:attack_extra, _, %{lift: _}}, &1))
    assert Enum.any?(effects, &match?({:event, 4}, &1))
    assert running?(ticks, "Valimc.AI.Goals.MeleeAttack")
    assert running?(ticks, "Valimc.AI.Goals.RandomStroll")

    assert Enum.any?(
             minds(ticks),
             &(is_tuple(&1) and is_map(elem(&1, 8)) and elem(&1, 8)[:anger_end] > 0)
           )
  end

  ## Wandering traders

  test "wandering traders drink by dark and by day, flee, panic, wander and go", ctx do
    spots = land(ctx.blocks, 10, :rand.seed_s(:exsss, 421))
    {[here, zombie], rest} = Enum.split(spots, 2)
    {wx, wy, wz} = hd(rest)

    traders =
      for {spot, n} <- Enum.with_index(rest, 1) do
        data =
          cond do
            n == 1 -> [despawn_delay: 120]
            n == 2 -> [wander_target: {wx + 14, wy, wz + 3}]
            n == 3 -> [invisible: true]
            true -> [despawn_delay: 4000]
          end

        mob(n, "minecraft:wandering_trader", spot, data: data)
      end

    {zx, zy, zz} = zombie
    hunters = [mob(20, "minecraft:zombie", {zx, zy, zz}, no_ai: true)]

    observed =
      for {bright, level} <- [{false, 141}, {true, 142}] do
        scene =
          scene([player(0, here)],
            ticks: 200,
            bright: bright,
            acts: [{6, 4, :hurt}],
            post: true,
            level: level
          )

        compare(ctx, scene, traders ++ hunters)
      end

    ticks = Enum.concat(observed)
    effects = effects(ticks)
    records = records(ticks)
    assert Enum.any?(effects, &match?({:discard}, &1))
    assert Enum.any?(records, &(&1.data[:invisible] == true))
    assert Enum.any?(records, &(&1.mob.equipment[:mainhand] != nil))
    assert running?(ticks, "Valimc.AI.Goals.UseItem")
    assert running?(ticks, "Valimc.AI.Goals.Panic")
    assert running?(ticks, "Valimc.AI.Mobs.WanderingTrader.WanderToPosition")
  end
end
