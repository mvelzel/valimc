defmodule Valimc.NativeMobDolphinTest do
  @moduledoc """
  The native dolphins (VMC-081d, `valimc_core::mobs::water::dolphin`)
  against `Valimc.AI.Mobs.Dolphin`: their registered goals against
  vanilla's, whole sections of them thinking tick by tick over generated
  terrain (`Valimc.NativeMobScene`), every record, mind and effect and the
  level random equal every tick (swimming, leaping, breathing, swimming
  with players, treasure, playing with items, drying out, biting back), and
  a player feeding one fish on both sides.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Entity.Body
  alias Valimc.Native
  alias Valimc.Protocol.ItemStack

  @dolphin "minecraft:dolphin"

  setup_all do
    setup()
  end

  test "dolphins are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()
    assert @dolphin in types
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)
  defp records(observed), do: List.flatten(for {r, _, _, _} <- observed, do: r)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

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

  # At the top of the water (`depth` 1) or deeper.
  defp swimmer(n, {x, y, z}, depth, opts),
    do: mob(n, @dolphin, {x, y - depth, z}, [motion: soaked()] ++ opts)

  test "dolphins swim, leap, breathe and swim along with swimming players", ctx do
    spots = pool(ctx.blocks, 12, 401)
    {[here, there], rest} = Enum.split(spots, 2)
    {px, py, pz} = here

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        opts = [finalize: if(rem(n, 2) == 0, do: :natural), no_ai: n == 7]
        opts = if rem(n, 3) == 0, do: [{:air, 120} | opts], else: opts
        opts = if n == 5, do: [{:age, -24_000} | opts], else: opts
        swimmer(n, spot, if(rem(n, 4) == 0, do: 3, else: 1), opts)
      end

    swimming = %{
      player(0, here, swimming: true)
      | position: {px + 0.5, py - 1.0, pz + 0.5}
    }

    players = [swimming, player(1, there)]

    for level <- [401, 402] do
      scene = scene(players, ticks: 300, post: true, level: level)
      observed = compare(ctx, scene, entries)
      assert running?(observed, "Valimc.AI.Mobs.Dolphin.SwimWithPlayer")
      assert running?(observed, "Valimc.AI.Goals.RandomStroll")
      assert running?(observed, "Valimc.AI.Goals.BreathAir")
      assert Enum.any?(effects(observed), &match?({:effect, {:player, _}, _}, &1))
    end
  end

  # Water columns with open water seven blocks east of them and air above.
  defp open_water(blocks, count, seed) do
    world = %Valimc.AI.World{read: &read(blocks, &1)}

    clear = fn {x, y, z} ->
      Enum.all?([0, 1, 4, 5, 6, 7], fn i ->
        Valimc.AI.World.fluid(world, {x + i, y - 1, z}) == :water and
          Valimc.AI.World.air?(world, {x + i, y, z}) and
          Valimc.AI.World.air?(world, {x + i, y + 1, z})
      end)
    end

    blocks |> water(200, :rand.seed_s(:exsss, seed)) |> Enum.filter(clear) |> Enum.take(count)
  end

  test "dolphins leap out of open water", ctx do
    spots = open_water(ctx.blocks, 12, 403)

    # Facing east, `getMotionDirection` east.
    entries = for {spot, n} <- Enum.with_index(spots, 1), do: swimmer(n, spot, 1, yaw: 270.0)

    observed =
      for level <- [403, 404] do
        compare(ctx, scene([], ticks: 240, post: true, level: level), entries)
      end

    assert Enum.any?(observed, &running?(&1, "Valimc.AI.Mobs.Dolphin.Jump"))
  end

  test "a dolphin that got fish seeks treasure, at once or deferred", ctx do
    spots = pool(ctx.blocks, 6, 405)
    {[{tx, ty, tz}], rest} = Enum.split(spots, 1)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1),
          do: swimmer(n, spot, 2, data: [got_fish: true], air: if(n == 3, do: 90, else: 4800))

    for {treasure, level} <- [{{tx + 30, ty - 12, tz - 20}, 405}, {nil, 406}] do
      scene = scene([], ticks: 240, post: true, level: level, treasure: treasure)
      observed = compare(ctx, scene, entries)
      assert running?(observed, "Valimc.AI.Mobs.Dolphin.Treasure")

      if treasure do
        assert Enum.any?(records(observed), &(&1.data.treasure == treasure))
        assert Enum.any?(effects(observed), &(&1 == {:event, 38}))
      end
    end
  end

  test "dolphins pick items up, carry them and toss them", ctx do
    spots = pool(ctx.blocks, 8, 407)
    cod = ItemStack.new("minecraft:cod")

    entries =
      for {spot, n} <- Enum.with_index(spots, 1) do
        opts = [pick_up: true]
        opts = if n == 4, do: [{:equipment, [mainhand: cod]} | opts], else: opts
        swimmer(n, spot, 1, opts)
      end

    items =
      for {{x, y, z}, k} <- Enum.with_index(Enum.take(spots, 5), 1) do
        name = if rem(k, 2) == 0, do: "minecraft:stick", else: "minecraft:kelp"
        item(k, name, {x + 0.6, y - 1.0, z + 0.5}, count: k, in_water: k != 5)
      end

    {fx, fy, fz} = List.last(spots)
    far = item(9, "minecraft:stick", {fx + 6.5, fy - 1.0, fz + 0.5})

    for level <- [407, 408] do
      scene = scene([], ticks: 240, post: true, level: level, items: items ++ [far])
      observed = compare(ctx, scene, entries)
      effects = effects(observed)
      assert Enum.any?(effects, &match?({:pickup, _, _}, &1))
      assert Enum.any?(effects, &match?({:throw, _, _, _, 40}, &1))
      assert running?(observed, "Valimc.AI.Mobs.Dolphin.MoveToItem")
      assert running?(observed, "Valimc.AI.Mobs.Dolphin.PlayWithItems")
    end
  end

  test "dolphins on land dry out and flop, and bite back when hurt", ctx do
    land = land(ctx.blocks, 4, :rand.seed_s(:exsss, 409))
    spots = pool(ctx.blocks, 6, 410)
    {[here], rest} = Enum.split(spots, 1)
    {px, py, pz} = here

    stranded =
      for {spot, n} <- Enum.with_index(land, 1),
          do:
            mob(n, @dolphin, spot, data: [moistness: 20 * n], motion: [vertical_collision: true])

    swimming =
      for {spot, n} <- Enum.with_index(rest, 10),
          do: swimmer(n, spot, 1, age: if(n == 12, do: -24_000, else: 0))

    # The first on land beside the player that hurts it, another in the
    # water by a second.
    swimmer = %{player(1, here) | position: {px + 0.5, py - 1.0, pz + 0.5}}
    acts = [{5, 0, :hurt}, {5, 4, :hurt}, {7, 6, :hurt}]
    players = [player(0, hd(land)), swimmer]

    scene = scene(players, ticks: 200, post: true, acts: acts, level: 411)
    observed = compare(ctx, scene, stranded ++ swimming)
    effects = effects(observed)
    hurt = sound_id("minecraft:entity.dolphin.hurt")
    assert Enum.any?(effects, &match?({:sound, ^hurt, _, _, _}, &1))
    assert Enum.any?(effects, &match?({:attack, {:player, _}}, &1))
    assert running?(observed, "Valimc.AI.Goals.MeleeAttack")
    assert running?(observed, "Valimc.AI.Goals.TryFindLiquid")
  end

  ## Feeding

  defp interact(ctx, body, item) do
    body = put_in(body.mob.ai, Valimc.AI.mind(body.type, uuid(1), nil, body.data))
    record = entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})
    {:ok, restored} = Body.restore(record)
    player = uuid(2000)

    {native, native_record} =
      Native.mob_parity_interact(
        ctx.facts,
        record,
        item,
        {player, {2.5, 64.0, 0.5}, 2000},
        false,
        nil,
        []
      )

    request = %{item: item, infinite: false, player: player}

    case {native, Valimc.AI.Mobs.interact(restored, request)} do
      {:pass, :pass} ->
        :pass

      {{:done, hand, swing, events, others, [], nil, []}, {:ok, body, outcome}} ->
        assert {hand, swing, others} == {outcome.hand, outcome.swing, outcome.others}

        assert events ==
                 Enum.map(outcome.events, fn {kind, id, source, volume, pitch, _seed} ->
                   {kind, id, source, volume, pitch}
                 end)

        assert native_record ==
                 entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})

        :done
    end
  end

  test "a dolphin eats fish from a player's hand", ctx do
    {:ok, dolphin} = Body.new(@dolphin)
    baby = %{dolphin | data: %{dolphin.data | age: -2000}}
    assert interact(ctx, dolphin, ItemStack.new("minecraft:cod")) == :done
    assert interact(ctx, baby, ItemStack.new("minecraft:salmon")) == :done
    assert interact(ctx, dolphin, ItemStack.new("minecraft:stone")) == :pass
  end
end
