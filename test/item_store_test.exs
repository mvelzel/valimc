defmodule Valimc.ItemStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{ItemRecords, Region, Store}
  alias Valimc.Protocol.ItemStack
  import ExUnit.CaptureLog

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-items-#{nonce}")
    key = {230 + rem(nonce, 10_000), 230}
    TestScope.isolate(key, world_path: base)
    {:ok, {pid, _} = owner} = World.item_owner(key)

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf!(base)
    end)

    {rx, rz} = key

    %{
      base: base,
      key: key,
      pid: pid,
      owner: owner,
      position: {rx * 128 + 0.5, 64.5, rz * 128 + 0.5}
    }
  end

  defp wait_pending(pid, retries \\ 100) do
    case Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource) do
      nil ->
        assert(retries > 0)
        Process.sleep(1)
        wait_pending(pid, retries - 1)

      pending ->
        pending
    end
  end

  defp send_resource(ctx, message), do: send(ctx.pid, {:resource, elem(ctx.owner, 1), message})

  test "a full write queue answers retryable backpressure, and drained writes all commit", ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)

    try do
      created =
        for n <- 1..64 do
          task =
            Task.async(fn ->
              Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)
            end)

          wait_queued(ctx.pid, n)
          task
        end

      assert {:error, :storage_backpressure} =
               Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)

      :sys.resume(writer)
      assert Enum.all?(Task.await_many(created, 5000), &match?({:ok, _}, &1))
      assert {:ok, _} = Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)
      assert map_size(World.item_snapshot(ctx.key)) == 65
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp wait_queued(pid, count, retries \\ 500) do
    if length(Valimc.TestConn.state(pid).resource.item_writes) < count do
      assert retries > 0
      Process.sleep(1)
      wait_queued(pid, count, retries - 1)
    end
  end

  test "untagged and foreign-epoch callbacks cannot publish a real pending proposal", ctx do
    {handle, _, _stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)

    try do
      task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
      pending = wait_pending(ctx.pid)

      for message <- [
            {:items_saved, writer, pending.token, :ok},
            {:item_commit_deadline, pending.token}
          ] do
        send(ctx.pid, message)
        send(ctx.pid, {:resource, make_ref(), message})
      end

      assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
      assert Valimc.TestRegion.write_token(:sys.get_state(ctx.pid).resource) == pending.token
      assert Task.yield(task, 10) == nil
      # The owner adopted the change in memory, but publishes nothing before durability.
      assert World.item_snapshot(ctx.key)[elem(handle, 2)].revision == 1
      :sys.resume(writer)
      assert {:ok, updated} = Task.await(task)
      assert World.item_snapshot(ctx.key)[elem(updated, 2)].revision == 2
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "block saves require the matching resource and writer before clearing dirty state", ctx do
    {x, _, z} = ctx.position
    position = {floor(x), 64, floor(z)}
    :ok = World.set_block(position, 1)
    before = :sys.get_state(ctx.pid).resource
    assert before.dirty and not before.saving
    send(ctx.pid, {:saved, before.store, before.revision, :ok})
    send(ctx.pid, {:resource, make_ref(), {:saved, before.store, before.revision, :ok}})
    send_resource(ctx, {:saved, self(), before.revision, :ok})
    send(ctx.pid, :save)
    assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
    assert :sys.get_state(ctx.pid).resource == before
    send_resource(ctx, :save)
    assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
    assert Store.load(before.store)[position] == 1
    assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
    after_save = :sys.get_state(ctx.pid).resource
    refute after_save.dirty or after_save.saving
    assert after_save.save_timer != before.save_timer
    assert Process.read_timer(before.save_timer) == false
  end

  defp seed(ctx) do
    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:custom_data" => {:compound, %{"save" => {:string, "region"}}}},
        removed: MapSet.new(["minecraft:rarity"])
    }

    {:ok, handle} = Region.create_item(ctx.owner, stone, ctx.position)
    view = World.item_snapshot(ctx.key)[elem(handle, 2)]
    {handle, view.uuid, stone}
  end

  defp replace_owner(ctx, reason \\ :kill) do
    ref = Process.monitor(ctx.pid)

    if reason == :kill,
      do: Process.exit(ctx.pid, :kill),
      else: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 1500
    {:ok, owner} = World.item_owner(ctx.key)
    owner
  end

  test "acknowledged create/replace/remove survive owner replacement with UUID and fresh handles",
       ctx do
    {handle, uuid, _stone} = seed(ctx)
    egg = ItemStack.new("egg", 3)
    {:ok, updated} = Region.replace_item(handle, egg)
    owner = replace_owner(ctx)
    assert {:ok, current} = Region.find_item(owner, uuid)
    assert elem(current, 2) != elem(updated, 2) and elem(current, 1) != elem(updated, 1)

    assert {:error, :stale_region} =
             Region.remove_item(
               {elem(owner, 0), elem(updated, 1), elem(updated, 2), elem(updated, 3)}
             )

    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == egg
    assert :ok = Region.remove_item(current)
    next = replace_owner(%{ctx | pid: elem(owner, 0)}, :shutdown)
    assert {:error, :missing_item} = Region.find_item(next, uuid)
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "a stalled write holds replies and publication while later mutations queue behind it",
       ctx do
    {handle, _uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)

    try do
      assert {:ok, ^handle} = Region.replace_item(handle, stone)
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
      task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
      pending = wait_pending(ctx.pid)
      created = Task.async(fn -> Region.create_item(ctx.owner, stone, ctx.position) end)
      assert Task.yield(task, 10) == nil and Task.yield(created, 10) == nil
      assert map_size(World.item_snapshot(ctx.key)) == 1
      assert World.item_snapshot(ctx.key)[elem(handle, 2)].revision == 1
      {x, _, z} = ctx.position
      assert :ok = World.set_block({floor(x), 64, floor(z)}, 1)
      assert World.get_block({floor(x), 64, floor(z)}) == 1
      send_resource(ctx, {:items_saved, writer, make_ref(), :ok})
      send_resource(ctx, {:items_saved, self(), pending.token, :ok})
      send_resource(ctx, {:item_commit_deadline, make_ref()})
      assert Valimc.TestRegion.write_token(:sys.get_state(ctx.pid).resource) == pending.token
      assert {:message_queue_len, 2} = Process.info(writer, :message_queue_len)
      :sys.resume(writer)
      assert {:ok, updated} = Task.await(task)
      assert {:ok, _} = Task.await(created)
      assert World.item_snapshot(ctx.key)[elem(updated, 2)].revision == 2
      assert map_size(World.item_snapshot(ctx.key)) == 2
      assert :ok = Region.flush(ctx.pid)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a real write failure fences the owner and preserves the old recoverable state", ctx do
    {handle, uuid, stone} = seed(ctx)
    old = disk(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    Valimc.TestDisk.break_writer(writer)
    ref = Process.monitor(ctx.pid)

    assert capture_log(fn ->
             assert {:error, :item_commit_uncertain} =
                      Region.replace_item(handle, ItemStack.new("egg", 3))

             assert_receive {:DOWN, ^ref, :process, _, {:item_storage_failed, _}}, 1500
           end) =~ "Region commit failed"

    Valimc.TestDisk.await_exit(writer)
    assert disk(ctx) == old
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == stone
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "writer loss fences a pending operation and recovers the actual previous file", ctx do
    {handle, uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg")) end)
    wait_pending(ctx.pid)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      Process.exit(writer, :kill)
      assert {:error, :item_commit_uncertain} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, _, {:store_failed, :killed}}, 1500
    end)

    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == stone
  end

  test "a pending deadline fences its writer and never publishes or overwrites the old item",
       ctx do
    {handle, uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg")) end)
    pending = wait_pending(ctx.pid)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      send_resource(ctx, {:item_commit_deadline, pending.token})
      assert {:error, :item_commit_uncertain} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, _, :item_storage_timeout}, 2000
    end)

    refute Process.alive?(writer)
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == stone
  end

  test "shutdown before delivery of an acknowledgment recovers a committed proposal without rollback",
       ctx do
    {handle, uuid, _} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
    wait_pending(ctx.pid)
    :sys.suspend(ctx.pid)
    :sys.resume(writer)
    assert {:ok, %{records: [%{stack: stack}]}} = Store.load_items(writer)
    assert stack == ItemStack.new("egg", 3)
    owner = replace_owner(ctx, :shutdown)
    assert {:error, :item_commit_uncertain} = Task.await(task)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == stack
  end

  test "a corrupt item file is preserved and prevents only its region from publishing", ctx do
    seed(ctx)
    bytes = disk(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    Valimc.TestDisk.await_exit(writer)
    corrupt = bytes <> <<0>>
    Valimc.TestDisk.write(ctx.base, ctx.key, :items, corrupt)

    capture_log(fn ->
      assert {:error, reason} = World.item_owner(ctx.key)
      assert reason in [{:item_load_failed, :invalid_item_file}, :region_restarting]
    end)

    assert World.item_snapshot(ctx.key) == %{} and disk(ctx) == corrupt
    {rx, rz} = ctx.key
    {:ok, healthy} = World.item_owner({rx + 1, rz})

    assert {:ok, _} =
             Region.create_item(healthy, ItemStack.new("stone"), {(rx + 1) * 128, 64, rz * 128})

    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(healthy, 0))
  end

  test "old block snapshots cannot overwrite a newer committed item file", ctx do
    {handle, _, _} = seed(ctx)
    {:ok, _} = Region.replace_item(handle, ItemStack.new("egg", 3))
    bytes = disk(ctx)
    writer = :sys.get_state(ctx.pid).resource.store

    Store.snapshot(
      writer,
      :sys.get_state(ctx.pid).resource.store_lease,
      %{},
      {self(), elem(ctx.owner, 1)},
      31
    )

    assert_receive {:resource, _, {:saved, ^writer, 31, :ok}}
    assert disk(ctx) == bytes
    assert {:ok, %{records: [%{stack: stack}]}} = ItemRecords.decode(bytes, ctx.key)
    assert stack == ItemStack.new("egg", 3)
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  def transfer(ctx, sequence \\ 1) do
    {x, y, z} = ctx.position
    record = %{uuid: <<sequence::128>>, x: x, y: y, z: z, stack: ItemStack.new("stone", 7)}
    %{source: <<99::128>>, sequence: sequence, records: [record]}
  end

  test "transfer receipt survives removal and restart without recreating an item", ctx do
    request = transfer(ctx)
    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, request)
    assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, request)
    assert map_size(World.item_snapshot(ctx.key)) == 1
    {:ok, handle} = Region.find_item(ctx.owner, hd(request.records).uuid)
    assert :ok = Region.remove_item(handle)
    bytes = disk(ctx)
    assert {:ok, %{records: [], receipts: receipts}} = ItemRecords.decode(bytes, ctx.key)
    assert receipts[request.source].sequence == 1
    owner = replace_owner(ctx)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, request)
    assert World.item_snapshot(ctx.key) == %{} and disk(ctx) == bytes
    assert :sys.get_state(elem(owner, 0)).resource.item_receipts == receipts

    assert {:error, :stale_region} =
             Region.apply_item_transfer({elem(owner, 0), elem(ctx.owner, 1)}, request)
  end

  test "moving transfer intent survives real writer recovery and removal retains its receipt",
       ctx do
    request = transfer(ctx)
    motion = %Valimc.ItemMotionState{velocity: {0.3, 0.1, -0.2}, pickup_delay: 40}
    record = Map.put(hd(request.records), :motion, motion)
    request = %{request | records: [record]}
    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, request)
    assert <<"VMCITEMS", 3, _::binary>> = bytes = disk(ctx)
    assert {:ok, %{records: [^record], receipts: receipts}} = ItemRecords.decode(bytes, ctx.key)
    owner = replace_owner(ctx)
    assert [^record] = Valimc.World.Items.records(:sys.get_state(elem(owner, 0)).resource.items)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, request)
    assert disk(ctx) == bytes
    assert {:ok, handle} = Region.find_item(owner, record.uuid)
    assert :ok = Region.remove_item(handle)
    final = replace_owner(%{ctx | pid: elem(owner, 0)}, :shutdown)
    assert {:ok, :already_applied} = Region.apply_item_transfer(final, request)
    assert World.item_snapshot(ctx.key) == %{}

    assert {:ok, %{records: [], receipts: ^receipts}} =
             ItemRecords.decode(disk(ctx), ctx.key)
  end

  test "accepted step publication waits for disk and survives owner replacement with its receipt",
       ctx do
    request = transfer(ctx)
    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, request)
    {:ok, {_, _, id, revision}} = Region.find_item(ctx.owner, hd(request.records).uuid)
    {x, y, z} = ctx.position

    step = %{
      id: id,
      revision: revision,
      position: {x + 1, y, z},
      motion: %Valimc.ItemMotionState{velocity: {0.1, 0, 0}, pickup_delay: 39, no_gravity: true}
    }

    writer = :sys.get_state(ctx.pid).resource.store
    before = World.item_snapshot(ctx.key)
    :sys.suspend(writer)

    try do
      task = Task.async(fn -> Region.advance_items(ctx.owner, [step]) end)
      wait_pending(ctx.pid)
      assert Task.yield(task, 10) == nil
      assert World.item_snapshot(ctx.key) == before
      :sys.resume(writer)
      assert {:ok, [{_, _, ^id, 2}]} = Task.await(task)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end

    assert {:error, :expired_item_step} =
             GenServer.call(
               ctx.pid,
               {:advance_items, elem(ctx.owner, 1), [step],
                System.monotonic_time(:millisecond) - 1}
             )

    owner = replace_owner(ctx)
    assert [record] = Valimc.World.Items.records(:sys.get_state(elem(owner, 0)).resource.items)
    assert {record.x, record.y, record.z} == step.position and record.motion == step.motion
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, request)
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "scene updates and block snapshots retain the inbox receipt", ctx do
    request = transfer(ctx)
    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, request)
    {:ok, handle} = Region.find_item(ctx.owner, hd(request.records).uuid)
    assert {:ok, _} = Region.replace_item(handle, ItemStack.new("egg", 3))
    writer = :sys.get_state(ctx.pid).resource.store

    Store.snapshot(
      writer,
      :sys.get_state(ctx.pid).resource.store_lease,
      %{},
      {self(), elem(ctx.owner, 1)},
      51
    )

    assert_receive {:resource, _, {:saved, ^writer, 51, :ok}}
    owner = replace_owner(ctx, :shutdown)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, request)
    assert map_size(World.item_snapshot(ctx.key)) == 1
    assert [entry] = Map.values(:sys.get_state(elem(owner, 0)).resource.items.entries)
    assert entry.stack == ItemStack.new("egg", 3)
  end

  test "a stalled transfer publishes neither items nor receipts before its acknowledgment", ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    request = transfer(ctx)

    try do
      task = Task.async(fn -> Region.apply_item_transfer(ctx.owner, request) end)
      pending = wait_pending(ctx.pid)
      assert Task.yield(task, 10) == nil
      assert World.item_snapshot(ctx.key) == %{}
      # A duplicate and a receipt query would be destination proof: both wait for
      # the original write to become durable.
      duplicate = Task.async(fn -> Region.apply_item_transfer(ctx.owner, request) end)
      proof = Task.async(fn -> Region.item_transfer_receipt(ctx.owner, request.source) end)
      assert Task.yield(duplicate, 50) == nil and Task.yield(proof, 10) == nil
      send_resource(ctx, {:items_saved, self(), pending.token, :ok})
      assert Task.yield(duplicate, 10) == nil
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task)
      assert {:ok, :already_applied} = Task.await(duplicate)
      assert {:ok, {_, %{sequence: 1}}} = Task.await(proof)
      assert :sys.get_state(ctx.pid).resource.item_receipts[request.source].sequence == 1
      :sys.suspend(writer)
      assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, request)
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "physical transfer commit with a withheld reply recovers one item and its receipt", ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    request = transfer(ctx)
    task = Task.async(fn -> Region.apply_item_transfer(ctx.owner, request) end)
    wait_pending(ctx.pid)
    :sys.suspend(ctx.pid)
    :sys.resume(writer)
    assert {:ok, %{records: records, receipts: receipts}} = Store.load_items(writer)
    assert records == request.records and receipts[request.source].sequence == 1
    owner = replace_owner(ctx, :shutdown)
    assert {:error, :item_commit_uncertain} = Task.await(task)
    assert {:ok, :already_applied} = Region.apply_item_transfer(owner, request)
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "writer loss before transfer commit leaves neither records nor receipts", ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    request = transfer(ctx)
    task = Task.async(fn -> Region.apply_item_transfer(ctx.owner, request) end)
    wait_pending(ctx.pid)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      Process.exit(writer, :kill)
      assert {:error, :item_commit_uncertain} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, _, {:store_failed, :killed}}, 1500
    end)

    {:ok, owner} = World.item_owner(ctx.key)
    assert :sys.get_state(elem(owner, 0)).resource.item_receipts == %{}
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, :applied} = Region.apply_item_transfer(owner, request)
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  # Install a controlled blocked pure job so failure/deadline delivery is deterministic.
  # No proposal has been sent to the disk writer at this boundary.
  defp blocked_plan(ctx) do
    {:ok, worker} =
      Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
        receive do
          :finish -> :ok
        end
      end)

    caller =
      Task.async(fn ->
        receive do
          {:plan_reply, result} -> result
        end
      end)

    token = make_ref()

    :sys.replace_state(ctx.pid, fn state ->
      pending = %{
        phase: :planning,
        worker: worker,
        monitor: Process.monitor(worker),
        token: token,
        from: {caller.pid, :plan_reply},
        timer:
          Process.send_after(
            self(),
            {:resource, elem(ctx.owner, 1), {:item_commit_deadline, token}},
            5000
          )
      }

      %{state | resource: %{state.resource | item_pending: pending}}
    end)

    {worker, caller, token}
  end

  test "pure worker loss clears admission and stale results cannot create an item", ctx do
    {worker, caller, token} = blocked_plan(ctx)
    {x, _, z} = ctx.position
    assert :ok = World.set_block({floor(x), 64, floor(z)}, 1)
    assert {:error, :item_storage_busy} = Region.apply_item_transfer(ctx.owner, transfer(ctx))
    Process.exit(worker, :kill)
    assert {:error, :item_plan_failed} = Task.await(caller)
    refute Valimc.TestRegion.writing?(:sys.get_state(ctx.pid).resource)

    result =
      Valimc.World.ItemTransfers.plan(Valimc.World.Items.new(), %{}, ctx.key, transfer(ctx))

    send_resource(ctx, {:item_transfer_plan, worker, token, result})
    assert :sys.get_state(ctx.pid).resource.item_receipts == %{}
    assert World.item_snapshot(ctx.key) == %{}
    assert Valimc.TestDisk.read(ctx.base, ctx.key, :items) == nil
    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, transfer(ctx))
  end

  test "planning deadline fences the owner and terminates its bounded CPU job", ctx do
    {worker, caller, token} = blocked_plan(ctx)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      send_resource(ctx, {:item_commit_deadline, token})
      assert {:error, :item_commit_uncertain} = Task.await(caller)
      assert_receive {:DOWN, ^ref, :process, _, :item_storage_timeout}, 1500
    end)

    refute Process.alive?(worker)
    {:ok, owner} = World.item_owner(ctx.key)
    assert :sys.get_state(elem(owner, 0)).resource.item_receipts == %{}
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, :applied} = Region.apply_item_transfer(owner, transfer(ctx))
  end
