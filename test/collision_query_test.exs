defmodule Valimc.CollisionQueryTest do
  use ExUnit.Case, async: false
  # Serial: queries run against production latency deadlines that concurrent CPU
  # load can exceed, and one test saturates the shared geometry worker pool.
  alias Valimc.TestScope
  alias Valimc.Physics.{CollisionQuery, Collision, CollisionContext}
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    keys = for x <- -402..-401, z <- -402..-401, do: {x, z}
    for key <- keys, do: assert({:ok, _} = World.owner(key))

    on_exit(fn ->
      for key <- keys,
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)
    end)

    %{keys: keys, origin: -51_328}
  end

  defp await(task), do: Task.await(task, 60_000)

  test "live geometry spans existing owners and retains exact snapshot fences", %{origin: n} do
    for x <- (n - 1)..(n + 1), y <- 64..65, do: :ok = Valimc.TestBlocks.set({x, y, n}, 1)
    box = {n - 0.3, 64.0, n - 2.3, n + 0.3, 65.8, n + 2.3}
    {:ok, task} = CollisionQuery.start(box)
    assert {:ok, result} = await(task)
    assert map_size(result.fences) == 4
    assert Enum.any?(result.colliders, &(&1.position == {n, 64, n}))
    shapes = Enum.map(result.colliders, & &1.shape)

    assert {+0.0, +0.0, dz} =
             Collision.move({n - 0.3, 64.0, n - 2.3, n + 0.3, 65.8, n - 1.7}, shapes, {0, 0, 4})

    assert_in_delta dz, 1.7, 1.0e-10

    for {key, fence} <- result.fences do
      assert {:ok, _} = Region.observe_blocks(fence.owner, [], fence.revision)
      assert {:ok, owner} = World.existing_owner(key)
      assert fence.owner == owner
    end
  end

  test "unknown or invalid space fails without allocating regions or jobs" do
    key = {-950, -950}
    n = -121_600
    assert Registry.lookup(Valimc.RegionRegistry, key) == []
    {:ok, task} = CollisionQuery.start({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    assert {:error, {:region, ^key, :region_unavailable}} = await(task)
    assert Registry.lookup(Valimc.RegionRegistry, key) == []

    for box <- [nil, {30_000_000, 0, 0, 30_000_001, 1, 1}, {0, 1_000_000, 0, 1, 1_000_001, 1}] do
      assert {:error, _} = CollisionQuery.start(box)
    end

    assert {:error, :invalid_collision_query} = CollisionQuery.start({0, 64, 0, 1, 65, 1}, :bad)
  end

  test "batch planning deduplicates overlaps and refuses count/cell/coordinate overflow", %{
    origin: n
  } do
    box = {n + 4.2, 64, n + 4.2, n + 4.8, 64.25, n + 4.8}
    {:ok, plan} = Valimc.Physics.BlockScan.plan(box)

    {:ok, task} =
      CollisionQuery.start_batch_frame(
        List.duplicate(box, 32),
        &Valimc.Physics.BlockCollisions.prepare/1
      )

    assert {:ok, frame} = await(task)
    assert MapSet.new(Map.keys(frame.states)) == MapSet.new(plan, &elem(&1, 0))

    assert {:error, :invalid_collision_batch} =
             CollisionQuery.start_batch_frame(List.duplicate(box, 33), &{:ok, &1})

    assert {:error, :invalid_collision_batch} = CollisionQuery.start_batch_frame([], &{:ok, &1})
    assert {:error, _} = CollisionQuery.start_batch_frame([nil], &{:ok, &1})

    assert {:error, _} =
             CollisionQuery.start_batch_frame(
               [{30_000_000, 64, 0, 30_000_001, 65, 1}],
               &{:ok, &1}
             )

    sparse =
      for i <- 1..32, do: {n + i * 5.0 + 0.2, 64, n + 4.2, n + i * 5.0 + 1.8, 65.8, n + 5.8}

    assert {:error, :block_scan_limit} = CollisionQuery.start_batch_frame(sparse, &{:ok, &1})
  end

  test "batch results recheck real source revisions after pure work", %{origin: n} do
    box = {n + 5.2, 64, n + 5.2, n + 5.8, 64.25, n + 5.8}

    {:ok, task} =
      CollisionQuery.start_batch_frame([box], fn observations ->
        :ok = Valimc.TestBlocks.set({n + 5, 64, n + 5}, 1)
        {:ok, observations}
      end)

    assert await(task) == {:error, {:region, {-401, -401}, :stale_revision}}
  end

  test "a suspended owner does not delay reads of its published snapshot", %{origin: n} do
    {:ok, {pid, _}} = World.existing_owner({-401, -401})
    :ok = Valimc.TestBlocks.set({n + 1, 64, n + 1}, 1)
    :sys.suspend(pid)

    try do
      {:ok, task} = CollisionQuery.start({n + 1.2, 64, n + 1.2, n + 1.8, 65.8, n + 1.8})
      assert {:ok, %{colliders: [_ | _]}} = await(task)
    after
      :sys.resume(pid)
    end
  end

  test "snapshot rows newer than the fence and foreign epochs are rejected" do
    alias Valimc.World.{BlockSnapshot, Blocks}
    table = :ets.new(:snapshot_test, [:set, :public])
    epoch = make_ref()
    {:ok, blocks} = Blocks.new({0, 0}, %{{1, 70, 1} => 1})
    :ok = BlockSnapshot.publish_chunks(table, blocks, [{0, 0}], 1)
    BlockSnapshot.publish_fence(table, epoch, 1)

    assert {:ok, 1, %{{1, 70, 1} => 1, {40, 63, 40} => 9}} =
             BlockSnapshot.read(table, epoch, [{1, 70, 1}, {40, 63, 40}])

    # Owner order is rows first, fence last: a reader between them sees a newer row.
    :ok = Blocks.put(blocks, %{{1, 70, 1} => 0})
    :ok = BlockSnapshot.publish_chunks(table, blocks, [{0, 0}], 2)
    assert {:error, :stale_revision} = BlockSnapshot.read(table, epoch, [{1, 70, 1}])
    BlockSnapshot.publish_fence(table, epoch, 2)
    assert {:ok, 2, %{{1, 70, 1} => 0}} = BlockSnapshot.read(table, epoch, [{1, 70, 1}])
    refute BlockSnapshot.current?(table, epoch, 1)
    assert {:error, :stale_owner} = BlockSnapshot.read(table, make_ref(), [{1, 70, 1}])
  end

  test "cancellation and dead owners leave no live query or late result", %{origin: n} do
    box = {n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8}
    parent = self()

    hold = fn _observations ->
      send(parent, {:holding, self()})

      receive do
        :release -> {:ok, :done}
      end
    end

    {:ok, cancelled} = CollisionQuery.start_frame(box, CollisionContext.empty(), hold)
    assert_receive {:holding, _}
    assert Task.shutdown(cancelled, :brutal_kill) == nil
    refute Process.alive?(cancelled.pid)

    {:ok, {pid, _}} = World.existing_owner({-401, -401})
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, dead} = CollisionQuery.start(box)
    assert {:error, {:region, {-401, -401}, :region_unavailable}} = await(dead)
  end

  test "a shulker box without observed block-entity facts collides as a full block", %{origin: n} do
    :ok = Valimc.TestBlocks.set({n + 5, 64, n + 5}, 16849)

    {:ok, task} =
      CollisionQuery.start(
        {n + 5.2, 64.2, n + 5.2, n + 5.8, 64.8, n + 5.8},
        CollisionContext.empty()
      )

    assert {:ok, %{colliders: [_ | _]}} = await(task)
  end

  test "sampled geometry rechecks every source after computation", %{origin: n} do
    parent = self()
    box = {n - 0.3, 64.0, n - 0.3, n + 0.3, 65.8, n + 0.3}

    finish = fn observations ->
      send(parent, {:sampled, self(), observations})

      receive do
        :computed -> {:ok, :selected}
      end
    end

    {:ok, unchanged} = CollisionQuery.start_frame(box, CollisionContext.empty(), finish)
    assert_receive {:sampled, worker, observations}
    assert MapSet.size(MapSet.new(observations, & &1.region)) == 4
    send(worker, :computed)
    assert await(unchanged) == {:ok, :selected}

    {:ok, changed} = CollisionQuery.start_frame(box, CollisionContext.empty(), finish)
    assert_receive {:sampled, worker, _}
    :ok = Valimc.TestBlocks.set({n - 1, 64, n - 1}, 1)
    send(worker, :computed)
    assert await(changed) == {:error, {:region, {-402, -402}, :stale_revision}}

    {:ok, replaced} = CollisionQuery.start_frame(box, CollisionContext.empty(), finish)
    assert_receive {:sampled, worker, _}
    {:ok, {owner, _}} = World.existing_owner({-402, -402})
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, owner)
    assert {:ok, _} = World.owner({-402, -402})
    send(worker, :computed)
    assert await(replaced) == {:error, {:region, {-402, -402}, :region_unavailable}}
  end

  test "prepared movement retains geometry plans, never owner incarnations or block facts", %{
    origin: n
  } do
    key = {-401, -401}
    pos = {n + 5, 64, n + 5}
    box = {n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8}
    context = CollisionContext.empty()

    {:ok, start} =
      CollisionQuery.prepare_movement_frame(
        box,
        context,
        &Valimc.Physics.BlockCollisions.collect(box, &1, context)
      )

    :ok = Valimc.TestBlocks.set(pos, 1)
    {:ok, task} = start.()
    assert {:ok, first} = await(task)
    assert [%{position: ^pos, state: 1}] = first.colliders
    {:ok, {old, _}} = World.existing_owner(key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, old)
    {:ok, replacement} = World.owner(key)
    refute elem(replacement, 0) == old
    :ok = Valimc.TestBlocks.set(pos, 0)
    {:ok, task} = start.()
    assert {:ok, %{colliders: [], fences: fences}} = await(task)
    assert fences[key].owner == replacement
    assert first.fences[key].owner != replacement
  end

  test "pool capacity rejects excess admission and becomes usable after release", %{origin: n} do
    # Pools are partitioned by caller; fill this caller's partition.
    holders = Valimc.TestPool.fill(self())
    assert length(holders) >= div(CollisionQuery.worker_limit(), Valimc.Workers.partitions())

    try do
      assert {:error, :collision_workers_busy} =
               CollisionQuery.start({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    after
      Valimc.TestPool.release(holders)
    end

    Valimc.TestWait.until(fn -> Valimc.TestPool.active(self()) == 0 end)
    {:ok, task} = CollisionQuery.start({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    assert {:ok, _} = await(task)
  end
end
