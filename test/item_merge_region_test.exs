defmodule Valimc.ItemMergeRegionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Items, Region, Store}

  setup do
    n = System.unique_integer([:positive])
    key = {41000 + rem(n, 10000), 900}
    base = Path.join(System.tmp_dir!(), "valimc-item-merge-#{n}")
    File.mkdir_p!(base)
    previous = Valimc.config(:world_path)
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
    path = Store.item_path(base, key)

    {:ok, bytes} =
      ItemLedger.encode(key, records, receipts, %ItemLedger{generations: %{<<2::128>> => 3}})

    File.write!(path, bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key) do
        state = :sys.get_state(pid).resource
        if Process.alive?(state.store), do: :sys.resume(state.store)
        DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{owner: owner, key: key, base: base, path: path, records: records, receipts: receipts}
  end

  defp state({pid, _}), do: :sys.get_state(pid).resource

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

  defp disk(ctx) do
    {:ok, saved} = ItemLedger.decode(File.read!(ctx.path), ctx.key)
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
      wait(fn -> match?(%{phase: :writing}, state(ctx.owner).item_pending) end)
      assert length(Items.records(state(ctx.owner).items)) == 2
      assert length(disk(ctx).records) == 2
      assert [{:items, views}] = :ets.lookup(s.item_publication, :items)
      assert map_size(views) == 2
      assert Task.yield(task, 10) == nil
      assert {:error, :item_storage_busy} = Region.merge_items(ctx.owner, proposal)
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
    File.write!(Path.join(ctx.base, "blocked"), "file")
    :sys.replace_state(writer, &%{&1 | items: Path.join(ctx.base, "blocked/items")})
    original = File.read!(ctx.path)
    {pid, _} = ctx.owner
    ref = Process.monitor(pid)

    capture_log(fn ->
      assert {:error, :item_commit_uncertain} = Region.merge_items(ctx.owner, pairs(ctx.owner))
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1500
    end)

    assert File.read!(ctx.path) == original
    assert {:ok, next} = World.item_owner(ctx.key)
    assert Items.records(state(next).items) == ctx.records
    assert state(next).item_receipts == ctx.receipts
  end

  test "epoch/deadline/invalid batches refuse before storage", ctx do
    {pid, epoch} = ctx.owner
    original = File.read!(ctx.path)
    proposal = pairs(ctx.owner)
    assert {:error, :stale_region} = Region.merge_items({pid, make_ref()}, proposal)

    assert {:error, :expired_item_step} =
             GenServer.call(
               pid,
               {:merge_items, epoch, proposal, System.monotonic_time(:millisecond) - 1}
             )

    assert {:error, :invalid_item_merges} = Region.merge_items(ctx.owner, proposal ++ proposal)
    assert File.read!(ctx.path) == original and state(ctx.owner).item_pending == nil
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
      assert state(ctx.owner).item_pending == nil and length(disk(ctx).records) == 2
    after
      for pid <- blocked, do: Task.Supervisor.terminate_child(Valimc.ItemWorkers, pid)
    end
  end
end
