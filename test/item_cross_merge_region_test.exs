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

  defp wait(fun, tries \\ 600) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert tries > 0
        Process.sleep(5)
        wait(fun, tries - 1)
    end
  end

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

  test "recipient admission waits for durable capacity and refuses expired completion", c do
    writer = state(c.target).store
    :sys.suspend(writer)

    try do
      task = Task.async(fn -> grant(c) end)
      wait(fn -> Valimc.TestRegion.in_flight?(state(c.target)) end)
      assert disk(c, c.destination).ledger.incoming == %{}
      assert state(c.target).permits.entries == %{}
      Process.sleep(260)
      :sys.resume(writer)
      assert {:error, :expired_item_step} = Task.await(task, 2000)
      assert disk(c, c.destination).ledger.incoming[c.key].sequence == 0
      assert disk(c, c.key).ledger.sequence == 6 and disk(c, c.key).records == [c.donor]
      assert {:ok, _} = grant(c)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
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
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1500
      end)

      {:ok, owner} = World.item_owner(c.key)
      c = %{c | source: owner}
      Process.sleep(260)
      :sys.resume(writer)
      wait(fn -> finished(c) end)
      assert {:ok, {key, %{sequence: sequence}}} = Task.await(receipt)
      assert sequence > 0
      assert key == c.destination
      assert disk(c, c.key).records == [] and disk(c, c.key).ledger.outgoing == nil
      assert [%{stack: %{count: 5}}] = disk(c, c.destination).records
      assert {:ok, :already_applied} = Region.apply_item_merge(c.target, request)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "lost recipient permission rejects safely, returns a newer donor and permits a fresh retry",
       c do
    assert {:ok, request} = grant(c)
    {pid, _} = c.target
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, target} = World.item_owner(c.destination)
    c = %{c | target: target}
    assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
    wait(fn -> finished(c) end)
    assert disk(c, c.key).records == [c.donor]
    assert disk(c, c.key).ledger.generations[c.donor.uuid] == 3
    assert disk(c, c.destination).records == [c.recipient]

    assert {:ok, :rejected} =
             ItemMergeTransfer.receipt_result(
               request,
               disk(c, c.destination).ledger.incoming[c.key]
             )

    assert {:ok, retry} = grant(c)
    assert retry.sequence == 8 and retry.donor_generation == 3
    assert {:ok, :prepared} = Region.prepare_item_merge(c.source, retry)
    wait(fn -> finished(c) and disk(c, c.key).records == [] end)
    assert [%{stack: %{count: 5}}] = disk(c, c.destination).records
    assert disk(c, c.key).ledger.sequence == 8
  end

  test "expired contact and stale epochs never authorize a recipient gain", c do
    assert {:ok, request} = grant(c)
    Process.sleep(260)
    assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
    wait(fn -> finished(c) end)
    assert disk(c, c.key).records == [c.donor] and disk(c, c.destination).records == [c.recipient]
    {pid, _} = c.target
    assert {:error, :stale_region} = Region.reserve_item_merge({pid, make_ref()}, proposal(c))
    assert {:error, :stale_region} = Region.apply_item_merge({pid, make_ref()}, request)
  end

  test "source authority refreshes movement and counters before pinning the durable request", c do
    assert {:ok, request} = grant(c)
    {:ok, {_, id, revision}} = Items.find(state(c.source).items, c.donor.uuid)

    step = %{
      id: id,
      revision: revision,
      position: {c.donor.x + 0.05, c.donor.y, c.donor.z},
      motion: %{c.donor.motion | age: 31}
    }

    assert {:ok, [_]} = Region.advance_items(c.source, [step])
    writer = state(c.target).store
    :sys.suspend(writer)

    try do
      assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
      fresh = disk(c, c.key).ledger.outgoing.request
      assert fresh.donor.x == c.donor.x + 0.05 and fresh.donor.motion.age == 31
      :sys.resume(writer)
      wait(fn -> finished(c) end)
      proof = disk(c, c.destination).ledger.incoming[c.key]
      assert {:ok, :applied} = ItemMergeTransfer.receipt_result(fresh, proof)

      assert {:error, :item_merge_receipt_conflict} =
               ItemMergeTransfer.receipt_result(request, proof)

      assert [%{motion: %{age: 31}, stack: %{count: 5}}] = disk(c, c.destination).records
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "moving the source out of contact after a grant cannot withdraw its item", c do
    assert {:ok, request} = grant(c)
    {:ok, {_, id, revision}} = Items.find(state(c.source).items, c.donor.uuid)

    step = %{
      id: id,
      revision: revision,
      position: {c.donor.x - 3.0, c.donor.y, c.donor.z},
      motion: c.donor.motion
    }

    assert {:ok, [_]} = Region.advance_items(c.source, [step])
    assert {:error, :item_merge_not_prepared} = Region.prepare_item_merge(c.source, request)
    assert disk(c, c.key).ledger.sequence == 6 and disk(c, c.key).ledger.outgoing == nil
    assert disk(c, c.destination).records == [c.recipient]
  end

  test "failed donor fsync never publishes withdrawal or starts delivery", c do
    assert {:ok, request} = grant(c)
    writer = state(c.source).store
    Valimc.TestDisk.break_writer(writer)
    {pid, _} = c.source
    monitor = Process.monitor(pid)

    capture_log(fn ->
      assert {:error, :item_commit_uncertain} = Region.prepare_item_merge(c.source, request)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    end)

    assert disk(c, c.key).records == [c.donor] and disk(c, c.key).ledger.sequence == 6
    assert disk(c, c.destination).records == [c.recipient]
    assert disk(c, c.destination).ledger.incoming[c.key].sequence == 0
    assert {:ok, recovered} = World.item_owner(c.key)
    assert Items.records(state(recovered).items) == [c.donor]
  end

  test "failed recipient fsync recovers its reservation and returns the donor through typed rejection",
       c do
    assert {:ok, request} = grant(c)
    writer = state(c.target).store
    Valimc.TestDisk.break_writer(writer)
    {pid, _} = c.target
    monitor = Process.monitor(pid)

    capture_log(fn ->
      assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
      wait(fn -> finished(c) end)
    end)

    assert disk(c, c.key).records == [c.donor]
    assert disk(c, c.key).ledger.generations[c.donor.uuid] == 3
    assert disk(c, c.destination).records == [c.recipient]

    assert {:ok, :rejected} =
             ItemMergeTransfer.receipt_result(
               request,
               disk(c, c.destination).ledger.incoming[c.key]
             )

    assert disk(c, c.key).receipts == c.births and disk(c, c.destination).receipts == c.births
  end

  test "counter-only native effects keep both entity identities and use coalesced persistence",
       c do
    c = custom_counter_fixture(c)

    assert {:ok, proposal, fence} =
             Region.item_merge_donor(c.source, c.donor.uuid, c.recipient.uuid)

    assert World.item_observation_current?(fence)
    assert {:ok, request} = Region.reserve_item_merge(c.target, proposal)
    before = state(c.target)
    writer = before.store
    :sys.suspend(writer)

    try do
      assert {:ok, :applied} = Region.apply_item_merge_counters(c.target, request, fence)
      after_effect = state(c.target)
      assert after_effect.items.ledger == before.items.ledger
      assert Map.keys(after_effect.items.entries) == Map.keys(before.items.entries)
      assert [%{stack: %{count: 64}, motion: motion}] = Items.records(after_effect.items)
      assert motion.age == 30 and motion.pickup_delay == 10
      assert after_effect.item_motion_generation > after_effect.item_saved_generation
      assert disk(c, c.destination).records == [c.recipient]
      assert disk(c, c.key).records == [c.donor] and disk(c, c.key).ledger.sequence == 6
      assert state(c.source).items.ledger.outgoing == nil

      assert {:error, :item_merge_not_available} =
               Region.apply_item_merge_counters(c.target, request, fence)

      :sys.resume(writer)
      {pid, _} = c.target
      assert :ok = Region.flush(pid)

      assert [%{stack: %{count: 64}, motion: %{age: 30, pickup_delay: 10}}] =
               disk(c, c.destination).records

      assert disk(c, c.destination).ledger.incoming[c.key].sequence == 0
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp custom_counter_fixture(c) do
    stack = %{ItemStack.new("stone", 2) | components: %{"minecraft:max_stack_size" => 99}}
    donor = %{c.donor | stack: stack}
    recipient = %{c.recipient | stack: %{stack | count: 64}}

    for {owner, record} <- [{c.source, donor}, {c.target, recipient}] do
      {:ok, {epoch, id, revision}} = Items.find(state(owner).items, record.uuid)
      {pid, ^epoch} = owner
      assert {:ok, _} = Region.replace_item({pid, epoch, id, revision}, record.stack)
    end

    %{c | donor: donor, recipient: recipient}
  end

  test "source publication invalidates prior owner authority after motion or expiry", c do
    c = custom_counter_fixture(c)

    assert {:ok, proposal, fence} =
             Region.item_merge_donor(c.source, c.donor.uuid, c.recipient.uuid)

    assert {:ok, request} = Region.reserve_item_merge(c.target, proposal)
    {:ok, {_, id, revision}} = Items.find(state(c.source).items, c.donor.uuid)

    step = %{
      id: id,
      revision: revision,
      position: {c.donor.x - 3.0, c.donor.y, c.donor.z},
      motion: c.donor.motion
    }

    assert {:ok, [handle]} = Region.advance_items(c.source, [step])
    refute World.item_observation_current?(fence)

    assert {:error, :item_merge_not_available} =
             Region.apply_item_merge_counters(c.target, request, fence)

    assert disk(c, c.destination).records == [c.recipient]

    {_, _, id, revision} = handle

    assert {:ok, [_]} =
             Region.advance_items(c.source, [
               %{step | id: id, revision: revision, position: {c.donor.x, c.donor.y, c.donor.z}}
             ])

    assert {:ok, proposal, expired} =
             Region.item_merge_donor(c.source, c.donor.uuid, c.recipient.uuid)

    Process.sleep(260)
    assert {:ok, request} = Region.reserve_item_merge(c.target, proposal)
    refute World.item_observation_current?(expired)

    assert {:error, :item_merge_not_available} =
             Region.apply_item_merge_counters(c.target, request, expired)

    assert disk(c, c.destination).records == [c.recipient]
  end

  test "sub-packet motion and return cannot revive an old source authorization", c do
    c = custom_counter_fixture(c)
    assert {:ok, _, fence} = Region.item_merge_donor(c.source, c.donor.uuid, c.recipient.uuid)
    {:ok, {_, id, revision}} = Items.find(state(c.source).items, c.donor.uuid)
    before = state(c.source).items.views[id]

    step = %{
      id: id,
      revision: revision,
      position: {c.donor.x, c.donor.y, c.donor.z},
      motion: %{c.donor.motion | velocity: {1.0e-12, 0.0, 0.0}}
    }

    assert {:ok, [_]} = Region.advance_items(c.source, [step])
    next = state(c.source).items.views[id]
    assert next.motion_revision == before.motion_revision
    refute World.item_observation_current?(fence)

    assert {:ok, [_]} =
             Region.advance_items(c.source, [
               %{step | revision: next.revision, motion: c.donor.motion}
             ])

    refute World.item_observation_current?(fence)
  end

  test "recipient handoff after admission rejects the old merge and returns only its donor", c do
    third_key = {elem(c.destination, 0) + 1, elem(c.destination, 1)}
    {:ok, third} = World.item_owner(third_key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, third_key),
          do: TestScope.kill(pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, third_key),
          do: TestScope.kill(pid)
    end)

    assert {:ok, request} = grant(c)
    {:ok, {_, id, revision}} = Items.find(state(c.target).items, c.recipient.uuid)

    step = %{
      id: id,
      revision: revision,
      position: {elem(third_key, 0) * 128 + 0.5, c.recipient.y, c.recipient.z},
      motion: c.recipient.motion
    }

    assert {:ok, 1} = Region.handoff_items(c.target, third_key, [step])

    wait(fn ->
      state(c.target).items.ledger.outgoing == nil and
        not Valimc.TestRegion.writing?(state(c.target))
    end)

    assert {:ok, :prepared} = Region.prepare_item_merge(c.source, request)
    wait(fn -> finished(c) end)
    assert [%{uuid: uuid, stack: %{count: 3}}] = Items.records(state(third).items)
    assert uuid == c.recipient.uuid
    assert Items.records(state(c.source).items) == [c.donor]
    assert state(c.source).items.ledger.generations[c.donor.uuid] == 3
    assert Items.records(state(c.target).items) == []

    assert {:ok, :rejected} =
             ItemMergeTransfer.receipt_result(
               request,
               disk(c, c.destination).ledger.incoming[c.key]
             )

    assert disk(c, c.key).receipts == c.births and disk(c, c.destination).receipts == c.births
  end
end
