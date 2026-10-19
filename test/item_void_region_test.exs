defmodule Valimc.ItemVoidRegionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Region}

  setup do
    n = System.unique_integer([:positive])
    key = {81000 + rem(n, 10000), 2400}
    base = Path.join(System.tmp_dir!(), "valimc-item-void-#{n}")
    previous = Valimc.config(:world_path)
    File.mkdir_p!(base)
    Application.put_env(:valimc, :world_path, base)
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
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key) do
        writer = state({pid, nil}).store
        if Process.alive?(writer), do: :sys.resume(writer)
        DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
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

  defp state({pid, _}), do: :sys.get_state(pid).resource

  defp enable({pid, _}),
    do: :sys.replace_state(pid, &%{&1 | resource: %{&1.resource | item_simulation_enabled: true}})

  defp wait(fun, tries \\ 400) do
    if value = fun.(),
      do: value,
      else:
        (
          assert tries > 0
          Process.sleep(5)
          wait(fun, tries - 1)
        )
  end

  defp disk(c) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(c.base, c.key, :items), c.key)
    saved
  end

  defp removed(_c, owner) do
    s = state(owner)
    s.item_pending == nil and map_size(s.items.entries) == 1
  end

  test "void removal waits for fsync, retains receipts and survives owner reopening", c do
    writer = state(c.owner).store
    :sys.suspend(writer)

    try do
      enable(c.owner)
      wait(fn -> match?(%{phase: :writing}, state(c.owner).item_pending) end)
      assert map_size(World.item_snapshot(c.key)) == 2 and length(disk(c).records) == 2
      assert state(c.owner).item_simulation == nil and state(c.owner).item_cross_job == nil
      :sys.resume(writer)
      wait(fn -> removed(c, c.owner) end)
      assert Enum.map(Map.values(World.item_snapshot(c.key)), & &1.uuid) == [c.boundary.uuid]
      saved = disk(c)
      assert saved.records == [c.boundary] and saved.receipts == c.receipts
      assert saved.ledger == %{c.ledger | generations: %{c.boundary.uuid => 4}}
      {pid, _} = c.owner
      assert :ok = Region.flush(pid)
      DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      {:ok, reopened} = World.item_owner(c.key)
      assert map_size(state(reopened).items.entries) == 1
      assert disk(c).records == [c.boundary]
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "failed removal never publishes and a new owner retries from durable authority", c do
    writer = state(c.owner).store
    Valimc.TestDisk.break_writer(writer)
    {pid, _} = c.owner
    monitor = Process.monitor(pid)

    capture_log(fn ->
      enable(c.owner)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    end)

    assert length(disk(c).records) == 2 and disk(c).ledger == c.ledger
    {:ok, recovered} = World.item_owner(c.key)
    assert map_size(state(recovered).items.entries) == 2
    enable(recovered)
    wait(fn -> removed(c, recovered) end)
    assert disk(c).records == [c.boundary] and disk(c).receipts == c.receipts
  end
end
