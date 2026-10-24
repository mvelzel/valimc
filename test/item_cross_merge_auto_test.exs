defmodule Valimc.ItemCrossMergeAutoTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Entity.{Handoffs, Store}
  alias Valimc.World.Region

  setup tags do
    n = System.unique_integer([:positive])
    key = {72000 + rem(n, 3333) * 3, 2300}
    target_key = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-cross-auto-#{n}")
    File.mkdir_p!(base)
    # Separate groups: the merge crosses by the durable handoff (inside one
    # group it is local, `region_group_test.exs`).
    TestScope.isolate(TestScope.neighborhood(key, 2),
      world_path: base,
      regionizer: false,
      region_ticks: if(tags[:manual], do: :manual, else: :timer)
    )

    donor = %{
      uuid: <<n::64, 1::64>>,
      x: (elem(key, 0) + 1) * 128 - 0.1,
      y: 68.0,
      z: elem(key, 1) * 128 + 7.5,
      kind: :item,
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{age: 30, pickup_delay: 15, no_gravity: true}
    }

    recipient = %{
      donor
      | uuid: <<n::64, 257::64>>,
        x: donor.x + 0.2,
        stack: ItemStack.new("stone", 3),
        motion: %{donor.motion | age: 100, pickup_delay: 0}
    }

    for {k, records} <- [{key, [donor]}, {target_key, [recipient]}],
        do: Valimc.TestDisk.write(base, k, :items, %{records: records})

    {:ok, source} = Valimc.TestWorld.item_owner(key)
    {:ok, target} = Valimc.TestWorld.item_owner(target_key)

    on_exit(fn ->
      for x <- (elem(key, 0) - 1)..(elem(key, 0) + 2),
          z <- (elem(key, 1) - 1)..(elem(key, 1) + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end)

    %{
      key: key,
      target_key: target_key,
      source: source,
      target: target,
      donor: donor,
      recipient: recipient,
      base: base
    }
  end

  defp state(owner), do: Valimc.TestRegion.section(owner)
  defp section(key), do: Valimc.TestWorld.section(key)

  defp start(c) do
    for owner <- [c.source, c.target] do
      Valimc.TestScope.simulate(owner, state(owner).key)
      Valimc.TestRegion.replace_section(owner, &put_in(&1.entities.simulate, true))
    end
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp idle(c),
    do:
      Enum.all?([c.source, c.target], fn owner ->
        s = state(owner)

        s.entities.store.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s)
      end)

  defp total(c),
    do:
      Enum.sum(
        for o <- [c.source, c.target],
            {_, e} <- state(o).entities.store.entries,
            do: e.stack.count
      )

  defp converged(c), do: map_size(state(c.source).entities.store.entries) == 0 and idle(c)

  defp disk(c, k), do: Valimc.TestDisk.read(c.base, k, :items)

  test "a border item is handed over and merged on arrival, durably", c do
    start(c)
    wait(fn -> converged(c) end)
    assert total(c) == 5

    assert [%{uuid: uuid, stack: %{count: 5}, motion: motion}] =
             Store.records(state(c.target).entities.store)

    assert uuid == c.recipient.uuid and motion.age < 90
    assert disk(c, c.key).records == [] and disk(c, c.key).ledger.sequence == 1
    assert disk(c, c.target_key).ledger.incoming[section(c.key)].sequence == 1
    {pid, _} = c.target
    assert :ok = Region.flush(pid)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, restarted} = Valimc.TestWorld.item_owner(c.target_key)

    assert [%{uuid: ^uuid, stack: %{count: 5}}] =
             Store.records(state(restarted).entities.store)
  end

  @tag manual: true
  test "a merge started during the tick keeps its copied store until adoption", c do
    start(c)
    parent = self()

    Valimc.TestRegion.replace_section(c.source, fn s ->
      next =
        Valimc.World.RegionData.item_tick(
          %{s | game_tick: s.game_tick + 1},
          System.monotonic_time(:millisecond)
        )

      job = Valimc.World.Jobs.get(next.jobs, :plan)
      send(parent, {:merge_copy, job.data.kind, job.data.base_store == next.entities.store})
      next
    end)

    assert_receive {:merge_copy, :item_merge_out, unchanged}
    assert unchanged

    wait(fn ->
      for owner <- [c.source, c.target], do: Region.step(owner, 1)
      converged(c)
    end)

    assert total(c) == 5
    assert disk(c, c.key).records == []
    assert disk(c, c.target_key).ledger.incoming[section(c.key)].sequence == 1
  end

  test "a donor whose target is gone is rejected and comes back with its network id", c do
    {:ok, source} = Store.restore(c.key, [c.donor])
    {:ok, {epoch, id, revision}} = Store.find(source, c.donor.uuid)

    assert {:ok, departed, transfer} =
             Handoffs.depart_merge(
               source,
               section(c.key),
               epoch,
               {id, revision},
               section(c.target_key),
               <<1::128>>
             )

    assert departed.entries == %{} and transfer.merge == <<1::128>>
    assert {:ok, digest} = Handoffs.digest(transfer)
    {:ok, target} = Store.restore(c.target_key, [c.recipient])

    assert {:ok, target, :rejected} =
             Handoffs.accept(target, section(c.target_key), transfer)

    assert {:ok, ^target, :already_rejected} =
             Handoffs.accept(target, section(c.target_key), transfer)

    assert Store.records(target) ==
             Store.records(elem(Store.restore(c.target_key, [c.recipient]), 1))

    assert {:ok, back} =
             Handoffs.finish(departed, section(c.key), transfer.sequence, digest, :rejected)

    assert back.ledger.outgoing == nil
    assert {:ok, {_, ^id, _}} = Store.find(back, c.donor.uuid)
  end
end
