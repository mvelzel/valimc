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

  import Valimc.NativeMobScene

  alias Valimc.AI
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  setup_all do
    setup()
  end

  test "the farm animals are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <-
          ~w(minecraft:chicken minecraft:cow minecraft:mooshroom minecraft:pig minecraft:rabbit minecraft:sheep),
        do: assert(type in types)
  end

  @types ~w(minecraft:cow minecraft:pig minecraft:sheep minecraft:chicken minecraft:mooshroom minecraft:rabbit)

  test "farm animals wander, graze, follow, look and tempt", ctx do
    spots = land(ctx.blocks, 16, :rand.seed_s(:exsss, 91))
    wheat = ItemTypes.id("minecraft:wheat")
    {[here, there], rest} = Enum.split(spots, 2)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@types)), 1) do
        mob(n, type, spot,
          age: if(rem(n, 4) == 0, do: -24_000, else: 0),
          no_ai: n == 5
        )
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
        mob(1 + 2 * k + side, type, {x + side, y, z + 2 * k},
          finalize: :natural,
          data: if(type == "minecraft:sheep", do: [color: 4 + side], else: [])
        )
      end

    baby = mob(30, "minecraft:cow", {x + 1, y, z + 1}, age: -1200)
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
    entries = for {spot, n} <- Enum.with_index(rest, 1), do: mob(n, "minecraft:rabbit", spot)
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
        mob(n, type, spot, age: if(rem(n, 2) == 0, do: -24_000, else: 0))
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
      mob(1, "minecraft:cow", {ax + 2, ay, az}, leash: {:player, holder.uuid}),
      mob(2, "minecraft:pig", b, leash: {:knot, knot}),
      mob(3, "minecraft:sheep", {ax - 2, ay, az}, leash: {:player, holder.uuid})
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
