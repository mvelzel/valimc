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
    key = {20_000 + rem(nonce, 3_333) * 3, 400}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    other = {rx * span + 1, 63, rz * span}
    {:ok, {pid, epoch} = owner} = World.item_owner(key)
    assert :ok = Valimc.TestBlocks.set(position, Data.block("stone"))
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

      File.rm_rf(base)
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

  defp writing(pid, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource)
      end)

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
      assert {:ok, :applied} = Task.await(task, 60_000)
      assert Valimc.TestBlocks.get(ctx.position) == 0
      assert map_size(World.item_snapshot(ctx.key)) == 1
      assert {:ok, {_, receipt}} = Region.item_transfer_receipt(ctx.owner, ctx.transfer.source)
      assert {:ok, :applied} = MiningTransfers.receipt_result(ctx.key, ctx.transfer, receipt)
      # A retry cannot break a replacement block after its permit was consumed.
      assert :ok = Valimc.TestBlocks.set(ctx.position, 1)
      assert {:ok, :already_applied} = Region.apply_mining_transfer(ctx.owner, ctx.transfer)
      assert Valimc.TestBlocks.get(ctx.position) == 1
      assert map_size(World.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "unrelated edits preserve permits but a changed-and-restored target durably rejects its old intent",
       ctx do
    assert :ok = Valimc.TestBlocks.set(ctx.other, 1)
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

    assert :ok = Valimc.TestBlocks.set(ctx.other, 1)
    assert {:ok, :rejected} = Region.apply_mining_transfer(ctx.owner, transfer)
    assert {:ok, :already_rejected} = Region.apply_mining_transfer(ctx.owner, transfer)
    assert Valimc.TestBlocks.get(ctx.other) == 1
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
    assert Valimc.TestBlocks.get(ctx.position) == 0
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "a restarted owner rejects an uncommitted old permit; a committed receipt survives restart",
       ctx do
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert {:error, :stale_region} = Region.apply_mining_transfer({pid, ctx.epoch}, ctx.transfer)
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, ctx.transfer)
    assert Valimc.TestBlocks.get(ctx.position) == 1
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
    assert Valimc.TestBlocks.get(ctx.position) == 0
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "real writer failure commits neither block nor receipt and rejects the stale retry", ctx do
    before = Valimc.TestBlocks.get(ctx.position)
    writer = :sys.get_state(ctx.pid).resource.store
    Valimc.TestDisk.break_writer(writer)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      assert {:error, :mining_commit_uncertain} =
               Region.apply_mining_transfer(ctx.owner, ctx.transfer)

      assert_receive {:DOWN, ^ref, :process, _, _}
    end)

    Valimc.TestDisk.await_exit(writer)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert Valimc.TestBlocks.get(ctx.position) == before and World.item_snapshot(ctx.key) == %{}
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, ctx.transfer)
    assert Valimc.TestBlocks.get(ctx.position) == before and World.item_snapshot(ctx.key) == %{}
  end

  test "no-drop mining still commits a block and receipt; invalid inbox data is inert", ctx do
    request = %{ctx.transfer | records: []}
    assert {:ok, :applied} = Region.apply_mining_transfer(ctx.owner, request)
    assert Valimc.TestBlocks.get(ctx.position) == 0
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, :already_applied} = Region.apply_mining_transfer(ctx.owner, request)

    assert {:error, :invalid_mining_transfer} =
             Region.apply_mining_transfer(ctx.owner, %{request | sequence: 0})

    assert {:error, :invalid_mining_reservation} = Region.reserve_mining(ctx.owner, [])
    assert {:error, :wrong_region} = Region.reserve_mining(ctx.owner, [{0, 63, 0}])
  end
end
