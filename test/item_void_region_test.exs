defmodule Valimc.ItemVoidRegionTest do
  use ExUnit.Case, async: false
  # Serial: the fsync-wait assertion races a simulation tick that queued writes allow.
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.Region

  setup do
    n = System.unique_integer([:positive])
    key = {81000 + rem(n, 3333) * 3, 2400}
    base = Path.join(System.tmp_dir!(), "valimc-item-void-#{n}")
    File.mkdir_p!(base)
    TestScope.isolate(TestScope.neighborhood(key), world_path: base)
    motion = %ItemMotionState{age: -32768, pickup_delay: 32767, no_gravity: true}

    below = %{
      uuid: <<n::64, 1::64>>,
      x: elem(key, 0) * 128 + 8.5,
      y: -128.01,
      z: elem(key, 1) * 128 + 8.5,
      kind: :item,
      stack: ItemStack.new("stone", 7),
      motion: motion,
      hops: 3
    }

    boundary = %{below | uuid: <<n::64, 2::64>>, y: -128.0, hops: 4}
    receipts = %{<<n::64, 3::64>> => %{sequence: 11, digest: <<12::256>>}}

    ledger = %{
      sequence: 8,
      outgoing: nil,
      incoming: %{{elem(key, 0) - 1, elem(key, 1)} => %{sequence: 6, digest: <<7::256>>}}
    }

    data = %{records: [below, boundary], receipts: receipts, ledger: ledger}
    Valimc.TestDisk.write(base, key, :items, data)
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)

      Valimc.TestScope.stop_neighbourhood(key)

      File.rm_rf!(base)
    end)

    %{
      key: key,
      base: base,
      owner: owner,
      below: below,
      boundary: boundary,
      receipts: receipts,
      ledger: ledger
    }
  end

  defp state(owner), do: Valimc.TestRegion.section(owner)

  defp enable(owner) do
    Valimc.TestScope.simulate(owner, state(owner).key)
    Valimc.TestRegion.replace_section(owner, &put_in(&1.entities.simulate, true))
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp disk(c), do: Valimc.TestDisk.read(c.base, c.key, :items)

  test "void removal applies at once, retains receipts and survives owner reopening", c do
    enable(c.owner)
    wait(fn -> map_size(state(c.owner).entities.store.entries) == 1 end)

    wait(fn ->
      Enum.map(Map.values(Valimc.TestWorld.item_snapshot(c.key)), & &1.uuid) == [c.boundary.uuid]
    end)

    {pid, _} = c.owner
    assert :ok = Region.flush(pid)
    saved = disk(c)

    assert Enum.map(saved.records, &{&1.uuid, &1.hops}) == [{c.boundary.uuid, 4}] and
             saved.receipts == c.receipts

    assert saved.ledger == c.ledger
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, reopened} = Valimc.TestWorld.item_owner(c.key)
    assert map_size(state(reopened).entities.store.entries) == 1
    assert Enum.map(disk(c).records, & &1.uuid) == [c.boundary.uuid]
  end
end
