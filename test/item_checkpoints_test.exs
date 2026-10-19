defmodule Valimc.ItemCheckpointsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.{ItemMotionState, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemRecords, Items, Region, Store}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-item-checkpoints-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {20_000 + rem(nonce, 10_000), 320}
    {:ok, {pid, _} = owner} = World.item_owner(key)
    {rx, rz} = key
    position = {rx * 128 + 8.5, 65.5, rz * 128 + 8.5}
    {x, y, z} = position

    record = %{
      uuid: <<71::128>>,
      x: x,
      y: y,
      z: z,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{}
    }

    transfer = %{source: <<91::128>>, sequence: 1, records: [record]}
    assert {:ok, :applied} = Region.apply_item_transfer(owner, transfer)
    assert {:ok, handle} = Region.find_item(owner, record.uuid)

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, live)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      pid: pid,
      owner: owner,
      position: position,
      handle: handle,
      transfer: transfer
    }
  end

  defp state(ctx), do: :sys.get_state(ctx.pid).resource
  defp send_resource(ctx, message), do: send(ctx.pid, {:resource, elem(ctx.owner, 1), message})

  defp step(ctx, {_, _, id, revision}, n) do
    {x, y, z} = ctx.position

    %{
      id: id,
      revision: revision,
      position: {x + n * 0.01, y, z},
      motion: %ItemMotionState{age: n, no_gravity: true, velocity: {0.01, 0, 0}}
    }
  end

  defp advance(ctx, handle, n) do
    assert {:ok, [next]} = Region.publish_item_motion(ctx.owner, [step(ctx, handle, n)])
    next
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  defp read(ctx) do
    assert {:ok, data} = ItemRecords.decode(disk(ctx), ctx.key)
    data
  end

  defp checkpoint(ctx) do
    timer = state(ctx).item_checkpoint_timer
    assert timer != nil
    send_resource(ctx, {:item_checkpoint, timer.token})
    assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
  end

  defp wait(ctx, predicate, attempts \\ 200) do
    value = state(ctx)

    if predicate.(value),
      do: value,
      else:
        (
          assert attempts > 0
          Process.sleep(2)
          wait(ctx, predicate, attempts - 1)
        )
  end

  test "motion publishes while the writer is suspended and coalesces to one in-flight snapshot",
       ctx do
    writer = state(ctx).store
    before = disk(ctx)
    :sys.suspend(writer)

    try do
      first = Enum.reduce(1..20, ctx.handle, &advance(ctx, &2, &1))
      assert disk(ctx) == before
      assert World.item_snapshot(ctx.key)[elem(first, 2)].revision == 21
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
      checkpoint(ctx)
      pending = state(ctx).item_checkpoint
      assert pending.generation == 20
      assert {:message_queue_len, 1} = Process.info(writer, :message_queue_len)
      final = Enum.reduce(21..40, first, &advance(ctx, &2, &1))
      assert state(ctx).item_checkpoint.token == pending.token
      assert state(ctx).item_checkpoint_timer == nil
      assert {:message_queue_len, 1} = Process.info(writer, :message_queue_len)
      :sys.resume(writer)
      saved = wait(ctx, &(&1.item_checkpoint == nil))
      assert saved.item_saved_generation == 20 and saved.item_motion_generation == 40
      checkpoint(ctx)
      wait(ctx, &(&1.item_saved_generation == 40))
      assert read(ctx).records == Items.records(state(ctx).items)
      assert {:ok, ^final} = Region.find_item(ctx.owner, <<71::128>>)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a critical stack change follows a checkpoint and includes newer motion without rollback",
       ctx do
    first = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)

    try do
      checkpoint(ctx)
      second = advance(ctx, first, 2)
      replacement = Task.async(fn -> Region.replace_item(second, ItemStack.new("egg", 3)) end)
      wait(ctx, &(&1.item_pending != nil))
      assert {:message_queue_len, 2} = Process.info(writer, :message_queue_len)

      assert {:error, :item_storage_busy} =
               Region.publish_item_motion(ctx.owner, [step(ctx, second, 3)])

      assert {:error, :item_storage_busy} = Region.flush(ctx.pid)
      assert Task.yield(replacement, 10) == nil
      :sys.resume(writer)
      assert {:ok, final} = Task.await(replacement)
      after_commit = state(ctx)
      assert after_commit.item_saved_generation == after_commit.item_motion_generation
      assert read(ctx).records == Items.records(after_commit.items)
      assert [%{stack: %{item_id: id}, motion: %{age: 2}}] = read(ctx).records
      assert id == ItemStack.new("egg").item_id
      assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, ctx.transfer)
      assert {:ok, ^final} = Region.find_item(ctx.owner, <<71::128>>)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "removal stays durable across an older in-flight motion snapshot and original delivery retry",
       ctx do
    handle = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)

    try do
      checkpoint(ctx)
      removal = Task.async(fn -> Region.remove_item(handle) end)
      wait(ctx, &(&1.item_pending != nil))
      :sys.resume(writer)
      assert :ok = Task.await(removal)
      assert read(ctx).records == []
      assert read(ctx).receipts[ctx.transfer.source].sequence == 1
      assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, ctx.transfer)
      assert World.item_snapshot(ctx.key) == %{}
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "flush persists latest motion after an older queued checkpoint without redirtying it",
       ctx do
    first = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)

    try do
      checkpoint(ctx)
      _second = advance(ctx, first, 2)
      flushing = Task.async(fn -> Region.flush(ctx.pid) end)
      assert Task.yield(flushing, 10) == nil
      :sys.resume(writer)
      assert :ok = Task.await(flushing)
      clean = wait(ctx, &(&1.item_checkpoint == nil))
      assert clean.item_saved_generation == 2 and clean.item_motion_generation == 2
      assert read(ctx).records == Items.records(clean.items)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "normal shutdown checkpoints motion but a crash may roll back only ordinary motion", ctx do
    _first = advance(ctx, ctx.handle, 1)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    assert [%{motion: %{age: 1}}] = read(ctx).records
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    fresh = %{ctx | pid: pid, owner: owner}
    assert {:ok, handle} = Region.find_item(owner, <<71::128>>)
    _second = advance(fresh, handle, 2)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1500
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert [%{motion: %{age: 1}}] = Items.records(:sys.get_state(pid).resource.items)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, ctx.transfer)
    assert map_size(:sys.get_state(pid).resource.items.entries) == 1
  end

  test "foreign callback/epoch/lease and stale/expired steps cannot acknowledge or change motion",
       ctx do
    handle = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)

    try do
      checkpoint(ctx)
      pending = state(ctx).item_checkpoint
      send(ctx.pid, {:items_saved, writer, pending.token, :ok})
      send(ctx.pid, {:resource, make_ref(), {:items_saved, writer, pending.token, :ok}})
      send_resource(ctx, {:items_saved, self(), pending.token, :ok})
      send_resource(ctx, {:items_saved, writer, make_ref(), :ok})
      send_resource(ctx, {:item_checkpoint_deadline, make_ref()})
      assert state(ctx).item_checkpoint.token == pending.token
      assert state(ctx).item_saved_generation == 0

      assert {:error, :stale_item} =
               Region.publish_item_motion(ctx.owner, [step(ctx, ctx.handle, 2)])

      assert {:error, :stale_region} =
               Region.publish_item_motion({ctx.pid, make_ref()}, [step(ctx, handle, 2)])

      assert {:error, :expired_item_step} =
               GenServer.call(
                 ctx.pid,
                 {:publish_item_motion, elem(ctx.owner, 1), [step(ctx, handle, 2)],
                  System.monotonic_time(:millisecond) - 1}
               )

      :sys.resume(writer)
      wait(ctx, &(&1.item_checkpoint == nil))

      assert {:error, :stale_store_lease} =
               Store.flush_items(writer, make_ref(), state(ctx).items, state(ctx).item_receipts)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "checkpoint disk failure fences the owner and leaves the old critical receipt recoverable",
       ctx do
    old = disk(ctx)
    _ = advance(ctx, ctx.handle, 1)
    Valimc.TestDisk.break_writer(state(ctx).store)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      timer = state(ctx).item_checkpoint_timer
      send_resource(ctx, {:item_checkpoint, timer.token})
      assert_receive {:DOWN, ^ref, :process, _, {:item_checkpoint_failed, _}}, 1500
    end)

    assert disk(ctx) == old
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert [%{motion: %{age: 0}}] = Items.records(:sys.get_state(pid).resource.items)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, ctx.transfer)
  end

  test "shutdown cannot flush old motion over a queued critical removal", ctx do
    handle = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)

    try do
      checkpoint(ctx)
      _ = advance(ctx, handle, 2)
      {:ok, current} = Region.find_item(ctx.owner, <<71::128>>)
      removal = Task.async(fn -> Region.remove_item(current) end)
      wait(ctx, &(&1.item_pending != nil))

      stopping =
        Task.async(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid) end)

      assert {:error, :item_commit_uncertain} = Task.await(removal)
      :sys.resume(writer)
      assert :ok = Task.await(stopping)
      assert read(ctx).records == []
      assert read(ctx).receipts[ctx.transfer.source].sequence == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a timed-out checkpoint fences the owner without losing its critical retry receipt", ctx do
    _ = advance(ctx, ctx.handle, 1)
    writer = state(ctx).store
    :sys.suspend(writer)
    checkpoint(ctx)
    pending = state(ctx).item_checkpoint
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      send_resource(ctx, {:item_checkpoint_deadline, pending.token})
      assert_receive {:DOWN, ^ref, :process, _, :item_checkpoint_timeout}, 2500
    end)

    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert [%{motion: %{age: 0}}] = Items.records(:sys.get_state(pid).resource.items)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, ctx.transfer)
  end
end
