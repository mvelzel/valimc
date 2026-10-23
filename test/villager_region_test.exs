defmodule Valimc.VillagerRegionTest do
  @moduledoc """
  A villager in its owner (VMC-044a1): by day it claims the bed and the
  lectern beside it and becomes a librarian; at night it lies in its bed,
  which the owner marks occupied, and its claims go with its record. An
  iron golem kills a zombie that hunts a villager (VMC-044a2).
  """
  use ExUnit.Case, async: false
  alias Valimc.AI.Brain
  alias Valimc.Data.Blocks
  alias Valimc.Entity.{Body, Store}
  alias Valimc.TestScope
  alias Valimc.World.{Clock, Region}

  setup do
    nonce = System.unique_integer([:positive])
    key = {68_000 + rem(nonce, 333) * 3, 2903}
    base = Path.join(System.tmp_dir!(), "valimc-villager-#{nonce}")
    day = Clock.snapshot().clocks["minecraft:overworld"].total_ticks

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
    stone = Blocks.default_state("stone")

    for x <- (x0 - 6)..(x0 + 6),
        z <- (z0 - 6)..(z0 + 6),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    head = Blocks.state("red_bed", %{"facing" => "east", "part" => "head", "occupied" => "false"})
    foot = Blocks.state("red_bed", %{"facing" => "east", "part" => "foot", "occupied" => "false"})
    Valimc.TestBlocks.set({x0 + 3, 64, z0}, head)
    Valimc.TestBlocks.set({x0 + 2, 64, z0}, foot)
    Valimc.TestBlocks.set({x0 - 1, 64, z0}, Blocks.default_state("lectern"))

    on_exit(fn ->
      :ok = Clock.configure({"minecraft:overworld", :ticks, day})

      for k <- TestScope.neighborhood(key), {pid, _} <- Valimc.TestWorld.registered(k) do
        try do
          :sys.resume(pid)
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

  defp villager(ctx), do: body(ctx, 31)

  defp body(ctx, n) do
    store = Valimc.TestRegion.section(ctx.owner).entities.store

    case Store.find(store, <<n::128>>) do
      {:ok, {_, id, _}} -> store.entries[id].body
      _ -> nil
    end
  end

  defp memory(body, name), do: Brain.get(%Valimc.AI.Self{mind: body.mob.ai}, name)

  test "a villager takes the trade of its lectern, claims its bed and sleeps in it at night",
       ctx do
    {x0, z0} = ctx.at
    :ok = Clock.configure({"minecraft:overworld", :ticks, 1_000})
    {:ok, body} = Body.new("minecraft:villager")
    record = Store.body_record(body, <<31::128>>, {x0 + 0.5, 64.0, z0 + 0.5})
    :ok = Region.drop_items(ctx.owner, [record])

    Valimc.TestWait.until(fn ->
      step(ctx, 10)
      body = villager(ctx)
      body.data.profession == "minecraft:librarian" and memory(body, :home) != nil
    end)

    body = villager(ctx)
    assert {:overworld, {x0 - 1, 64, z0}} == memory(body, :job_site)
    assert {:overworld, {x0 + 3, 64, z0}} == memory(body, :home)

    assert Valimc.TestRegion.section(ctx.owner).poi_claims == %{
             {x0 - 1, 64, z0} => 1,
             {x0 + 3, 64, z0} => 1
           }

    :ok = Clock.configure({"minecraft:overworld", :ticks, 13_000})

    Valimc.TestWait.until(fn ->
      step(ctx, 10)
      villager(ctx).data.sleeping == {x0 + 3, 64, z0}
    end)

    step(ctx, 1)
    bed = Valimc.TestBlocks.get({x0 + 3, 64, z0})
    assert {"occupied", "true"} in Blocks.properties(bed)
    assert {"occupied", "true"} in Blocks.properties(Valimc.TestBlocks.get({x0 + 2, 64, z0}))

    # Its record keeps what it claimed.
    record = Valimc.AI.Mind.record(villager(ctx).mob.ai)
    assert %{home: {{:overworld, {_, 64, _}}, :never}} = record.memories
  end

  test "an iron golem kills the zombie hunting a villager", ctx do
    {x0, z0} = ctx.at
    :ok = Clock.configure({"minecraft:overworld", :ticks, 18_000})

    records =
      for {n, type, x} <- [
            {31, "villager", x0 - 4},
            {32, "zombie", x0 + 4},
            {33, "iron_golem", x0}
          ] do
        {:ok, body} = Body.new("minecraft:" <> type)
        Store.body_record(body, <<n::128>>, {x + 0.5, 64.0, z0 - 3.5})
      end

    :ok = Region.drop_items(ctx.owner, records)

    Valimc.TestWait.until(fn ->
      step(ctx, 10)
      zombie = body(ctx, 32)
      zombie == nil or not Body.alive?(zombie)
    end)

    assert %Body{} = body(ctx, 33)
  end
end
