defmodule Valimc.ItemCrossMergeRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  import ExUnit.CaptureLog
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, ItemMergeTransfer, Items, Region}

  setup do
    n = System.unique_integer([:positive])
    key = {51000 + rem(n, 3333) * 3, 1300}
    destination = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-cross-merge-#{n}")
    File.mkdir_p!(base)
    TestScope.isolate(TestScope.neighborhood(key, 2), world_path: base)

    donor = %{
      uuid: <<n::64, 1::64>>,
      x: elem(key, 0) * 128 + 127.9,
      y: 64.0,
      z: elem(key, 1) * 128 + 8.5,
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{age: 30, pickup_delay: 10, no_gravity: true}
    }

    recipient = %{
      donor
      | uuid: <<n::64, 2::64>>,
        x: donor.x + 0.2,
        stack: ItemStack.new("stone", 3),
        motion: %{donor.motion | age: 100, pickup_delay: 2}
    }

    births = %{<<n::64, 3::64>> => %{sequence: 4, digest: <<5::256>>}}

    for {key, record, ledger} <- [
          {key, donor, %ItemLedger{sequence: 6, generations: %{donor.uuid => 2}}},
          {destination, recipient, %ItemLedger{generations: %{recipient.uuid => 4}}}
        ] do
      {:ok, bytes} = ItemLedger.encode(key, [record], births, ledger)
      Valimc.TestDisk.write(base, key, :items, bytes)
    end

    {:ok, source_owner} = World.item_owner(key)
    {:ok, dest_owner} = World.item_owner(destination)

    on_exit(fn ->
      for k <- [key, destination] do
        for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k) do
          writer = Valimc.TestConn.state(pid).resource.store
          if Process.alive?(writer), do: :sys.resume(writer)
          TestScope.kill(pid)
        end

        for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, k),
            do: TestScope.kill(pid)
      end

      File.rm_rf(base)
    end)

    %{
      key: key,
      destination: destination,
      source: source_owner,
      target: dest_owner,
      donor: donor,
      recipient: recipient,
      base: base,
      births: births
    }
  end

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp disk(c, key) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, key, :items), key)
    saved
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp proposal(c) do
    s = state(c.source)
    donor = Enum.find(Items.records(s.items), &(&1.uuid == c.donor.uuid))

    %{
      source: c.key,
      sequence: s.items.ledger.sequence + 1,
      donor: donor,
      donor_generation: Map.get(s.items.ledger.generations, c.donor.uuid, 0),
      recipient_uuid: c.recipient.uuid
    }
  end

  defp grant(c), do: Region.reserve_item_merge(c.target, proposal(c))

  defp finished(c) do
    s = state(c.source)

    s.items.ledger.sequence >= 7 and s.items.ledger.outgoing == nil and
      not Valimc.TestRegion.writing?(s)
  end

  test "actual admission, donor journal, destination proof and automatic source clear conserve items",
       c do
    assert {:ok, request} = grant(c)
    assert disk(c, c.destination).ledger.incoming[c.key] == %{sequence: 0, digest: <<0::256>>}
    assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
    wait(fn -> finished(c) end)
    assert disk(c, c.key).records == []
    assert [%{uuid: uuid, stack: %{count: 5}}] = disk(c, c.destination).records
    assert uuid == c.recipient.uuid

    assert {:ok, :applied} =
             ItemMergeTransfer.receipt_result(
               request,
               disk(c, c.destination).ledger.incoming[c.key]
             )

    assert {:ok, :already_applied} = Region.apply_item_merge(c.target, request)
    assert disk(c, c.key).receipts == c.births and disk(c, c.destination).receipts == c.births
  end

  test "a paused destination exposes no gain before ack; committed source survives restart and replay",
       c do
    assert {:ok, request} = grant(c)
    writer = state(c.target).store
    :sys.suspend(writer)

    try do
      assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
      wait(fn -> Valimc.TestRegion.in_flight?(state(c.target)) end)
      assert disk(c, c.key).records == [] and disk(c, c.key).ledger.outgoing.request == request
      assert disk(c, c.destination).records == [c.recipient]
      # The receipt is destination proof: it is answered only once durable.
      receipt = Task.async(fn -> Region.owner_item_receipt(c.target, c.key) end)
      assert Task.yield(receipt, 20) == nil
      {pid, _} = c.source
      monitor = Process.monitor(pid)

      capture_log(fn ->
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      end)

      {:ok, owner} = World.item_owner(c.key)
      c = %{c | source: owner}
      Process.sleep(260)
      :sys.resume(writer)
      wait(fn -> finished(c) end)
      assert {:ok, {key, %{sequence: sequence}}} = Task.await(receipt, 60_000)
      assert sequence > 0
      assert key == c.destination
      wait(fn -> disk(c, c.key).records == [] and disk(c, c.key).ledger.outgoing == nil end)
      assert [%{stack: %{count: 5}}] = disk(c, c.destination).records
      assert {:ok, :already_applied} = Region.apply_item_merge(c.target, request)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end
end
