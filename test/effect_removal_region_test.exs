defmodule Valimc.EffectRemovalRegionTest do
  @moduledoc """
  A killed mob's effects as it is removed (VMC-037p): Weaving's cobwebs on
  the floor around it and Oozing's two slimes, after its death's 20 ticks.
  """
  use ExUnit.Case, async: false
  alias Valimc.Data.{Blocks, EffectTypes}
  alias Valimc.Entity.{Body, Mob, Store}
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {71_000 + rem(nonce, 333) * 3, 2911}
    base = Path.join(System.tmp_dir!(), "valimc-removal-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :items, %{records: []})
    {rx, rz} = key
    {x0, z0} = {rx * 128 + 64, rz * 128 + 64}
    stone = Blocks.default_state("stone")

    floor =
      for x <- (x0 - 16)..(x0 + 16), z <- (z0 - 16)..(z0 + 16), into: %{}, do: {{x, 63, z}, stone}

    Valimc.TestDisk.write(base, key, :blocks, floor)
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for k <- TestScope.neighborhood(key), {pid, _} <- Valimc.TestWorld.registered(k) do
        try do
          TestScope.kill(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, at: {x0, z0}}
  end

  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  test "a killed zombie under Weaving and Oozing leaves cobwebs and two slimes", ctx do
    {x0, z0} = ctx.at
    rung = {600, 0, false, true, true}
    {:ok, body} = Body.new("minecraft:zombie")

    mob =
      body.mob
      |> Mob.add_effect(EffectTypes.id("weaving"), rung)
      |> Mob.add_effect(EffectTypes.id("oozing"), rung)

    uuid = <<41::128>>

    :ok =
      Region.drop_items(ctx.owner, [
        Store.body_record(%{body | mob: mob}, uuid, {x0 + 0.5, 64.0, z0 + 0.5})
      ])

    step(ctx, 2)
    assert {:ok, 1} = Region.kill_entities(ctx.owner, [uuid])
    step(ctx, 25)

    cells = for dx <- -1..1, dy <- 0..1, dz <- -1..1, do: {x0 + dx, 64 + dy, z0 + dz}
    {:ok, %{blocks: blocks}} = Region.observe_blocks(ctx.owner, cells)
    cobweb = Blocks.default_state("cobweb")
    # Only the floor's level stands on stone.
    assert Enum.count(blocks, fn {{_, y, _}, s} -> y == 64 and s == cobweb end) in 2..3
    assert Enum.count(blocks, fn {_, s} -> s == cobweb end) in 2..3

    store = Valimc.TestRegion.section(ctx.owner).entities.store
    slimes = for {_, %{body: %{type: "minecraft:slime"}} = e} <- store.entries, do: e
    assert length(slimes) == 2
    assert Enum.all?(slimes, &(&1.body.data.size == 2))
  end
end
