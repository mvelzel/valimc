defmodule Valimc.HostileRegionTest do
  @moduledoc """
  Hostiles in an owner: a zombie finishes its spawn on its first tick, and
  by day it burns under the open sky, not under a roof (VMC-043b1); flint
  and steel lights a creeper, which explodes (VMC-043b4).
  """
  # The clock and weather are global: clear noon for the whole test.
  use ExUnit.Case, async: false
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    alias Valimc.World.Clock
    :ok = Clock.configure({:advance_weather, false})
    :ok = Clock.configure({:weather, :clear, 0})
    :ok = Clock.configure({"minecraft:overworld", :ticks, 6000})
    on_exit(fn -> Clock.configure({:advance_weather, true}) end)
    nonce = System.unique_integer([:positive])
    key = {70_000 + rem(nonce, 333) * 3, 2900}
    base = Path.join(System.tmp_dir!(), "valimc-hostile-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :items, %{records: []})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    {x0, z0} = {rx * 128 + 8, rz * 128 + 8}
    stone = Valimc.Data.Blocks.default_state("stone")

    for x <- (x0 - 6)..(x0 + 6),
        z <- (z0 - 3)..(z0 + 3),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    # A roof over the western end.
    for x <- (x0 - 6)..(x0 - 3),
        z <- (z0 - 3)..(z0 + 3),
        do: Valimc.TestBlocks.set({x, 67, z}, stone)

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

    %{key: key, owner: owner, at: {x0 + 0.5, z0 + 0.5}}
  end

  # A finalized one may wear a Halloween pumpkin, which keeps the sun off:
  # the burning zombies skip their spawn.
  defp summon(ctx, uuid, {x, y, z}, finalize \\ false, type \\ "minecraft:zombie") do
    {:ok, body} =
      if finalize,
        do: Body.spawned(type, :command),
        else: Body.new(type)

    # It stands still: only the sun acts on it.
    body = put_in(body.mob.no_ai, true)
    :ok = Region.drop_items(ctx.owner, [Store.body_record(body, uuid, {x, y, z})])
  end

  defp entry(ctx, uuid) do
    store = Valimc.TestRegion.section(ctx.owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, uuid)
    store.entries[id]
  end

  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  test "a zombie finishes its spawn, burns in the open by day and not under a roof", ctx do
    {x, z} = ctx.at
    summon(ctx, <<1::128>>, {x + 3.0, 64.0, z})
    summon(ctx, <<2::128>>, {x - 5.0, 64.0, z})
    summon(ctx, <<3::128>>, {x, 64.0, z + 2.0}, true)
    step(ctx, 1)

    # `finalizeSpawn` ran: a follow range bonus, its own reinforcement chance.
    spawned = entry(ctx, <<3::128>>)
    assert spawned.body.mob.finalize == nil
    assert Map.has_key?(spawned.body.mob.attributes, "minecraft:spawn_reinforcements")

    step(ctx, 300)
    assert entry(ctx, <<1::128>>).body.mob.living.fire_ticks > 0
    assert entry(ctx, <<2::128>>).body.mob.living.fire_ticks <= 0
  end

  test "flint and steel lights a creeper, which explodes and is gone", ctx do
    {x, z} = ctx.at
    summon(ctx, <<4::128>>, {x + 3.0, 64.0, z}, false, "minecraft:creeper")

    request = %{
      item: ItemStack.new("minecraft:flint_and_steel"),
      infinite: false,
      player: <<9::128>>
    }

    assert {:ok, %{hand: {:wear, 1}, swing: true}} =
             Region.interact_entity(ctx.owner, <<4::128>>, request)

    assert entry(ctx, <<4::128>>).body.data.ignited
    step(ctx, 40)
    store = Valimc.TestRegion.section(ctx.owner).entities.store
    assert {:error, _} = Store.find(store, <<4::128>>)
  end
end
