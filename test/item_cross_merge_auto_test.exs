defmodule Valimc.ItemCrossMergeAutoTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{EntityHandoffs, Entities, Region}

  setup do
    n = System.unique_integer([:positive])
    key = {72000 + rem(n, 3333) * 3, 2300}
    target_key = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-cross-auto-#{n}")
    File.mkdir_p!(base)
    TestScope.isolate(TestScope.neighborhood(key, 2), world_path: base)

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
             Entities.records(state(c.target).entities.store)

    assert uuid == c.recipient.uuid and motion.age < 90
    assert disk(c, c.key).records == [] and disk(c, c.key).ledger.sequence == 1
    assert disk(c, c.target_key).ledger.incoming[c.key].sequence == 1
    {pid, _} = c.target
    assert :ok = Region.flush(pid)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, restarted} = Valimc.TestWorld.item_owner(c.target_key)

    assert [%{uuid: ^uuid, stack: %{count: 5}}] =
             Entities.records(state(restarted).entities.store)
  end

  test "a donor whose target is gone is rejected and comes back with its network id", c do
    {:ok, source} = Entities.restore(c.key, [c.donor])
    {:ok, {epoch, id, revision}} = Entities.find(source, c.donor.uuid)

    assert {:ok, departed, transfer} =
             EntityHandoffs.depart_merge(
               source,
               c.key,
               epoch,
               {id, revision},
               c.target_key,
               <<1::128>>
             )

    assert departed.entries == %{} and transfer.merge == <<1::128>>
    assert {:ok, digest} = EntityHandoffs.digest(transfer)
    {:ok, target} = Entities.restore(c.target_key, [c.recipient])
    assert {:ok, target, :rejected} = EntityHandoffs.accept(target, c.target_key, transfer)

    assert {:ok, ^target, :already_rejected} =
             EntityHandoffs.accept(target, c.target_key, transfer)

    assert Entities.records(target) ==
             Entities.records(elem(Entities.restore(c.target_key, [c.recipient]), 1))

    assert {:ok, back} =
             EntityHandoffs.finish(departed, c.key, transfer.sequence, digest, :rejected)

    assert back.ledger.outgoing == nil
    assert {:ok, {_, ^id, _}} = Entities.find(back, c.donor.uuid)
  end
end
