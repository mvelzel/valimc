defmodule Valimc.ItemLedgerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemLedger, Region}

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
end
