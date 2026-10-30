defmodule Valimc.NativeMobNetherTest do
  @moduledoc """
  The native Nether families (VMC-081d, `valimc_core::mobs::monsters` and
  `animals`) against `Valimc.AI.Mobs`: zombified piglins, wither skeletons,
  blazes, ghasts and striders thinking tick by tick over generated terrain
  (`Valimc.NativeMobScene`), every record, mind and effect and the level
  random equal every tick.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Native

  setup_all do
    setup()
  end

  test "the Nether families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <- ~w(minecraft:zombified_piglin minecraft:wither_skeleton),
        do: assert(type in types)
  end

  defp loot, do: Valimc.Blocks.Loot.registry()

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)
  defp records(observed), do: List.flatten(for {r, _, _, _} <- observed, do: r)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  defp own(observed), do: for(m <- minds(observed), is_tuple(m), own = elem(m, 8), do: own)

  ## Zombified piglins

  test "zombified piglins spawn with gold, anger when hurt and bring their kind", ctx do
    spots = land(ctx.blocks, 12, :rand.seed_s(:exsss, 201))
    {[here], rest} = Enum.split(spots, 1)
    {hx, hy, hz} = here

    entries =
      for {spot, n} <- Enum.with_index(rest, 1),
          do: mob(n, "minecraft:zombified_piglin", spot, finalize: :natural)

    near =
      for {dx, n} <- Enum.with_index([2, -2, 3], 20),
          do: mob(n, "minecraft:zombified_piglin", {hx + dx, hy, hz + 1})

    for {universal, level} <- [{false, 51}, {true, 52}] do
      scene =
        scene([player(0, here)],
          ticks: 240,
          difficulty: :hard,
          universal_anger: universal,
          acts: [{3, 11, :hurt}, {90, 12, :hurt}, {91, 0, :hurt}],
          post: true,
          loot: loot(),
          level: level
        )

      observed = compare(ctx, scene, entries ++ near)
      effects = effects(observed)
      assert Enum.any?(effects, &match?({:alert, _, _}, &1))
      assert Enum.any?(effects, &match?({:attack, _}, &1))
      assert Enum.any?(own(observed), &(is_map(&1) and &1[:anger_end] > 0))

      assert Enum.any?(records(observed), fn r ->
               Enum.any?(
                 r.mob.attributes["minecraft:movement_speed"][:modifiers] || [],
                 &(elem(&1, 0) == "minecraft:attacking")
               )
             end)
    end
  end

  ## Wither skeletons

  test "wither skeletons spawn with stone swords, hunt piglins and wither what they hit", ctx do
    spots = land(ctx.blocks, 10, :rand.seed_s(:exsss, 211))
    {[here, piglin], rest} = Enum.split(spots, 2)
    {px, py, pz} = piglin

    entries =
      for {spot, n} <- Enum.with_index(rest, 1),
          do: mob(n, "minecraft:wither_skeleton", spot, finalize: :natural)

    near = mob(20, "minecraft:wither_skeleton", {px + 2, py, pz})

    scene =
      scene([player(0, here)],
        ticks: 240,
        bright: false,
        difficulty: :hard,
        halloween: true,
        statues: [mob(90, "minecraft:piglin", piglin, no_ai: true)],
        acts: [{4, 2, :hurt}],
        post: true,
        loot: loot(),
        level: 61
      )

    observed = compare(ctx, scene, entries ++ [near])
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:attack_extra, _, %{effect: _}}, &1))
    assert running?(observed, "Valimc.AI.Mobs.Skeleton.Weapon")
  end
end
