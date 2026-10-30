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
    for type <- ~w(minecraft:strider), do: assert(type in types)
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
end
