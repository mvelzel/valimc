defmodule Valimc.ItemVoidRegionTest do
  use ExUnit.Case, async: false
  # Serial: the fsync-wait assertion races a simulation tick that queued writes allow.
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Region}

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
      stack: ItemStack.new("stone", 7),
      motion: motion
    }

    boundary = %{below | uuid: <<n::64, 2::64>>, y: -128.0}
    receipts = %{<<n::64, 3::64>> => %{sequence: 11, digest: <<12::256>>}}

    ledger = %ItemLedger{
      sequence: 8,
      incoming: %{{elem(key, 0) - 1, elem(key, 1)} => %{sequence: 6, digest: <<7::256>>}},
      generations: %{below.uuid => 3, boundary.uuid => 4}
    }

    {:ok, bytes} = ItemLedger.encode(key, [below, boundary], receipts, ledger)
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key), do: TestScope.kill(pid)

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

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp enable({pid, _} = owner) do
    Valimc.TestScope.simulate(owner, state(owner).key)
    :sys.replace_state(pid, &put_in(&1.resource.entities.simulate, true))
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp disk(c) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, c.key, :items), c.key)
    saved
  end

  test "void removal applies at once, retains receipts and survives owner reopening", c do
    enable(c.owner)
    wait(fn -> map_size(state(c.owner).entities.items.entries) == 1 end)

    wait(fn ->
      Enum.map(Map.values(World.item_snapshot(c.key)), & &1.uuid) == [c.boundary.uuid]
    end)

    {pid, _} = c.owner
    assert :ok = Region.flush(pid)
    saved = disk(c)

    assert Enum.map(saved.records, & &1.uuid) == [c.boundary.uuid] and
             saved.receipts == c.receipts

    assert saved.ledger == %{c.ledger | generations: %{c.boundary.uuid => 4}}
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, reopened} = World.item_owner(c.key)
    assert map_size(state(reopened).entities.items.entries) == 1
    assert Enum.map(disk(c).records, & &1.uuid) == [c.boundary.uuid]
  end
end