end

defmodule Valimc.ItemStoreTest.Serial do
  use ExUnit.Case, async: false
  # Serial: saturates a global worker pool that concurrent owners also use.
  import Valimc.ItemStoreTest, only: [transfer: 1]
  alias Valimc.World
  alias Valimc.World.Region

  setup {Valimc.ItemStoreTest, :scope}

  test "saturated CPU workers reject without queuing or changing authoritative state", ctx do
    workers =
      for _ <- 1..System.schedulers_online() do
        {:ok, worker} =
          Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
            receive do
              :finish -> :ok
            end
          end)

        worker
      end

    try do
      assert {:error, :item_workers_busy} = Region.apply_item_transfer(ctx.owner, transfer(ctx))
      refute Valimc.TestRegion.writing?(:sys.get_state(ctx.pid).resource)
      assert World.item_snapshot(ctx.key) == %{}
      assert Valimc.TestDisk.read(ctx.base, ctx.key, :items) == nil
      {x, _, z} = ctx.position
      assert :ok = World.set_block({floor(x), 64, floor(z)}, 1)
    after
      for worker <- workers, do: Task.Supervisor.terminate_child(Valimc.ItemWorkers, worker)
    end

    assert {:ok, :applied} = Region.apply_item_transfer(ctx.owner, transfer(ctx))
  end
end
