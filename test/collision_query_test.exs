defmodule Valimc.CollisionQueryTest do
  use ExUnit.Case, async: false
  # Serial: queries run against production latency deadlines that concurrent CPU
  # load can exceed, and one test saturates the shared geometry worker pool.
  alias Valimc.TestScope
  alias Valimc.Physics.{BlockCollisions, Collision, CollisionQuery}
  alias Valimc.World
  alias Valimc.World.View

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
  defp collide(box), do: CollisionQuery.start_frame(box, &BlockCollisions.collect(box, &1))

  test "geometry reads every owner's published snapshot through one view", %{origin: n} do
    for x <- (n - 1)..(n + 1), y <- 64..65, do: :ok = Valimc.TestBlocks.set({x, y, n}, 1)
    box = {n - 0.3, 64.0, n - 2.3, n + 0.3, 65.8, n + 2.3}
    parent = self()

    {:ok, task} =
      CollisionQuery.start_frame(box, fn view ->
        send(parent, {:owners, View.owners(view)})
        BlockCollisions.collect(box, view)
      end)

    assert {:ok, result} = await(task)
    assert_receive {:owners, owners}
    assert length(owners) == 4
    assert Enum.any?(result.colliders, &(&1.position == {n, 64, n}))
    shapes = Enum.map(result.colliders, & &1.shape)

    assert {+0.0, +0.0, dz} =
             Collision.move({n - 0.3, 64.0, n - 2.3, n + 0.3, 65.8, n - 1.7}, shapes, {0, 0, 4})

    assert_in_delta dz, 1.7, 1.0e-10
  end

  test "space of a region not running cannot be read and allocates nothing" do
    key = {-950, -950}
    n = -121_600
    assert Registry.lookup(Valimc.RegionRegistry, key) == []
    {:ok, task} = collide({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    assert {:error, {:missing_block, _}} = await(task)
    assert Registry.lookup(Valimc.RegionRegistry, key) == []

    for box <- [nil, {30_000_000, 0, 0, 30_000_001, 1, 1}, {0, 1_000_000, 0, 1, 1_000_001, 1}] do
      assert {:error, _} = CollisionQuery.start_frame(box, &{:ok, &1})
    end
  end

  test "a batch reads its bodies' boxes and refuses count and coordinate overflow", %{origin: n} do
    box = {n + 4.2, 64, n + 4.2, n + 4.8, 64.25, n + 4.8}

    {:ok, task} =
      CollisionQuery.start_batch_frame(List.duplicate(box, 32), &BlockCollisions.collect(box, &1))

    assert {:ok, %{colliders: _}} = await(task)

    assert {:error, :invalid_collision_batch} =
             CollisionQuery.start_batch_frame(List.duplicate(box, 33), &{:ok, &1})

    assert {:error, :invalid_collision_batch} = CollisionQuery.start_batch_frame([], &{:ok, &1})
    assert {:error, _} = CollisionQuery.start_batch_frame([nil], &{:ok, &1})

    assert {:error, _} =
             CollisionQuery.start_batch_frame(
               [{30_000_000, 64, 0, 30_000_001, 65, 1}],
               &{:ok, &1}
             )
  end

  test "a block change elsewhere in the region does not discard the result", %{origin: n} do
    box = {n + 5.2, 64, n + 5.2, n + 5.8, 64.25, n + 5.8}

    {:ok, task} =
      CollisionQuery.start_frame(box, fn view ->
        # A furnace lighting up a few chunks away, while the job computes.
        :ok = Valimc.TestBlocks.set({n + 60, 70, n + 60}, 1)
        BlockCollisions.collect(box, view)
      end)

    assert {:ok, %{colliders: []}} = await(task)
  end

  test "a suspended owner does not delay reads of its published snapshot", %{origin: n} do
    {:ok, {pid, _}} = World.existing_owner({-401, -401})
    :ok = Valimc.TestBlocks.set({n + 1, 64, n + 1}, 1)
    :sys.suspend(pid)

    try do
      {:ok, task} = collide({n + 1.2, 64, n + 1.2, n + 1.8, 65.8, n + 1.8})
      assert {:ok, %{colliders: [_ | _]}} = await(task)
    after
      :sys.resume(pid)
    end
  end

  test "cancellation leaves no live query or late result", %{origin: n} do
    box = {n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8}
    parent = self()

    hold = fn _view ->
      send(parent, {:holding, self()})

      receive do
        :release -> {:ok, :done}
      end
    end

    {:ok, cancelled} = CollisionQuery.start_frame(box, hold)
    assert_receive {:holding, _}
    assert Task.shutdown(cancelled, :brutal_kill) == nil
    refute Process.alive?(cancelled.pid)
  end

  test "a shulker box without observed block-entity facts collides as a full block", %{origin: n} do
    :ok = Valimc.TestBlocks.set({n + 5, 64, n + 5}, 16849)
    {:ok, task} = collide({n + 5.2, 64.2, n + 5.2, n + 5.8, 64.8, n + 5.8})
    assert {:ok, %{colliders: [_ | _]}} = await(task)
  end

  test "pool capacity rejects excess admission and becomes usable after release", %{origin: n} do
    # Pools are partitioned by caller; fill this caller's partition.
    holders = Valimc.TestPool.fill(self())
    assert length(holders) >= div(CollisionQuery.worker_limit(), Valimc.Workers.partitions())

    try do
      assert {:error, :collision_workers_busy} =
               collide({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    after
      Valimc.TestPool.release(holders)
    end

    Valimc.TestWait.until(fn -> Valimc.TestPool.active(self()) == 0 end)
    {:ok, task} = collide({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    assert {:ok, _} = await(task)
  end
end
