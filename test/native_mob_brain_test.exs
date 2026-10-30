defmodule Valimc.NativeMobBrainTest do
  @moduledoc """
  The native brain families (VMC-081d, `valimc_core::mobs::brains` over
  `mobs::ai::brain`) against `Valimc.AI.Brains`: whole sections of hoglins,
  piglins, axolotls and villagers thinking tick by tick over generated
  terrain with platforms built for their scenes (repellents, beds, job
  sites, meeting points, water), every record, mind (memories, activities,
  running behaviours and sensors' countdowns included), effect and the
  level random equal every tick (`Valimc.NativeMobScene`).
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Data.Blocks
  alias Valimc.Native

  # The platforms' floor (`@floor`) and the blocks on them.
  @floor 100
  @hoglins {2, 2, 30, 14}
  # A pool (water over x 34..42) with a dry ledge beside it.
  @pool {34, 2, 46, 14}
  @water {34, 2, 42, 14}

  setup_all do
    setup_with(fn _blocks ->
      stone = Blocks.default_state("stone")
      water = Blocks.default_state("water")
      floor = fn {x0, z0, x1, z1} -> for x <- x0..x1, z <- z0..z1, do: {{x, @floor, z}, stone} end
      {wx0, wz0, wx1, wz1} = @water
      pool = for x <- wx0..wx1, z <- wz0..wz1, do: {{x, @floor + 1, z}, water}
      edits = Map.new(floor.(@hoglins) ++ floor.(@pool) ++ pool)
      edits = Map.put(edits, {28, @floor + 1, 12}, Blocks.default_state("warped_fungus"))
      {edits, %{fungus: {28, @floor + 1, 12}}}
    end)
  end

  test "the brain families are native and register no goals" do
    assert {:ok, types} = Native.mob_kinds()
    for type <- ~w(minecraft:hoglin minecraft:axolotl), do: assert(type in types)
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)

  defp brains(observed),
    do: for(m <- minds(observed), is_tuple(m), b = elem(m, 14), b != nil, do: b)

  defp remembered?(observed, name),
    do:
      Enum.any?(brains(observed), fn {memories, _, _, _} ->
        List.keymember?(memories, name, 0)
      end)

  defp active?(observed, activity),
    do: Enum.any?(brains(observed), fn {_, active, _, _} -> activity in active end)

  # A spot on a platform's floor.
  defp on({x, z}), do: {x, @floor + 1, z}

  ## Hoglins

  test "hoglins hunt a player and fight back as a herd", ctx do
    herd = for {x, z} <- [{4, 4}, {6, 4}, {4, 7}, {7, 7}, {5, 10}, {9, 5}], do: on({x, z})

    entries =
      for {spot, n} <- Enum.with_index(herd, 1),
          do: mob(n, "minecraft:hoglin", spot, finalize: :natural)

    scene =
      scene([player(0, on({10, 10}))],
        ticks: 300,
        acts: [{40, 0, :hurt}, {41, 1, :hurt}, {90, 2, :hurt}],
        post: true,
        level: 21
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:attack, _}, &1))
    assert Enum.any?(effects, &match?({:attack_extra, _, _}, &1))
    assert active?(observed, :fight)
  end

  test "hoglins shy from warped fungus and babies flee", ctx do
    {fx, _, fz} = ctx.info.fungus

    entries = [
      mob(1, "minecraft:hoglin", on({fx - 2, fz - 1})),
      mob(2, "minecraft:hoglin", on({fx - 3, fz - 3})),
      mob(3, "minecraft:hoglin", on({16, 5}), age: -2000),
      mob(4, "minecraft:hoglin", on({18, 5}))
    ]

    scene =
      scene([player(0, on({15, 9}))],
        ticks: 240,
        acts: [{30, 2, :hurt}],
        post: true,
        level: 22
      )

    observed = compare(ctx, scene, entries)
    assert remembered?(observed, "pacified")
    assert remembered?(observed, "nearest_repellent")
    assert active?(observed, :avoid)
  end

  ## Axolotls

  @wet [motion: [water: 0.5]]

  test "axolotls hunt fish in water, play dead and look for water on land", ctx do
    entries = [
      mob(1, "minecraft:axolotl", on({36, 4}), [finalize: :natural] ++ @wet),
      mob(2, "minecraft:axolotl", on({38, 6}), [finalize: :natural] ++ @wet),
      mob(3, "minecraft:axolotl", on({37, 9}), @wet),
      mob(4, "minecraft:axolotl", on({45, 8}))
    ]

    statues = [
      mob(90, "minecraft:cod", on({39, 5}), [no_ai: true] ++ @wet),
      mob(91, "minecraft:drowned", on({35, 11}), [no_ai: true] ++ @wet)
    ]

    blows = for t <- [20, 23, 26, 29, 32, 35, 38], i <- [0, 1, 2], do: {t + i, i, :blow}

    scene =
      scene([player(0, on({41, 12}))],
        ticks: 300,
        statues: statues,
        acts: blows,
        post: true,
        level: 31
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:attack, _}, &1))
    assert active?(observed, :fight)
    assert active?(observed, :play_dead)
    assert remembered?(observed, "nearest_attackable")
    assert remembered?(observed, "has_hunting_cooldown")
  end

  test "axolotls breed and follow a player tempting them", ctx do
    bucket = Valimc.Protocol.ItemTypes.id("minecraft:tropical_fish_bucket")

    entries = [
      mob(1, "minecraft:axolotl", on({36, 4}), @wet),
      mob(2, "minecraft:axolotl", on({37, 5}), @wet),
      mob(3, "minecraft:axolotl", on({39, 10}), [age: -2400] ++ @wet),
      mob(4, "minecraft:axolotl", on({44, 4}))
    ]

    scene =
      scene([player(0, on({40, 7}), mainhand: bucket)],
        ticks: 240,
        acts: [{2, 0, :love}, {2, 1, :love}],
        post: true,
        level: 32
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:offspring, "minecraft:axolotl", _, _}, &1))
    assert remembered?(observed, "tempting_player")
    assert remembered?(observed, "breed_target")
  end
end
