defmodule Valimc.PlacementRegionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.World

  alias Valimc.World.{
    ItemRecords,
    MiningTransfers,
    PlacementPermits,
    PlacementTransfers,
    Region,
    Store
  }

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-placement-region-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {20_000 + rem(nonce, 10_000), 700}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 64, rz * span}
    other = {rx * span + 1, 64, rz * span}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, reservation} = Region.reserve_placement(owner, observed.revision, observed.blocks)

    transfer =
      Map.merge(reservation, %{source: <<nonce::128>>, sequence: 1, edits: %{position => 1}})

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, live)

      Application.put_env(:valimc, :world_path, previous)
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

  defp reserve(owner, positions) do
    {:ok, observed} = Region.observe_blocks(owner, positions)
    Region.reserve_placement(owner, observed.revision, observed.blocks)
  end

  defp writing(pid, attempts \\ 200)
  defp writing(_, 0), do: flunk("placement did not reach bounded writing phase")

  defp writing(pid, attempts) do
    case :sys.get_state(pid).resource.item_pending do
      %{kind: :placement, phase: :writing} = pending ->
        pending

      _ ->
        Process.sleep(1)
        writing(pid, attempts - 1)
    end
  end

  defp receipt(ctx, owner, request, outcome) do
    assert {:ok, {key, receipt}} = Region.item_transfer_receipt(owner, request.source)
    assert key == ctx.key
    assert {:ok, ^outcome} = PlacementTransfers.receipt_result(key, request, receipt)
    receipt
  end

  test "block and receipt remain unpublished until the atomic writer completes; replay preserves replacements",
       ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_placement_transfer(ctx.owner, ctx.transfer) end)

    try do
      pending = writing(ctx.pid)
      assert World.get_block(ctx.position) == 0

      assert {:error, :missing_transfer_receipt} =
               Region.item_transfer_receipt(ctx.owner, ctx.transfer.source)

      assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
      assert {:error, :mining_storage_busy} = World.set_block(ctx.other, 1)
      assert {:error, :mining_storage_busy} = Region.flush(ctx.pid)
      send(ctx.pid, {:resource, ctx.epoch, :save})
      send(ctx.pid, {:resource, ctx.epoch, {:items_saved, writer, pending.token, :ok}})
      send(ctx.pid, {:resource, make_ref(), {:mining_saved, writer, pending.token, :ok}})
      send(ctx.pid, {:resource, ctx.epoch, {:mining_saved, writer, make_ref(), :ok}})
      assert {:ok, _} = Region.observe_blocks(ctx.owner, [])
      assert Task.yield(task, 10) == nil
      :sys.resume(writer)
      assert {:ok, :applied} = Task.await(task)
      assert World.get_block(ctx.position) == 1
      receipt(ctx, ctx.owner, ctx.transfer, :applied)
      assert World.item_snapshot(ctx.key) == %{}
      assert :ok = World.set_block(ctx.position, 10)
      assert {:ok, :already_applied} = Region.apply_placement_transfer(ctx.owner, ctx.transfer)
      assert World.get_block(ctx.position) == 10
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "unrelated edits preserve permits; target ABA, release and changed context reject durably",
       ctx do
    assert :ok = World.set_block(ctx.other, 1)
    assert {:ok, :applied} = Region.apply_placement_transfer(ctx.owner, ctx.transfer)
    {:ok, reserved} = reserve(ctx.owner, [ctx.other])

    request =
      Map.merge(ctx.transfer, reserved) |> Map.merge(%{sequence: 2, edits: %{ctx.other => 10}})

    assert :ok = World.set_block(ctx.other, 10)
    assert :ok = World.set_block(ctx.other, 1)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    assert {:ok, :already_rejected} = Region.apply_placement_transfer(ctx.owner, request)
    assert World.get_block(ctx.other) == 1
    receipt(ctx, ctx.owner, request, :rejected)
    {:ok, released} = reserve(ctx.owner, [ctx.other])
    assert :ok = Region.release_placement(ctx.owner, released.permit)
    request = Map.merge(request, released) |> Map.put(:sequence, 3)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    {:ok, observed} = Region.observe_blocks(ctx.owner, [ctx.other])

    assert {:error, :placement_context_changed} =
             Region.reserve_placement(ctx.owner, observed.revision, %{ctx.other => 0})

    assert :ok = World.set_block(ctx.position, 10)

    assert {:error, :stale_revision} =
             Region.reserve_placement(ctx.owner, observed.revision, observed.blocks)
  end

  test "concurrent owners of source stacks cannot both replace the same reserved block", ctx do
    {:ok, reserved} = reserve(ctx.owner, [ctx.position])
    second = Map.merge(ctx.transfer, reserved) |> Map.put(:source, <<999::128>>)

    tasks =
      for request <- [ctx.transfer, second],
          do: Task.async(fn -> Region.apply_placement_transfer(ctx.owner, request) end)

    results =
      for {task, request} <- Enum.zip(tasks, [ctx.transfer, second]) do
        case Task.await(task) do
          {:error, :item_storage_busy} -> Region.apply_placement_transfer(ctx.owner, request)
          result -> result
        end
      end

    assert Enum.sort(results) == [{:ok, :applied}, {:ok, :rejected}]
    assert World.get_block(ctx.position) == 1
    assert map_size(:sys.get_state(ctx.pid).resource.item_receipts) == 2
  end

  test "the owner rechecks both context cells after planning", ctx do
    {:ok, reserved} = reserve(ctx.owner, [ctx.position, ctx.other])
    request = Map.merge(ctx.transfer, reserved)
    resource = :sys.get_state(ctx.pid).resource
    token = make_ref()
    caller = Task.async(fn -> receive do: ({:plan_reply, result} -> result) end)

    {:ok, worker} =
      Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
        receive do: (:continue -> :ok)

        {:ok, plan} =
          PlacementTransfers.plan(resource.items, resource.item_receipts, ctx.key, request, true)

        {:ok, batch} = Valimc.World.BlockBatch.prepare(request.edits)

        send(
          ctx.pid,
          {:resource, ctx.epoch,
           {:block_transfer_plan, self(), token,
            {:ok, Map.merge(plan, %{kind: :placement, batch: batch})}}}
        )
      end)

    :sys.replace_state(ctx.pid, fn state ->
      pending = %{
        kind: :placement,
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

    assert :ok = World.set_block(ctx.other, 1)
    assert :ok = World.set_block(ctx.other, 0)
    send(worker, :continue)
    assert {:ok, :rejected} = Task.await(caller)
    assert World.get_block(ctx.position) == 0
    receipt(ctx, ctx.owner, request, :rejected)
  end

  test "restart rejects old authority; committed rejection and placement survive subsequent restarts",
       ctx do
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    {:ok, {pid, _} = owner} = World.item_owner(ctx.key)

    assert {:error, :stale_region} =
             Region.apply_placement_transfer({pid, ctx.epoch}, ctx.transfer)

    assert {:ok, :rejected} = Region.apply_placement_transfer(owner, ctx.transfer)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_rejected} = Region.apply_placement_transfer(owner, ctx.transfer)
    {:ok, reserved} = reserve(owner, [ctx.position])
    request = Map.merge(ctx.transfer, reserved) |> Map.put(:sequence, 2)
    assert {:ok, :applied} = Region.apply_placement_transfer(owner, request)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0))
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_placement_transfer(owner, request)
    assert World.get_block(ctx.position) == 1
    receipt(ctx, owner, request, :applied)
  end

  test "writer failure recovers block plus receipt and leaves preexisting item records exact",
       ctx do
    {x, y, z} = ctx.position

    {:ok, _} =
      Region.create_item(
        ctx.owner,
        Valimc.Protocol.ItemStack.new("dirt", 3),
        {x + 0.5, y + 0.5, z + 0.5}
      )

    records = Valimc.World.Items.records(:sys.get_state(ctx.pid).resource.items)
    path = Store.item_path(ctx.base, ctx.key)
    File.rm!(path)
    File.mkdir!(path)
    monitor = Process.monitor(ctx.pid)

    capture_log(fn ->
      assert {:error, :mining_commit_uncertain} =
               Region.apply_placement_transfer(ctx.owner, ctx.transfer)

      assert_receive {:DOWN, ^monitor, :process, _, _}, 1000
    end)

    assert File.regular?(Store.mining_path(ctx.base, ctx.key))
    File.rmdir!(path)
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_placement_transfer(owner, ctx.transfer)
    assert World.get_block(ctx.position) == 1
    receipt(ctx, owner, ctx.transfer, :applied)
    assert records == Valimc.World.Items.records(:sys.get_state(elem(owner, 0)).resource.items)
  end

  test "dirty graceful shutdown cannot overwrite the queued atomic placement", ctx do
    assert :ok = World.set_block(ctx.other, 10)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.apply_placement_transfer(ctx.owner, ctx.transfer) end)

    try do
      writing(ctx.pid)

      stop =
        Task.async(fn -> DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid) end)

      assert {:error, :item_commit_uncertain} = Task.await(task)
      :sys.resume(writer)
      assert :ok = Task.await(stop)
      {:ok, owner} = World.item_owner(ctx.key)
      assert {:ok, :already_applied} = Region.apply_placement_transfer(owner, ctx.transfer)
      assert World.get_block(ctx.position) == 1 and World.get_block(ctx.other) == 10
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "mining permits, receipt hashes and malformed requests cannot authorize placement", ctx do
    {:ok, mining} = Region.reserve_mining(ctx.owner, [ctx.position])
    request = Map.merge(ctx.transfer, mining)
    assert {:ok, :rejected} = Region.apply_placement_transfer(ctx.owner, request)
    actual = receipt(ctx, ctx.owner, request, :rejected)

    assert {:error, :transfer_conflict} =
             MiningTransfers.receipt_result(
               ctx.key,
               request |> Map.delete(:edits) |> Map.put(:records, []),
               actual
             )

    assert {:error, :transfer_conflict} = Region.apply_placement_transfer(ctx.owner, ctx.transfer)

    assert {:error, :invalid_placement_request} =
             Region.apply_placement_transfer(ctx.owner, %{ctx.transfer | sequence: 0})

    assert {:error, :invalid_placement_reservation} = Region.reserve_placement(ctx.owner, 0, %{})

    assert {:error, :stale_owner} =
             Region.release_placement({ctx.pid, make_ref()}, ctx.transfer.permit)

    assert World.get_block(ctx.position) == 0
  end

  test "receipt capacity admits existing sources only and binds every request field", ctx do
    receipts =
      Map.new(1..ItemRecords.max_sources(), &{<<&1::128>>, %{sequence: 1, digest: <<0::256>>}})

    request = %{ctx.transfer | source: <<0::128>>}

    assert {:error, :transfer_source_limit} =
             PlacementTransfers.plan(:unchanged, receipts, ctx.key, request, true)

    {:ok, plan} = PlacementTransfers.plan(:unchanged, %{}, ctx.key, request, true)
    refute plan.receipts[request.source].digest == plan.digest

    for altered <- [
          %{request | edits: %{ctx.position => 10}},
          %{request | permit: <<99::128>>},
          %{request | expected: %{ctx.position => 10}}
        ] do
      assert {:error, :transfer_conflict} =
               PlacementTransfers.plan(:unchanged, plan.receipts, ctx.key, altered, true)
    end

    assert {:ok, %{result: :already_applied}} =
             PlacementTransfers.plan(:unchanged, plan.receipts, ctx.key, request, false)

    assert {:error, :stale_transfer} =
             PlacementTransfers.plan(
               :unchanged,
               %{request.source => %{sequence: 2, digest: <<0::256>>}},
               ctx.key,
               request,
               true
             )
  end

  test "placement fences bound capacity and expire without revival" do
    blocks = %{{0, 64, 0} => 0}
    {:ok, first, token} = PlacementPermits.reserve(%PlacementPermits{}, blocks, 0)
    assert {:ok, ^blocks} = PlacementPermits.lookup(first, token, 9999)
    assert {:error, :stale_placement_permit} = PlacementPermits.lookup(first, token, 10_000)

    full =
      Enum.reduce(1..127, first, fn _, permits ->
        {:ok, next, _} = PlacementPermits.reserve(permits, blocks, 0)
        next
      end)

    assert {:error, :placement_permit_limit} = PlacementPermits.reserve(full, blocks, 1)
    assert {:ok, fresh, _} = PlacementPermits.reserve(full, blocks, 10_000)
    assert map_size(fresh.entries) == 1
    assert {:error, :stale_placement_permit} = PlacementPermits.lookup(fresh, token, 10_000)
  end
end
