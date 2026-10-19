defmodule Valimc.ItemHandoffRegionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemLedger, ItemRecords, Items, Region}

  setup tags do
    nonce = System.unique_integer([:positive])
    key = {31_000 + rem(nonce, 10_000), 700}
    destination = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-handoff-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    File.mkdir_p!(base)
    count = Map.get(tags, :population, 1)

    records = fn region, first ->
      {rx, rz} = region

      for n <- first..(first + count - 1),
          do: %{
            uuid: <<n::128>>,
            x: rx * 128 + 127.5,
            y: 64.25,
            z: rz * 128 + 0.5,
            stack: ItemStack.new("stone", 3),
            motion: %ItemMotionState{no_gravity: true}
          }
    end

    receipts = %{<<99::128>> => %{sequence: 1, digest: <<99::256>>}}
    source_records = records.(key, 1)
    destination_records = if count == 1, do: [], else: records.(destination, 1000)
    {:ok, bytes} = ItemRecords.encode(key, source_records, receipts)
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, bytes} = ItemRecords.encode(destination, destination_records)
    Valimc.TestDisk.write(base, destination, :items, bytes)
    {:ok, owner} = World.item_owner(key)
    {:ok, other} = World.item_owner(destination)

    on_exit(fn ->
      for region <- [key, destination],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, region) do
        :sys.resume(pid)
        resource = Valimc.TestConn.state(pid).resource
        if Process.alive?(resource.store), do: :sys.resume(resource.store)
        DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      for region <- [key, destination],
          {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, region),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      key: key,
      destination: destination,
      base: base,
      owner: owner,
      other: other,
      uuid: <<1::128>>,
      receipts: receipts,
      record: hd(source_records)
    }
  end

  defp resource({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp wait(fun, remaining \\ 600) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert remaining > 0
        Process.sleep(5)
        wait(fun, remaining - 1)
    end
  end

  defp steps(owner, destination, uuids) do
    state = resource(owner)
    {rx, rz} = destination

    Enum.map(uuids, fn uuid ->
      {:ok, {epoch, id, revision}} = Items.find(state.items, uuid)
      assert epoch == elem(owner, 1)

      %{
        id: id,
        revision: revision,
        position: {rx * 128 + 0.5, 64.25, rz * 128 + 0.5},
        motion: %ItemMotionState{velocity: {0.1, 0.0, 0.0}, age: 2, no_gravity: true}
      }
    end)
  end

  defp complete(owner),
    do:
      wait(fn ->
        s = resource(owner)
        s.items.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s)
      end)

  # Durably present in that owner's region (what a restart or any reader would see).
  defp published({pid, _}, uuid) do
    [key] = Registry.keys(Valimc.RegionRegistry, pid)

    {:ok, saved} =
      ItemLedger.decode(Valimc.TestDisk.read(Valimc.config(:world_path), key, :items), key)

    Enum.any?(saved.records, &(&1.uuid == uuid))
  end

  defp disk(ctx, key) do
    assert {:ok, snapshot} = ItemLedger.decode(Valimc.TestDisk.read(ctx.base, key, :items), key)
    snapshot
  end

  defp replace_owner(owner, key) do
    {pid, _} = owner
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1500
    assert {:ok, next} = World.item_owner(key)
    next
  end

  test "both directions and owner recovery conserve one item and leave original player receipts",
       ctx do
    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    complete(ctx.owner)
    refute published(ctx.owner, ctx.uuid)
    assert published(ctx.other, ctx.uuid)
    assert disk(ctx, ctx.key).receipts == ctx.receipts
    assert disk(ctx, ctx.destination).receipts == %{}
    assert disk(ctx, ctx.destination).ledger.generations == %{ctx.uuid => 1}
    receipt = ctx.receipts[<<99::128>>]
    # The existing player receipt still fences a retry after the item has left.
    assert {:ok, {key, ^receipt}} = Region.item_transfer_receipt(ctx.owner, <<99::128>>)
    assert key == ctx.key

    assert {:ok, 1} =
             Region.handoff_items(ctx.other, ctx.key, steps(ctx.other, ctx.key, [ctx.uuid]))

    complete(ctx.other)
    owner = replace_owner(ctx.owner, ctx.key)
    other = replace_owner(ctx.other, ctx.destination)
    assert published(owner, ctx.uuid) and not published(other, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.generations == %{ctx.uuid => 2}
    assert disk(ctx, ctx.destination).ledger.incoming[ctx.key].sequence == 1
    assert disk(ctx, ctx.key).receipts == ctx.receipts
  end

  test "withdrawal remains unpublished until source persistence while block work stays live",
       ctx do
    writer = resource(ctx.owner).store
    :sys.suspend(writer)

    task =
      Task.async(fn ->
        Region.handoff_items(
          ctx.owner,
          ctx.destination,
          steps(ctx.owner, ctx.destination, [ctx.uuid])
        )
      end)

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.owner)) end)
    assert Task.yield(task, 10) == nil
    assert published(ctx.owner, ctx.uuid) and not published(ctx.other, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.outgoing == nil
    assert :ok = World.set_block({floor(ctx.record.x), 64, floor(ctx.record.z)}, 1)
    :sys.resume(writer)
    assert {:ok, 1} = Task.await(task)
    complete(ctx.owner)
    assert published(ctx.other, ctx.uuid)
  end

  test "source crash with destination writing resumes the exact intent without holding other items",
       ctx do
    destination_writer = resource(ctx.other).store
    :sys.suspend(destination_writer)

    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.other)) end)
    before = disk(ctx, ctx.key)
    assert before.records == [] and before.ledger.sequence == 1
    refute published(ctx.owner, ctx.uuid) or published(ctx.other, ctx.uuid)

    assert {:ok, added} =
             Region.create_item(
               ctx.owner,
               ItemStack.new("egg", 2),
               {ctx.record.x - 1, 64.25, ctx.record.z}
             )

    owner = replace_owner(ctx.owner, ctx.key)
    assert disk(ctx, ctx.key).ledger.outgoing == before.ledger.outgoing
    assert map_size(resource(owner).items.entries) == 1
    :sys.resume(destination_writer)
    complete(owner)
    assert published(ctx.other, ctx.uuid)
    assert length(disk(ctx, ctx.key).records) == 1
    assert length(disk(ctx, ctx.destination).records) == 1
    assert {:error, :stale_region} = Region.remove_item(put_elem(added, 0, elem(owner, 0)))
  end

  test "crashes after destination receipt and before source acknowledgement cannot resurrect items",
       ctx do
    writer = resource(ctx.other).store
    :sys.suspend(writer)

    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.other)) end)
    :sys.suspend(elem(ctx.owner, 0))
    :sys.resume(writer)
    wait(fn -> published(ctx.other, ctx.uuid) end)
    assert disk(ctx, ctx.destination).ledger.incoming[ctx.key].sequence == 1
    assert disk(ctx, ctx.key).ledger.outgoing != nil
    other = replace_owner(ctx.other, ctx.destination)
    owner = replace_owner(ctx.owner, ctx.key)
    complete(owner)
    assert published(other, ctx.uuid) and not published(owner, ctx.uuid)
    assert length(disk(ctx, ctx.destination).records) == 1
    assert disk(ctx, ctx.key).ledger.sequence == 1
  end

  @tag population: 256
  test "full neighbors simultaneously exchange cohorts without a destination lock cycle", ctx do
    a_uuids = Enum.map(1..32, &<<&1::128>>)
    b_uuids = Enum.map(1000..1031, &<<&1::128>>)
    a_steps = steps(ctx.owner, ctx.destination, a_uuids)
    b_steps = steps(ctx.other, ctx.key, b_uuids)
    a = Task.async(fn -> Region.handoff_items(ctx.owner, ctx.destination, a_steps) end)
    b = Task.async(fn -> Region.handoff_items(ctx.other, ctx.key, b_steps) end)
    assert {:ok, 1} = Task.await(a)
    assert {:ok, 1} = Task.await(b)
    complete(ctx.owner)
    complete(ctx.other)
    records = disk(ctx, ctx.key).records ++ disk(ctx, ctx.destination).records
    assert length(records) == 512 and length(Enum.uniq_by(records, & &1.uuid)) == 512
    assert map_size(resource(ctx.owner).items.entries) == 256
    assert map_size(resource(ctx.other).items.entries) == 256
    assert Enum.all?(a_uuids, &published(ctx.other, &1))
    assert Enum.all?(b_uuids, &published(ctx.owner, &1))
  end

  test "a killed delivery worker and stale callbacks retain the committed sequence for retry",
       ctx do
    writer = resource(ctx.other).store
    :sys.suspend(writer)

    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.other)) end)
    job = resource(ctx.owner).item_handoff
    {pid, epoch} = ctx.owner

    for {tag, message} <- [
          {make_ref(), {:item_handoff_delivered, job.worker, job.token, {:ok, 1, <<0::256>>}}},
          {epoch, {:item_handoff_delivered, self(), job.token, {:ok, 1, <<0::256>>}}},
          {epoch, {:item_handoff_deadline, make_ref()}}
        ],
        do: send(pid, {:resource, tag, message})

    assert resource(ctx.owner).item_handoff == job
    Process.exit(job.worker, :kill)
    wait(fn -> resource(ctx.owner).item_handoff != job end)
    assert disk(ctx, ctx.key).ledger.sequence == 1
    assert disk(ctx, ctx.key).ledger.outgoing != nil
    :sys.resume(writer)
    complete(ctx.owner)
    assert length(disk(ctx, ctx.destination).records) == 1
    assert disk(ctx, ctx.destination).ledger.incoming[ctx.key].sequence == 1
  end

  test "failed source withdrawal never publishes or delivers an uncommitted item", ctx do
    writer = resource(ctx.owner).store
    Valimc.TestDisk.break_writer(writer)

    capture_log(fn ->
      assert {:error, :item_commit_uncertain} =
               Region.handoff_items(
                 ctx.owner,
                 ctx.destination,
                 steps(ctx.owner, ctx.destination, [ctx.uuid])
               )

      wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    end)

    refute published(ctx.other, ctx.uuid)
    Valimc.TestDisk.await_exit(writer)
    assert {:ok, owner} = World.item_owner(ctx.key)
    assert published(owner, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.sequence == 0
  end

  test "failed source clearance recovers from its intent and destination receipt", ctx do
    writer = resource(ctx.other).store
    :sys.suspend(writer)

    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.other)) end)
    source_writer = resource(ctx.owner).store
    Valimc.TestDisk.break_writer(source_writer)

    capture_log(fn ->
      :sys.resume(writer)
      wait(fn -> not Process.alive?(elem(ctx.owner, 0)) end)
    end)

    assert published(ctx.other, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.outgoing != nil
    Valimc.TestDisk.await_exit(source_writer)
    assert {:ok, owner} = World.item_owner(ctx.key)
    complete(owner)
    refute published(owner, ctx.uuid)
    assert length(disk(ctx, ctx.destination).records) == 1
  end

  test "expired, stale and oversized requests cannot prepare a withdrawal", ctx do
    {pid, epoch} = ctx.owner
    steps = steps(ctx.owner, ctx.destination, [ctx.uuid])

    assert {:error, :expired_item_step} =
             GenServer.call(
               pid,
               {:handoff_items, epoch, ctx.destination, steps,
                System.monotonic_time(:millisecond) - 1}
             )

    assert {:error, :stale_region} =
             Region.handoff_items({pid, make_ref()}, ctx.destination, steps)

    assert {:error, :invalid_item_steps} =
             Region.handoff_items(ctx.owner, ctx.destination, List.duplicate(hd(steps), 33))

    assert published(ctx.owner, ctx.uuid) and not published(ctx.other, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.sequence == 0
  end

  test "delivery deadline retries one pinned intent and clearance preserves later ordinary motion",
       ctx do
    writer = resource(ctx.other).store
    :sys.suspend(writer)

    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    wait(fn -> Valimc.TestRegion.in_flight?(resource(ctx.other)) end)
    job = resource(ctx.owner).item_handoff
    {pid, epoch} = ctx.owner
    monitor = Process.monitor(job.worker)
    send(pid, {:resource, epoch, {:item_handoff_deadline, job.token}})
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1000
    assert disk(ctx, ctx.key).ledger.sequence == 1

    assert {:ok, {_, _, id, revision}} =
             Region.create_item(
               ctx.owner,
               ItemStack.new("egg", 2),
               {ctx.record.x - 1, 64.25, ctx.record.z}
             )

    motion = %ItemMotionState{age: 17, velocity: {0.1, 0.0, 0.0}, no_gravity: true}

    assert {:ok, _} =
             Region.publish_item_motion(ctx.owner, [
               %{
                 id: id,
                 revision: revision,
                 position: {ctx.record.x - 2, 64.25, ctx.record.z},
                 motion: motion
               }
             ])

    :sys.resume(writer)
    complete(ctx.owner)
    assert [remaining] = disk(ctx, ctx.key).records
    assert remaining.stack == ItemStack.new("egg", 2) and remaining.motion == motion
    assert remaining.x == ctx.record.x - 2
    assert length(disk(ctx, ctx.destination).records) == 1
  end

  test "destination write failure leaves the source intent available for a fresh owner", ctx do
    writer = resource(ctx.other).store
    Valimc.TestDisk.break_writer(writer)

    capture_log(fn ->
      assert {:ok, 1} =
               Region.handoff_items(
                 ctx.owner,
                 ctx.destination,
                 steps(ctx.owner, ctx.destination, [ctx.uuid])
               )

      wait(fn -> not Process.alive?(elem(ctx.other, 0)) end)
      assert disk(ctx, ctx.key).ledger.outgoing != nil
      assert disk(ctx, ctx.destination).records == []
      Valimc.TestDisk.await_exit(writer)
      complete(ctx.owner)
    end)

    assert {:ok, other} = World.item_owner(ctx.destination)
    assert published(other, ctx.uuid) and not published(ctx.owner, ctx.uuid)
    assert length(disk(ctx, ctx.destination).records) == 1
  end
end
