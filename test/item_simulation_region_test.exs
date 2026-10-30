defmodule Valimc.ItemSimulationRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

  setup :scope

  def scope(tags) do
    nonce = System.unique_integer([:positive])
    key = {60_000 + rem(nonce, 333) * 3, 2000}
    base = Path.join(System.tmp_dir!(), "valimc-item-simulation-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)
    {rx, rz} = key
    motion = Map.get(tags, :motion, %ItemMotionState{})
    count = Map.get(tags, :count, 1)

    records =
      for n <- 1..count do
        x = if Map.get(tags, :edge, false), do: 127.85, else: 4.5 + rem(n - 1, 16) * 4

        %{
          uuid: <<n::128>>,
          x: rx * 128 + x,
          y: 68.0,
          z: rz * 128 + 4.5 + div(n - 1, 16) * 4,
          stack: ItemStack.new("stone", 3),
          motion: motion
        }
      end

    Valimc.TestDisk.write(base, key, :items, %{records: records})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}) do
        :sys.resume(pid)
        TestScope.kill(pid)
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, base: base, records: records}
  end

  def state(ctx), do: Valimc.TestRegion.section(ctx.owner)
  def entry(ctx), do: state(ctx).entities.store.entries |> Map.values() |> hd()

  # Owners tick only when stepped: advance every live owner around the test's
  # region one tick (items move within the tick, VMC-077l).
  def wait(ctx, fun, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      fun.() ||
        (
          step(ctx, 1)
          nil
        )
    end)
  end

  def step(ctx, ticks) do
    for key <- TestScope.neighborhood(ctx.key),
        {pid, _} <- Valimc.TestWorld.registered(key) do
      TestScope.simulate(pid, key)
      Region.step({pid, nil}, ticks)
    end

    :ok
  end

  @tag motion: %ItemMotionState{no_gravity: true}
  test "the owner retains the item's water observation until its next physics step", ctx do
    record = hd(ctx.records)
    pos = {floor(record.x), floor(record.y), floor(record.z)}
    :ok = Valimc.TestBlocks.set(pos, Valimc.Data.Blocks.default_state("water"))
    refute entry(ctx).motion.in_water
    step(ctx, 1)
    assert entry(ctx).motion.in_water
    :ok = Valimc.TestBlocks.set(pos, 0)
    assert entry(ctx).motion.in_water
    step(ctx, 1)
    refute entry(ctx).motion.in_water
  end

  @tag count: 256
  test "one owner advances every active item at its cadence", ctx do
    wait(ctx, fn ->
      Enum.all?(state(ctx).entities.store.entries, fn {_, e} -> e.entity.y < 67.8 end)
    end)

    store = state(ctx).entities.store
    entries = Enum.map(Map.values(store.entries), &Valimc.Entity.Store.settled(store, &1))
    assert length(entries) == 256
    assert length(Enum.uniq(Enum.map(entries, & &1.motion.age))) == 1
    assert Enum.all?(entries, &(&1.motion.age >= 3))
  end

  @tag count: 4
  test "items at rest are neither stepped nor aged until a chunk they read changes", ctx do
    alias Valimc.Entity.{Spatial, Store}
    resting = fn -> map_size(state(ctx).entities.store.spatial.resting) end
    wait(ctx, fn -> resting.() == 4 end)
    before = state(ctx).entities.store
    step(ctx, 20)
    store = state(ctx).entities.store

    # Twenty ticks later nothing of them was rebuilt, and their age ran.
    assert store.entries == before.entries and store.views == before.views
    assert Spatial.awake(store.spatial, Map.keys(store.clocks)) == []

    for {id, entry} <- store.entries,
        do:
          assert(
            Store.settled(store, entry).motion.age ==
              Store.settled(before, before.entries[id]).motion.age + 20
          )

    # Its checkpoint saves the age it has now.
    assert :ok = Region.flush(elem(ctx.owner, 0))
    saved = Valimc.TestDisk.read(ctx.base, ctx.key, :items)

    for record <- saved.records,
        {_, entry} = Enum.find(store.entries, fn {_, e} -> e.entity.uuid == record.uuid end),
        do: assert(record.motion.age == Store.settled(store, entry).motion.age)

    # The block under one goes: the items reading its chunk wake and it falls.
    {id, entry} = Enum.min_by(store.entries, fn {_, e} -> e.entity.x end)
    %{x: x, y: y, z: z} = entry.entity
    :ok = Valimc.TestBlocks.set({floor(x), floor(y) - 1, floor(z)}, 0)
    step(ctx, 1)
    refute Spatial.resting?(state(ctx).entities.store.spatial, id)
    wait(ctx, fn -> state(ctx).entities.store.entries[id].entity.y < y - 0.5 end)
  end

  @tag edge: true, motion: %ItemMotionState{no_gravity: true}

  @tag motion: %ItemMotionState{age: 5998}
  test "despawn is durable", ctx do
    wait(ctx, fn ->
      state(ctx).entities.store.entries == %{} and not Valimc.TestRegion.writing?(state(ctx))
    end)

    assert :ok = Region.flush(elem(ctx.owner, 0))

    saved = Valimc.TestDisk.read(ctx.base, ctx.key, :items)

    assert saved == nil
  end

  @tag edge: true, motion: %ItemMotionState{velocity: {0.3, 0.0, 0.0}, no_gravity: true}
end
