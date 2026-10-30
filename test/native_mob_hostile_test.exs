defmodule Valimc.NativeMobHostileTest do
  @moduledoc """
  The native hostile families (VMC-081d, `valimc_core::mobs::monsters`)
  against `Valimc.AI.Mobs`: their registered goals against vanilla's; whole
  sections of them thinking tick by tick over generated terrain as the farm
  animals do (`Valimc.NativeMobScene`), spawned through `finalizeSpawn`
  (armour, weapons and their enchanting, babies, jockeys, Halloween heads),
  with the sun and each family's part after the move, every record, mind
  and effect and the level random equal every tick; and what happens to
  them outside a tick (conversions, interactions, splits) on both sides.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.AI.Conversion
  alias Valimc.Entity.Body
  alias Valimc.Native

  setup_all do
    setup()
  end

  test "the hostile families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <- ~w(minecraft:zombie minecraft:husk minecraft:zombie_villager),
        do: assert(type in types)
  end

  defp loot, do: Valimc.Blocks.Loot.registry()

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  ## Zombies

  @zombies ~w(minecraft:zombie minecraft:husk minecraft:zombie_villager)

  test "zombies spawn armed, hunt players and villagers, and alert their kind", ctx do
    spots = land(ctx.blocks, 16, :rand.seed_s(:exsss, 101))
    {[here, villager, golem], rest} = Enum.split(spots, 3)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@zombies)), 1) do
        mob(n, type, spot, finalize: if(rem(n, 4) == 0, do: :spawner, else: :natural))
      end

    statues = [
      mob(90, "minecraft:villager", villager, no_ai: true),
      mob(91, "minecraft:iron_golem", golem, no_ai: true)
    ]

    acts = for i <- [0, 3], do: {3, i, :hurt}

    scene =
      scene([player(0, here)],
        ticks: 240,
        time: 18_000,
        day: 900_000,
        bright: false,
        difficulty: :hard,
        halloween: true,
        statues: statues,
        acts: acts,
        post: true,
        loot: loot(),
        level: 13
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:attack, _}, &1))
    assert Enum.any?(effects, &match?({:alert, _, _}, &1))
    assert running?(observed, "Valimc.AI.Goals.MeleeAttack")
  end

  test "zombies spawn as babies and jockeys, and go for golems", ctx do
    spots = land(ctx.blocks, 30, :rand.seed_s(:exsss, 102))
    {[golem, chicken], rest} = Enum.split(spots, 2)

    # Many spawns draw the rare outcomes: babies, jockeys, leaders, weapons.
    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@zombies)), 1),
          do: mob(n, type, spot, finalize: :natural)

    statues = [
      mob(90, "minecraft:iron_golem", golem, no_ai: true),
      mob(91, "minecraft:chicken", chicken, no_ai: true)
    ]

    observed =
      for level <- 1..6 do
        scene =
          scene([],
            ticks: 30,
            bright: false,
            difficulty: :hard,
            day: 2_000_000,
            statues: statues,
            post: true,
            loot: loot(),
            level: 100 + level
          )

        compare(ctx, scene, entries)
      end

    ticks = Enum.concat(observed)
    effects = effects(ticks)
    records = List.flatten(for {r, _, _, _} <- ticks, do: r)
    assert Enum.any?(effects, &match?({:spawn, "minecraft:chicken", _}, &1))
    assert Enum.any?(records, &(&1.data[:baby] == true))
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :mainhand))
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :chest))

    assert Enum.any?(records, fn r ->
             Enum.any?(r.mob.equipment, fn {_, s} -> s.components["minecraft:enchantments"] end)
           end)

    assert running?(ticks, "Valimc.AI.Goals.MeleeAttack")
  end

  test "zombies burn by day, set what they hit alight, and drown", ctx do
    spots = land(ctx.blocks, 6, :rand.seed_s(:exsss, 103))
    pools = water(ctx.blocks, 2, :rand.seed_s(:exsss, 104))
    {[here], rest} = Enum.split(spots, 1)
    {hx, hy, hz} = here

    water = Valimc.Protocol.Data.block("water")
    soaked = [motion: [water: 1.0, eye_water: true, eye: {true, water}]]

    burning =
      for {{x, y, z}, n} <- Enum.with_index([{hx + 1, hy, hz} | rest], 1) do
        type = if rem(n, 2) == 0, do: "minecraft:husk", else: "minecraft:zombie"
        mob(n, type, {x, y, z}, fire: if(n <= 2, do: 300, else: 0))
      end

    drowning =
      for {{{x, y, z}, type}, n} <-
            Enum.with_index(Enum.zip(pools, ["minecraft:zombie", "minecraft:husk"]), 20) do
        mob(n, type, {x, y - 1, z}, [data: [in_water: 598]] ++ soaked)
      end

    scene =
      scene([player(0, here)],
        ticks: 320,
        bright: true,
        monsters_burn: true,
        post: true,
        level: 17
      )

    observed = compare(ctx, scene, burning ++ drowning)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:convert, "minecraft:drowned"}, &1))
    assert Enum.any?(effects, &match?({:convert, "minecraft:zombie"}, &1))
    assert Enum.any?(effects, &match?({:attack_extra, _, _}, &1))
  end

  ## Conversions

  defp convert(ctx, body, to, special) do
    record = entry_record(1, %{entity: %{uuid: uuid(1), x: 3.5, y: 64.0, z: 2.5}, body: body})
    {:ok, restored} = Body.restore(record)
    new = uuid(77)
    native = Native.mob_parity_convert(ctx.facts, record, new, to, special)
    elixir = Conversion.convert(restored, new, to, special)

    assert native ==
             entry_record(1, %{entity: %{uuid: new, x: 3.5, y: 64.0, z: 2.5}, body: elixir})
  end

  test "conversions keep what vanilla keeps and roll a zombie's attributes", ctx do
    {:ok, zombie} = Body.new("minecraft:zombie")
    baby = %{zombie | data: %{zombie.data | baby: true}}
    baby = put_in(baby.mob.living.fire_ticks, 40)
    baby = put_in(baby.mob.equipment, %{head: Valimc.Protocol.ItemStack.new("iron_helmet")})
    {:ok, husk} = Body.new("minecraft:husk")

    for special <- [0.0, 0.5, 1.0] do
      convert(ctx, zombie, "minecraft:husk", special)
      convert(ctx, baby, "minecraft:zombie_villager", special)
      convert(ctx, husk, "minecraft:zombie", special)
    end
  end
end
