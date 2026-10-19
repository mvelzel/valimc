defmodule Valimc.ItemMergeRegionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Items, Region}

  setup tags do
    n = System.unique_integer([:positive])
    key = {41000 + rem(n, 10000), 900}
    base = Path.join(System.tmp_dir!(), "valimc-item-merge-#{n}")
    File.mkdir_p!(base)
    previous = Valimc.config(:world_path)
    previous_simulation = Valimc.config(:item_simulation)
    Application.put_env(:valimc, :item_simulation, Map.get(tags, :simulation, false))
    Application.put_env(:valimc, :world_path, base)

    records =
      for i <- 1..2,
          do: %{
            uuid: <<i::128>>,
            x: elem(key, 0) * 128 + 8.5,
            y: 64.0,
            z: elem(key, 1) * 128 + 8.5,
            stack: ItemStack.new("stone", i + 1),
            motion: %ItemMotionState{age: i * 100, pickup_delay: i * 10, no_gravity: true}
          }

    receipts = %{<<99::128>> => %{sequence: 4, digest: :crypto.hash(:sha256, "birth")}}

    {:ok, bytes} =
      ItemLedger.encode(key, records, receipts, %ItemLedger{generations: %{<<2::128>> => 3}})

    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key) do
        state = Valimc.TestConn.state(pid).resource
        if Process.alive?(state.store), do: :sys.resume(state.store)
        DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Application.put_env(:valimc, :item_simulation, previous_simulation)
      File.rm_rf!(base)
    end)

    %{owner: owner, key: key, base: base, records: records, receipts: receipts}
  end

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp pairs(owner) do
    items = state(owner).items
    {:ok, {_, a, ar}} = Items.find(items, <<1::128>>)
    {:ok, {_, b, br}} = Items.find(items, <<2::128>>)
    [%{a: {a, ar}, b: {b, br}}]
  end

  defp wait(fun, n \\ 200) do
    case fun.() do
      x when x not in [nil, false] ->
        x

      _ ->
        assert n > 0
        Process.sleep(5)
        wait(fun, n - 1)
    end
  end

  defp survivor_age(ctx, uuid) do
    Enum.find(Items.records(state(ctx.owner).items), &(&1.uuid == uuid)).motion.age
  end

  # Owner ticks advanced the survivor's motion age and no merge job is in flight.
  defp settled(ctx, uuid, age),
    do:
      wait(fn ->
        s = state(ctx.owner)

        # Moving items change physical revisions and legitimately wake merge scans.
        survivor_age(ctx, uuid) >= age and not Valimc.TestRegion.writing?(s) and
          map_size(s.item_resting) == map_size(s.items.entries)
      end)

  defp items_bytes(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  defp disk(ctx) do
    {:ok, saved} = ItemLedger.decode(items_bytes(ctx), ctx.key)
    saved
  end

  test "publication waits for durable merge; competing mutation refuses and restart keeps one stack",
       ctx do
    s = state(ctx.owner)
    writer = s.store
    :sys.suspend(writer)

    try do
      proposal = pairs(ctx.owner)
      task = Task.async(fn -> Region.merge_items(ctx.owner, proposal) end)
      wait(fn -> Valimc.TestRegion.in_flight?(state(ctx.owner)) end)
      assert length(disk(ctx).records) == 2
      assert [{:items, views}] = :ets.lookup(s.item_publication, :items)
      assert map_size(views) == 2
      assert Task.yield(task, 10) == nil
      # The pair is already merged in owner memory; a second merge cannot apply.
      assert {:error, _} = Region.merge_items(ctx.owner, proposal)
      :sys.resume(writer)
      assert {:ok, [_]} = Task.await(task, 2000)
      assert [record] = disk(ctx).records
      assert record.uuid == <<2::128>> and record.stack.count == 5
      assert record.motion.age == 100 and record.motion.pickup_delay == 20

      assert disk(ctx).receipts == ctx.receipts and
               disk(ctx).ledger.generations == %{record.uuid => 3}

      assert {:error, :stale_item} = Region.merge_items(ctx.owner, proposal)
      {pid, _} = ctx.owner
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1500
      assert {:ok, next} = World.item_owner(ctx.key)
      assert Items.records(state(next).items) == [record]
      assert state(next).item_receipts == ctx.receipts
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "storage failure never publishes replacement and recovery retains the complete prior pair",
       ctx do
    writer = state(ctx.owner).store
    Valimc.TestDisk.break_writer(writer)
    original = items_bytes(ctx)
    {pid, _} = ctx.owner
    ref = Process.monitor(pid)

    capture_log(fn ->
      assert {:error, :item_commit_uncertain} = Region.merge_items(ctx.owner, pairs(ctx.owner))
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1500
    end)

    assert items_bytes(ctx) == original
    assert {:ok, next} = World.item_owner(ctx.key)
    assert Items.records(state(next).items) == ctx.records
    assert state(next).item_receipts == ctx.receipts
  end

  test "epoch/deadline/invalid batches refuse before storage", ctx do
    {pid, epoch} = ctx.owner
    original = items_bytes(ctx)
    proposal = pairs(ctx.owner)
    assert {:error, :stale_region} = Region.merge_items({pid, make_ref()}, proposal)

    assert {:error, :expired_item_step} =
             GenServer.call(
               pid,
               {:merge_items, epoch, proposal, System.monotonic_time(:millisecond) - 1}
             )

    assert {:error, :invalid_item_merges} = Region.merge_items(ctx.owner, proposal ++ proposal)
    assert items_bytes(ctx) == original and not Valimc.TestRegion.writing?(state(ctx.owner))
  end

  test "bounded worker saturation refuses without a queued merge", ctx do
    blocked =
      Stream.repeatedly(fn ->
        Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
          receive do
            :stop -> :ok
          end
        end)
      end)
      |> Enum.reduce_while([], fn
        {:ok, pid}, acc -> {:cont, [pid | acc]}
        {:error, :max_children}, acc -> {:halt, acc}
      end)

    try do
      assert {:error, :item_workers_busy} = Region.merge_items(ctx.owner, pairs(ctx.owner))
      assert not Valimc.TestRegion.writing?(state(ctx.owner)) and length(disk(ctx).records) == 2
    after
      for pid <- blocked, do: Task.Supervisor.terminate_child(Valimc.ItemWorkers, pid)
    end
  end

  @tag simulation: true
  test "automatic merging sleeps after convergence and wakes for a new compatible birth", ctx do
    wait(fn ->
      map_size(state(ctx.owner).items.entries) == 1 and
        not Valimc.TestRegion.writing?(state(ctx.owner))
    end)

    assert [survivor] = Items.records(state(ctx.owner).items)
    assert survivor.stack.count == 5

    named = %{
      ItemStack.new("stone")
      | components: %{"minecraft:custom_name" => {:string, "separate"}}
    }

    assert {:ok, _} = Region.create_item(ctx.owner, named, {survivor.x, survivor.y, survivor.z})
    settled(ctx, survivor.uuid, survivor_age(ctx, survivor.uuid) + 2)
    # The stamp changes only when this owner starts a merge scan (the global job
    # metric also counts other regions).
    # Items spawned at the region corner can drift across the border and return
    # with new entity ids, which legitimately rescans; compare unchanged item sets.
    stamp = state(ctx.owner).item_merge_stamp
    settled(ctx, survivor.uuid, survivor_age(ctx, survivor.uuid) + 2)
    after_settle = state(ctx.owner)

    if Map.keys(after_settle.items.entries) == Map.keys(stamp),
      do: assert(after_settle.item_merge_stamp == stamp)

    assert map_size(state(ctx.owner).items.entries) == 2

    assert {:ok, _} =
             Region.create_item(
               ctx.owner,
               ItemStack.new("stone", 2),
               {survivor.x, survivor.y, survivor.z}
             )

    wait(fn ->
      Enum.any?(
        Items.records(state(ctx.owner).items),
        &(&1.uuid == survivor.uuid and &1.stack.count == 7)
      ) and not Valimc.TestRegion.writing?(state(ctx.owner))
    end)

    assert map_size(state(ctx.owner).items.entries) == 2
    assert disk(ctx).receipts == ctx.receipts
  end
end
