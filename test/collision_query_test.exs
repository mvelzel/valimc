defmodule Valimc.CollisionQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.Physics.{CollisionQuery, Collision, CollisionContext}
  alias Valimc.World
  alias Valimc.World.{Chunk, Region}

  setup do
    keys = for x <- -402..-401, z <- -402..-401, do: {x, z}
    for key <- keys, do: assert({:ok, _} = World.owner(key))

    on_exit(fn ->
      for key <- keys,
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    %{keys: keys, origin: -51_328}
  end

  defp await(task), do: Task.await(task, 1500)

  defp fake(key, handler) do
    parent = self()
    epoch = make_ref()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Valimc.RegionRegistry, key, %{epoch: epoch})
        send(parent, {:ready, self()})
        fake_loop(key, epoch, parent, handler, 0)
      end)

    assert_receive {:ready, ^pid}
    # Private observation fixture, installed by the directory's ETS owner. This
    # intentionally supplies fake query responses, not gameplay authority.
    :sys.replace_state(Valimc.World.Directory, fn state ->
      :ets.insert(
        Valimc.RegionRoutes,
        {key, pid, make_ref(), make_ref(), %{epoch: epoch, items: nil}}
      )

      state
    end)

    on_exit(fn ->
      :sys.replace_state(Valimc.World.Directory, fn state ->
        case :ets.lookup(Valimc.RegionRoutes, key) do
          [{^key, ^pid, _, _, _}] -> :ets.delete(Valimc.RegionRoutes, key)
          _ -> :ok
        end

        state
      end)

      Process.exit(pid, :kill)
    end)

    {pid, epoch}
  end

  defp fake_loop(key, epoch, parent, handler, index) do
    receive do
      {:"$gen_call", from, {:observe_blocks, ^epoch, batch, expected}} ->
        send(parent, {:batch, self(), batch, expected})

        observation = %{
          owner: {self(), epoch},
          region: key,
          revision: 0,
          blocks: Map.new(batch, &{&1, 0})
        }

        case handler.(index, observation) do
          :hold -> send(parent, {:held, self(), from, observation})
          reply -> GenServer.reply(from, reply)
        end

        fake_loop(key, epoch, parent, handler, index + 1)
    end
  end

  test "live geometry spans existing owners and retains exact snapshot fences", %{origin: n} do
    for x <- (n - 1)..(n + 1), y <- 64..65, do: :ok = World.set_block({x, y, n}, 1)
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

  test "out-of-build observations are native air while edits remain disallowed", %{origin: n} do
    {:ok, owner} = World.existing_owner({-401, -401})
    assert {:ok, obs} = Region.observe_blocks(owner, [{n, -65, n}, {n, 320, n}])
    assert obs.blocks == %{{n, -65, n} => 0, {n, 320, n} => 0}
    assert {:error, :invalid_block} == World.set_block({n, -65, n}, 1)
    assert Chunk.block_at(%{{0, -65, 0} => 1}, {0, -65, 0}) == 0

    for y <- [-66.5, 320.5] do
      {:ok, task} = CollisionQuery.start({n + 5.2, y, n + 5.2, n + 5.8, y + 0.6, n + 5.8})
      assert {:ok, %{colliders: []}} = await(task)
    end
  end

  test "a stalled owner does not serialize other owner requests or independent queries", %{
    origin: n
  } do
    {:ok, {pid, _}} = World.existing_owner({-401, -401})
    :sys.suspend(pid)

    try do
      {:ok, slow} = CollisionQuery.start({n - 0.3, 64, n - 0.3, n + 0.3, 65.8, n + 0.3})
      neighbour = {-402, -402}
      {:ok, owner} = World.existing_owner(neighbour)
      assert {:ok, _} = Region.observe_blocks(owner, [{n - 1, 64, n - 1}])
      {:ok, fast} = CollisionQuery.start({n - 5.8, 64, n - 5.8, n - 5.2, 65.8, n - 5.2})
      assert {:ok, %{colliders: []}} = await(fast)
      assert Process.alive?(slow.pid)
      assert {:error, :collision_query_timeout} = await(slow)
    after
      :sys.resume(pid)
    end
  end

  test "owners are requested concurrently, batches pin revisions and malformed replies reject" do
    first = fake({700, 700}, fn _, obs -> {:ok, obs} end)
    second = fake({701, 700}, fn _, _ -> :hold end)
    n = 701 * 128

    {:ok, task} =
      CollisionQuery.start({n - 0.3, 64, 700 * 128 + 5.2, n + 0.3, 65.8, 700 * 128 + 5.8})

    assert_receive {:batch, p1, _, :any}
    assert_receive {:batch, p2, _, :any}
    assert Enum.sort([p1, p2]) == Enum.sort([elem(first, 0), elem(second, 0)])
    assert {:error, :collision_query_timeout} = await(task)

    fake({702, 700}, fn index, obs ->
      if index == 0, do: {:ok, obs}, else: {:error, :stale_revision}
    end)

    n = 702 * 128 + 5

    {:ok, task} =
      CollisionQuery.start({n + 0.2, 64.2, 700 * 128 + 5.2, n + 5.8, 69.8, 700 * 128 + 10.8})

    assert {:error, {:region, {702, 700}, :stale_revision}} = await(task)
    assert_receive {:batch, _, _, 0}

    fake({703, 700}, fn _, obs -> {:ok, %{obs | blocks: %{}}} end)
    n = 703 * 128 + 5

    {:ok, task} =
      CollisionQuery.start({n + 0.2, 64.2, 700 * 128 + 5.2, n + 0.8, 65.8, 700 * 128 + 5.8})

    assert {:error, {:region, {703, 700}, :invalid_block_observation}} = await(task)
  end

  test "caller loss, cancellation and dead owners leave no live query or late result" do
    {pid, _} = fake({704, 700}, fn _, _ -> :hold end)
    n = 704 * 128 + 5
    box = {n + 0.2, 64.2, 700 * 128 + 5.2, n + 0.8, 65.8, 700 * 128 + 5.8}
    parent = self()

    caller =
      spawn(fn ->
        {:ok, task} = CollisionQuery.start(box)
        send(parent, {:task, task})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:task, task}
    ref = Process.monitor(task.pid)
    assert_receive {:batch, ^pid, _, _}
    assert_receive {:held, ^pid, _, _}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 500
    refute Process.alive?(task.pid)
    {:ok, cancelled} = CollisionQuery.start(box)
    assert_receive {:batch, ^pid, _, _}
    assert_receive {:held, ^pid, late, observation}
    assert Task.shutdown(cancelled, :brutal_kill) == nil
    refute Process.alive?(cancelled.pid)
    GenServer.reply(late, {:ok, observation})
    cancelled_ref = cancelled.ref
    refute_receive {^cancelled_ref, _}, 20
    {:ok, dead} = CollisionQuery.start(box)
    assert_receive {:batch, ^pid, _, _}
    Process.exit(pid, :kill)
    assert {:error, {:region, {704, 700}, :region_unavailable}} = await(dead)
  end

  test "pool capacity rejects excess admission and becomes usable after release", %{origin: n} do
    limit = max(System.schedulers_online(), 1)

    holders =
      for _ <- 1..limit do
        {:ok, pid} =
          Task.Supervisor.start_child(Valimc.CollisionWorkers, fn ->
            receive do
              :stop -> :ok
            end
          end)

        pid
      end

    try do
      assert {:error, :collision_workers_busy} =
               CollisionQuery.start({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    after
      for pid <- holders, do: Task.Supervisor.terminate_child(Valimc.CollisionWorkers, pid)
    end

    {:ok, task} = CollisionQuery.start({n + 5.2, 64, n + 5.2, n + 5.8, 65.8, n + 5.8})
    assert {:ok, _} = await(task)
  end

  test "an observed contextual block requires region block-entity facts", %{origin: n} do
    :ok = World.set_block({n + 5, 64, n + 5}, 16849)

    {:ok, task} =
      CollisionQuery.start(
        {n + 5.2, 64.2, n + 5.2, n + 5.8, 64.8, n + 5.8},
        CollisionContext.empty()
      )

    assert {:error, {:context_required, _, "minecraft:shulker_box"}} = await(task)
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
    :ok = World.set_block({n - 1, 64, n - 1}, 1)
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
end
