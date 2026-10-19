defmodule Valimc.MiningRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  import ExUnit.CaptureLog
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World
  alias Valimc.World.{MiningTransfers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-region-#{nonce}")
    key = {20_000 + rem(nonce, 10_000), 400}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    other = {rx * span + 1, 63, rz * span}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)
    assert :ok = World.set_block(position, Data.block("stone"))
    assert :ok = Region.flush(pid)
    {:ok, reservation} = Region.reserve_mining(owner, [position])
    {x, _, z} = position

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: 63.5,
      z: z + 0.5,
      stack: ItemStack.new("cobblestone")
    }

    transfer =
      Map.merge(reservation, %{
        source: :crypto.strong_rand_bytes(16),
        sequence: 1,
        records: [record]
      })

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      pid: pid,
      epoch: epoch,
      owner: owner,
      position: position,
      other: other,
      transfer: transfer
    }
  end

  defp writing(pid, attempts \\ 200)
  defp writing(_, 0), do: flunk("mining did not reach bounded writing phase")

  defp writing(pid, attempts) do
    case Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource) do
      %{} = pending ->
        pending

      _ ->
        Process.sleep(1)
        writing(pid, attempts - 1)
    end
  end

  test "pending write publishes neither blocks nor drops, ignores foreign completions and retries exactly once",
       ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_mining_transfer(ctx.owner, ctx.transfer) end)

    try do
      pending = writing(ctx.pid)
      # Adopted in owner memory; readers and clients see nothing before durability.
      assert Valimc.TestRegion.published_block(ctx.owner, ctx.position) == Data.block("stone")
      assert World.item_snapshot(ctx.key) == %{}
      assert {:ok, _} = Region.observe_blocks(ctx.owner, [ctx.position])
      assert {:error, :item_storage_busy} = Region.flush(ctx.pid)
      send(ctx.pid, {:resource, ctx.epoch, :save})
      send(ctx.pid, {:resource, ctx.epoch, {:items_saved, writer, pending.token, :ok}})
      send(ctx.pid, {:mining_saved, writer, pending.token, :ok})
      send(ctx.pid, {:resource, make_ref(), {:mining_saved, writer, pending.token, :ok}})
      send(ctx.pid, {:resource, ctx.epoch, {:mining_saved, writer, make_ref(), :ok}})
      assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
      assert Valimc.TestRegion.write_token(:sys.get_state(ctx.pid).resource) == pending.token
      assert Task.yield(task, 10) == nil
      assert World.item_snapshot(ctx.key) == %{}
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task)
      assert World.get_block(ctx.position) == 0
      assert map_size(World.item_snapshot(ctx.key)) == 1
      assert {:ok, {_, receipt}} = Region.item_transfer_receipt(ctx.owner, ctx.transfer.source)
      assert {:ok, :applied} = MiningTransfers.receipt_result(ctx.key, ctx.transfer, receipt)
      # A retry cannot break a replacement block after its permit was consumed.
      assert :ok = World.set_block(ctx.position, 1)
      assert {:ok, :already_applied} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
      assert World.get_block(ctx.position) == 1
      assert map_size(World.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "a raw edit behind a queued mining write reaches subscribers after the mined block", ctx do
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_mining_transfer(ctx.owner, ctx.transfer) end)

    try do
      writing(ctx.pid)
      assert :ok = World.set_block(ctx.position, 1)
      refute_receive {:event, {:block, _, _}}, 20
      refute_received {:event, {:block_batch, _}}
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task)
      assert_receive {:event, {:block_batch, _}}
      assert_receive {:event, {:block, position, 1}}
      assert position == ctx.position and World.get_block(ctx.position) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "unrelated edits preserve permits but a changed-and-restored target durably rejects its old intent",
       ctx do
    assert :ok = World.set_block(ctx.other, 1)
    assert {:ok, :applied} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
    {:ok, reservation} = Region.reserve_mining(ctx.owner, [ctx.other])
    transfer = Map.merge(ctx.transfer, reservation) |> Map.put(:sequence, 2)

    transfer = %{
      transfer
      | records: [Map.put(hd(transfer.records), :uuid, :crypto.strong_rand_bytes(16))]
    }

    assert {:ok, observation} = Region.observe_blocks(ctx.owner, [ctx.other])

    assert {:ok, _} =
             Region.set_blocks(ctx.owner, observation.revision, %{ctx.other => Data.block("dirt")})

    assert :ok = World.set_block(ctx.other, 1)
    assert {:ok, :rejected} = Region.apply_mining_transfer(ctx.owner, transfer)
    assert {:ok, :already_rejected} = Region.apply_mining_transfer(ctx.owner, transfer)
    assert World.get_block(ctx.other) == 1
    assert map_size(World.item_snapshot(ctx.key)) == 1
    assert {:ok, {_, receipt}} = Region.item_transfer_receipt(ctx.owner, transfer.source)
    assert {:ok, :rejected} = MiningTransfers.receipt_result(ctx.key, transfer, receipt)
    {:ok, replacement} = Region.reserve_mining(ctx.owner, [ctx.other])

    assert {:error, :transfer_conflict} =
             Region.apply_mining_transfer(ctx.owner, Map.merge(transfer, replacement))

    assert {:error, :stale_transfer} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
  end

  test "competing miners get one block/drop outcome and a conserved rejection", ctx do
    {:ok, reservation} = Region.reserve_mining(ctx.owner, [ctx.position])

    second =
      Map.merge(ctx.transfer, reservation) |> Map.put(:source, :crypto.strong_rand_bytes(16))

    second = %{
      second
      | records: [Map.put(hd(second.records), :uuid, :crypto.strong_rand_bytes(16))]
    }

    tasks =
      for request <- [ctx.transfer, second],
          do: Task.async(fn -> Region.apply_mining_transfer(ctx.owner, request) end)

    initial = Enum.map(tasks, &Task.await/1)

    results =
      for {result, request} <- Enum.zip(initial, [ctx.transfer, second]) do
        case result do
          {:error, :item_storage_busy} -> Region.apply_mining_transfer(ctx.owner, request)
          result -> result
        end
      end

    assert Enum.sort(results) == [{:ok, :applied}, {:ok, :rejected}]
    assert World.get_block(ctx.position) == 0
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "target mutation during pure planning rejects a previously eligible candidate", ctx do
    parent = self()
    token = make_ref()
    resource = :sys.get_state(ctx.pid).resource
    caller = Task.async(fn -> receive do: ({:plan_reply, result} -> result) end)

    {:ok, worker} =
      Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
        receive do: (:continue -> :ok)

        {:ok, plan} =
          MiningTransfers.plan(
            resource.items,
            resource.item_receipts,
            ctx.key,
            ctx.transfer,
            true
          )

        {:ok, batch} = Valimc.World.BlockBatch.prepare(%{ctx.position => 0})

        send(
          ctx.pid,
          {:resource, ctx.epoch,
           {:block_transfer_plan, self(), token,
            {:ok, Map.merge(plan, %{batch: batch, kind: :mining})}}}
        )

        send(parent, :planning_finished)
      end)

    :sys.replace_state(ctx.pid, fn state ->
      pending = %{
        kind: :mining,
        phase: :planning,
        token: token,
        from: {caller.pid, :plan_reply},
        worker: worker,
        monitor: Process.monitor(worker),
        timer:
          Process.send_after(self(), {:resource, ctx.epoch, {:item_commit_deadline, token}}, 5000)
      }

      %{state | resource: %{state.resource | item_pending: pending}}
    end)

    assert :ok = World.set_block(ctx.position, Data.block("dirt"))
    assert :ok = World.set_block(ctx.position, 1)
    send(worker, :continue)
    assert {:ok, :rejected} = Task.await(caller)
    assert_receive :planning_finished
    assert World.get_block(ctx.position) == 1
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, {_, receipt}} = Region.item_transfer_receipt(ctx.owner, ctx.transfer.source)
    assert {:ok, :rejected} = MiningTransfers.receipt_result(ctx.key, ctx.transfer, receipt)
  end

  test "a restarted owner rejects an uncommitted old permit; a committed receipt survives restart",
       ctx do
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert {:error, :stale_region} = Region.apply_mining_transfer({pid, ctx.epoch}, ctx.transfer)
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, ctx.transfer)
    assert World.get_block(ctx.position) == 1
    assert World.item_snapshot(ctx.key) == %{}
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_rejected} = Region.apply_mining_transfer(owner, ctx.transfer)
    {:ok, reservation} = Region.reserve_mining(owner, [ctx.position])
    transfer = Map.merge(ctx.transfer, reservation) |> Map.put(:sequence, 2)
    assert {:ok, :applied} = Region.apply_mining_transfer(owner, transfer)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0))
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, transfer)
    assert World.get_block(ctx.position) == 0
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "graceful shutdown cannot flush the old dirty snapshot over a queued mining commit", ctx do
    assert :ok = World.set_block(ctx.other, Data.block("dirt"))
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_mining_transfer(ctx.owner, ctx.transfer) end)

    stop =
      try do
        writing(ctx.pid)

        stop =
          Task.async(fn ->
            DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
          end)

        assert {:error, :mining_commit_uncertain} = Task.await(task)
        :sys.resume(writer)
        assert :ok = Task.await(stop)
        stop
      after
        if Process.alive?(writer), do: :sys.resume(writer)
        Task.shutdown(task, :brutal_kill)
      end

    Task.shutdown(stop, :brutal_kill)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, ctx.transfer)
    assert World.get_block(ctx.position) == 0
    assert World.get_block(ctx.other) == Data.block("dirt")
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "real writer failure commits neither block nor receipt and rejects the stale retry", ctx do
    before = World.get_block(ctx.position)
    writer = :sys.get_state(ctx.pid).resource.store
    Valimc.TestDisk.break_writer(writer)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      assert {:error, :mining_commit_uncertain} =
               Region.apply_mining_transfer(ctx.owner, ctx.transfer)

      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    end)

    Valimc.TestDisk.await_exit(writer)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert World.get_block(ctx.position) == before and World.item_snapshot(ctx.key) == %{}
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, ctx.transfer)
    assert World.get_block(ctx.position) == before and World.item_snapshot(ctx.key) == %{}
  end

  test "no-drop mining still commits a block and receipt; invalid inbox data is inert", ctx do
    request = %{ctx.transfer | records: []}
    assert {:ok, :applied} = Region.apply_mining_transfer(ctx.owner, request)
    assert World.get_block(ctx.position) == 0
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, :already_applied} = Region.apply_mining_transfer(ctx.owner, request)

    assert {:error, :invalid_mining_transfer} =
             Region.apply_mining_transfer(ctx.owner, %{request | sequence: 0})

    assert {:error, :invalid_mining_reservation} = Region.reserve_mining(ctx.owner, [])
    assert {:error, :wrong_region} = Region.reserve_mining(ctx.owner, [{0, 63, 0}])
  end

  test "renewal and release preserve owner, target and committed receipt fencing", ctx do
    token = ctx.transfer.permit
    expected = ctx.transfer.expected
    assert :ok = World.set_block(ctx.other, Data.block("dirt"))
    assert {:ok, ^expected} = Region.renew_mining(ctx.owner, token)
    stale = {ctx.pid, make_ref()}
    assert {:error, :stale_owner} = Region.renew_mining(stale, token)
    assert {:error, :stale_owner} = Region.release_mining(stale, token)
    assert {:ok, :applied} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
    assert :ok = Region.release_mining(ctx.owner, token)
    assert {:ok, :already_applied} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
    assert map_size(World.item_snapshot(ctx.key)) == 1

    {:ok, released} = Region.reserve_mining(ctx.owner, [ctx.other])
    assert :ok = Region.release_mining(ctx.owner, released.permit)
    assert :ok = Region.release_mining(ctx.owner, released.permit)
    assert {:error, :stale_mining_permit} = Region.renew_mining(ctx.owner, released.permit)

    request =
      Map.merge(released, %{source: :crypto.strong_rand_bytes(16), sequence: 1, records: []})

    assert {:ok, :rejected} = Region.apply_mining_transfer(ctx.owner, request)
    assert World.get_block(ctx.other) == Data.block("dirt")
    {:ok, aba} = Region.reserve_mining(ctx.owner, [ctx.other])
    assert :ok = World.set_block(ctx.other, Data.block("dirt"))
    assert {:error, :stale_mining_permit} = Region.renew_mining(ctx.owner, aba.permit)
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "waterlogged removal survives a failed writer and recovers its water and exact drop",
       ctx do
    assert :ok = World.set_block(ctx.position, 15179)
    assert :ok = Region.flush(ctx.pid)
    assert {:ok, permit} = Region.reserve_mining(ctx.owner, [ctx.position])
    request = Map.merge(ctx.transfer, permit)
    writer = :sys.get_state(ctx.pid).resource.store
    Valimc.TestDisk.break_writer(writer)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      assert {:error, :mining_commit_uncertain} = Region.apply_mining_transfer(ctx.owner, request)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    end)

    Valimc.TestDisk.await_exit(writer)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert World.get_block(ctx.position) == 15179 and World.item_snapshot(ctx.key) == %{}
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, request)
    assert {:ok, permit} = Region.reserve_mining(owner, [ctx.position])
    request = Map.merge(%{ctx.transfer | source: :crypto.strong_rand_bytes(16)}, permit)
    assert {:ok, :applied} = Region.apply_mining_transfer(owner, request)
    {pid, _} = owner
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, request)
    assert World.get_block(ctx.position) == 89
    assert map_size(World.item_snapshot(ctx.key)) == 1
    assert :ok = World.set_block(ctx.position, Data.block("dirt"))
    assert {:ok, :already_applied} = Region.apply_mining_transfer(owner, request)
    assert World.get_block(ctx.position) == Data.block("dirt")
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end
end
