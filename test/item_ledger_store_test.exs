defmodule Valimc.ItemLedgerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World
  alias Valimc.World.{ItemLedger, Items, Region, Store}

  setup tags do
    nonce = System.unique_integer([:positive])
    key = {20_000 + rem(nonce, 3_333) * 3, 600}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    base = Path.join(System.tmp_dir!(), "valimc-item-ledger-#{nonce}")
    TestScope.isolate(TestScope.neighborhood(key), world_path: base)
    File.mkdir_p!(base)

    record = %{
      uuid: <<1::128>>,
      x: rx * span + 0.5,
      y: 64.5,
      z: rz * span + 0.5,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{velocity: {0.1, -0.04, 0.0}, pickup_delay: 40}
    }

    outgoing = %{record | uuid: <<2::128>>, x: (rx + 1) * span + 0.5}

    ledger = %ItemLedger{
      sequence: 9,
      outgoing: %{
        destination: {rx + 1, rz},
        records: [outgoing],
        generations: %{outgoing.uuid => 6}
      },
      incoming: %{{rx - 1, rz} => %{sequence: 7, digest: <<77::256>>}},
      generations: %{record.uuid => 4}
    }

    receipts = %{<<71::128>> => %{sequence: 3, digest: <<33::256>>}}

    receipts =
      if Map.get(tags, :receipt_reservation, false),
        do: Map.put(receipts, <<72::128>>, %{sequence: 0, digest: <<0::256>>}),
        else: receipts

    {:ok, bytes} = ItemLedger.encode(key, [record], receipts, ledger)
    Valimc.TestDisk.write(base, key, :items, bytes)
    # Keep the outgoing intent pending while exercising unrelated save paths.
    destination = {rx + 1, rz}
    occupied = for n <- 1..256, do: %{outgoing | uuid: <<1000 + n::128>>}
    {:ok, full} = ItemLedger.encode(destination, occupied, %{})
    Valimc.TestDisk.write(base, destination, :items, full)

    on_exit(fn ->
      for region <- [key, destination],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, region),
          do: TestScope.kill(pid)

      for region <- [key, destination],
          {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, region),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, base: base, record: record, ledger: ledger, receipts: receipts}
  end

  defp disk(ctx) do
    assert {:ok, snapshot} =
             ItemLedger.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)

    assert snapshot.ledger == ctx.ledger
    assert snapshot.receipts == ctx.receipts
    snapshot
  end

  defp restart(pid, key, reason) do
    monitor = Process.monitor(pid)

    if reason == :kill,
      do: Process.exit(pid, :kill),
      else: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:ok, owner} = World.item_owner(key)
    owner
  end

  @tag receipt_reservation: true
  test "reserved source capacity survives critical writes and owner recovery before a first transfer",
       ctx do
    {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert Valimc.TestConn.state(pid).resource.item_receipts == ctx.receipts
    {:ok, handle} = Region.find_item(owner, ctx.record.uuid)
    assert {:ok, _} = Region.replace_item(handle, %{ctx.record.stack | count: 4})
    assert hd(disk(ctx).records).stack.count == 4
    owner = restart(pid, ctx.key, :kill)
    assert :sys.get_state(elem(owner, 0)).resource.item_receipts == ctx.receipts
    born = %{ctx.record | uuid: <<3::128>>}

    assert {:ok, :applied} =
             Region.apply_item_transfer(owner, %{
               source: <<72::128>>,
               sequence: 1,
               records: [born]
             })

    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)
    assert saved.receipts[<<72::128>>].sequence == 1
    assert saved.receipts[<<71::128>>] == ctx.receipts[<<71::128>>]
    assert saved.ledger == ctx.ledger
  end

  test "ordinary motion, critical edits and owner replacement retain every ledger component",
       ctx do
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert {:ok, {_, epoch, id, revision} = handle} = Region.find_item(owner, ctx.record.uuid)
    assert World.item_snapshot(ctx.key)[id].ownership_generation == 4
    assert Valimc.TestConn.state(pid).resource.items.ledger == ctx.ledger

    step = %{
      id: id,
      revision: revision,
      position: {ctx.record.x + 1, 65.0, ctx.record.z},
      motion: %{ctx.record.motion | age: 20}
    }

    assert {:ok, [{^pid, ^epoch, ^id, 2}]} = Region.publish_item_motion(owner, [step])
    assert {:ok, replaced} = Region.replace_item(put_elem(handle, 3, 2), ItemStack.new("egg", 3))
    assert :ok = Region.flush(pid)
    assert [%{x: x, stack: stack, motion: %{age: 20}}] = disk(ctx).records
    assert x == ctx.record.x + 1 and stack == ItemStack.new("egg", 3)

    for reason <- [:kill, :shutdown], reduce: {owner, replaced} do
      {{live, _}, _} ->
        next = restart(live, ctx.key, reason)
        assert {:ok, current} = Region.find_item(next, ctx.record.uuid)
        assert World.item_snapshot(ctx.key)[elem(current, 2)].ownership_generation == 4
        assert :sys.get_state(elem(next, 0)).resource.items.ledger == ctx.ledger
        assert disk(ctx).records |> hd() |> Map.get(:stack) == stack
        {next, current}
    end
  end

  test "removal retires only the owned hop and retains outgoing intent and both receipt kinds",
       ctx do
    assert {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert {:ok, handle} = Region.find_item(owner, ctx.record.uuid)
    assert :ok = Region.remove_item(handle)
    expected = %{ctx.ledger | generations: %{}}
    assert disk(%{ctx | ledger: expected}).records == []
    next = restart(pid, ctx.key, :kill)
    assert {:error, :missing_item} = Region.find_item(next, ctx.record.uuid)
    assert :sys.get_state(elem(next, 0)).resource.items.ledger == expected
  end

  test "periodic snapshots retain pending delivery metadata without a forced flush", ctx do
    assert {:ok, {pid, epoch} = owner} = World.item_owner(ctx.key)
    assert {:ok, {_, _, id, revision}} = Region.find_item(owner, ctx.record.uuid)

    step = %{
      id: id,
      revision: revision,
      position: {ctx.record.x + 1, 65.0, ctx.record.z},
      motion: %{ctx.record.motion | age: 5}
    }

    assert {:ok, _} = Region.publish_item_motion(owner, [step])
    timer = Valimc.TestConn.state(pid).resource.item_checkpoint_timer
    send(pid, {:resource, epoch, {:item_checkpoint, timer.token}})
    assert {:ok, _} = Region.observe_blocks(owner, [])
    state = Valimc.TestConn.state(pid).resource
    assert {:ok, %{ledger: ledger}} = Store.load_items(state.store)
    assert ledger == ctx.ledger
    assert [%{motion: %{age: 5}}] = disk(ctx).records
  end

  test "atomic block proposals preserve handoff state before acknowledgement", ctx do
    assert {:ok, writer, lease} = Store.open(ctx.key)
    assert {:ok, items} = Items.restore(ctx.key, [ctx.record], ctx.ledger)
    {x, z} = {floor(ctx.record.x), floor(ctx.record.z)}
    edits = %{{x, 64, z} => Data.block("dirt")}
    epoch = make_ref()
    token = make_ref()
    proposal = %{items: items, receipts: ctx.receipts, edits: edits, changes: edits}
    Store.commit_mining(writer, lease, proposal, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:mining_saved, ^writer, ^token, :ok}}
    assert disk(ctx).records == [ctx.record]
    assert Store.load(writer) == edits
    assert :ok = Store.close(writer, lease)
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert {:ok, %{ledger: ledger}} = Store.load_items(writer)
    assert ledger == ctx.ledger
  end
end
