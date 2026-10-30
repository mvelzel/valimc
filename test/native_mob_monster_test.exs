defmodule Valimc.NativeMobMonsterTest do
  @moduledoc """
  The native endermites, silverfish, phantoms and shulkers (VMC-081d,
  `valimc_core::mobs::monsters`) against `Valimc.AI.Mobs`: whole sections
  of them thinking tick by tick over generated terrain
  (`Valimc.NativeMobScene`), every record, mind and effect and the level
  random equal every tick.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.Native
  alias Valimc.Protocol.Data

  setup_all do
    ctx = setup()
    # The region's owner edits it: the silverfish's burrows.
    silverfish = land(ctx.blocks, 10, :rand.seed_s(:exsss, 311))
    burrows(ctx, tl(silverfish))
    %{ctx | view: view(ctx.blocks, 2)} |> Map.put(:silverfish, silverfish)
  end

  test "these families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <- ~w(minecraft:endermite minecraft:silverfish),
        do: assert(type in types)
  end

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  ## Endermites

  test "endermites hunt, alert their kind and live out their time", ctx do
    spots = land(ctx.blocks, 10, :rand.seed_s(:exsss, 301))
    {[here], rest} = Enum.split(spots, 1)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        data = if n <= 3, do: [life: 2300 + 30 * n], else: []
        mob(n, "minecraft:endermite", spot, data: data, no_ai: n == 2)
      end

    scene =
      scene([player(0, here)],
        ticks: 200,
        bright: false,
        acts: [{4, 5, :hurt}],
        post: true,
        level: 71
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:discard}, &1))
    assert Enum.any?(effects, &match?({:alert, _, _}, &1))
    assert Enum.any?(effects, &match?({:attack, _}, &1))
  end

  ## Silverfish

  # Stone under each spot and infested stone around and below it (solid
  # for solid: the paths and light stay as they were).
  defp burrows(ctx, spots) do
    stone = Data.block("stone")
    infested = Data.block("infested_stone")

    changes =
      for {x, y, z} <- spots,
          {dx, dy, dz, block} <-
            [{0, -1, 0, stone}] ++
              for(dx <- -3..3, dz <- -3..3, rem(dx + dz, 3) == 0, do: {dx, -3, dz, infested}),
          into: %{},
          do: {{x + dx, y + dy, z + dz}, block}

    :ok = Valimc.World.Blocks.put(ctx.blocks, changes)
  end

  test "silverfish wake their friends, merge into stone and prefer it", ctx do
    {[here], rest} = Enum.split(ctx.silverfish, 1)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1),
          do: mob(n, "minecraft:silverfish", spot, finalize: if(n < 4, do: :natural))

    acts = [{3, 0, :magic}, {5, 1, :poked}, {7, 2, :shot}, {9, 3, :hurt}, {40, 4, :magic}]

    for {griefing, level} <- [{true, 81}, {false, 82}] do
      scene =
        scene([player(0, here, mode: :creative)],
          ticks: 160,
          bright: false,
          griefing: griefing,
          acts: acts,
          post: true,
          level: level
        )

      observed = compare(ctx, scene, entries)
      effects = effects(observed)
      assert Enum.any?(effects, &match?({:wake_infested, _, _, ^griefing}, &1))
      assert running?(observed, "Valimc.AI.Mobs.Silverfish.WakeFriends")

      if griefing do
        assert Enum.any?(effects, &match?({:infest, _, _}, &1))
        assert Enum.any?(effects, &match?({:discard}, &1))
      end
    end
  end
end
