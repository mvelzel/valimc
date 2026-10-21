defmodule Valimc.ItemCrossMergeAutoTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Items, Region}

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

    for {k, records} <- [{key, [donor]}, {target_key, [recipient]}] do
      {:ok, bytes} = ItemLedger.encode(k, records, %{}, %ItemLedger{})
      Valimc.TestDisk.write(base, k, :items, bytes)
    end

    {:ok, source} = World.item_owner(key)
    {:ok, target} = World.item_owner(target_key)

    on_exit(fn ->
      for x <- (elem(key, 0) - 1)..(elem(key, 0) + 2),
          z <- (elem(key, 1) - 1)..(elem(key, 1) + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end)

    %{
      key: key,
      target_key: target_key,
      source: source,
      target: target,
      recipient: recipient,
      base: base
    }
  end

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp start(c) do
    for {pid, _} = owner <- [c.source, c.target] do
      Valimc.TestScope.simulate(owner, state(owner).key)
      :sys.replace_state(pid, &%{&1 | resource: %{&1.resource | item_simulation_enabled: true}})
    end
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp idle(c),
    do:
      Enum.all?([c.source, c.target], fn owner ->
        s = state(owner)

        s.items.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s) and
          not Valimc.World.Jobs.running?(s.jobs, :cross_merge)
      end)

  defp total(c),
    do:
      Enum.sum(for o <- [c.source, c.target], {_, e} <- state(o).items.entries, do: e.stack.count)

  defp converged(c), do: map_size(state(c.source).items.entries) == 0 and idle(c)

  defp disk(c, k) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, k, :items), k)
    saved
  end

  test "automatic boundary discovery commits and recovers a merge without manual grants", c do
    start(c)
    wait(fn -> converged(c) end)
    assert total(c) == 5

    assert [%{uuid: uuid, stack: %{count: 5}, motion: motion}] =
             Items.records(state(c.target).items)

    assert uuid == c.recipient.uuid and motion.age < 90
    assert disk(c, c.key).records == [] and disk(c, c.key).ledger.sequence == 1
    assert disk(c, c.target_key).ledger.incoming[c.key].sequence == 1
    {pid, _} = c.target
    assert :ok = Region.flush(pid)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, restarted} = World.item_owner(c.target_key)
    assert [%{uuid: ^uuid, stack: %{count: 5}}] = Items.records(state(restarted).items)
  end
end
