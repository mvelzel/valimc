defmodule Valimc.ItemMergeRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{ItemMotionState, Protocol.ItemStack, World}
  alias Valimc.World.{ItemLedger, Items, Region}

  setup :scope

  def scope(tags) do
    n = System.unique_integer([:positive])
    key = {41000 + rem(n, 3333) * 3, 900}
    base = Path.join(System.tmp_dir!(), "valimc-item-merge-#{n}")
    File.mkdir_p!(base)

    TestScope.isolate(key,
      world_path: base,
      item_simulation: Map.get(tags, :simulation, false)
    )

    records =
      for i <- 1..2,
          do: %{
            uuid: <<i::128>>,
            x: elem(key, 0) * 128 + 8.5,
            y: 64.0,
            z: elem(key, 1) * 128 + 8.5,
            stack: ItemStack.new("stone", i + 1),
            motion: %ItemMotionState{age: i * 100, pickup_delay: i * 10, no_gravity: true}
          }

    receipts = %{<<99::128>> => %{sequence: 4, digest: :crypto.hash(:sha256, "birth")}}

    {:ok, bytes} =
      ItemLedger.encode(key, records, receipts, %ItemLedger{generations: %{<<2::128>> => 3}})

    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key) do
        state = Valimc.TestConn.state(pid).resource
        if Process.alive?(state.store), do: :sys.resume(state.store)
        TestScope.kill(pid)
      end

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{owner: owner, key: key, base: base, records: records, receipts: receipts}
  end

  def state({pid, _}), do: Valimc.TestConn.state(pid).resource

  def pairs(owner) do
    items = state(owner).items
    {:ok, {_, a, ar}} = Items.find(items, <<1::128>>)
    {:ok, {_, b, br}} = Items.find(items, <<2::128>>)
    [%{a: {a, ar}, b: {b, br}}]
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp items_bytes(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  def disk(ctx) do
    {:ok, saved} = ItemLedger.decode(items_bytes(ctx), ctx.key)
    saved
  end

  test "publication waits for durable merge; competing mutation refuses and restart keeps one stack",
       ctx do
    s = state(ctx.owner)
    writer = s.store
    :sys.suspend(writer)

    try do
      proposal = pairs(ctx.owner)
      task = Task.async(fn -> Region.merge_items(ctx.owner, proposal) end)
      wait(fn -> Valimc.TestRegion.in_flight?(state(ctx.owner)) end)
      assert length(disk(ctx).records) == 2
      views = Valimc.World.EntityPublication.source(s.item_publication, :items)
      assert map_size(views) == 2
      assert Task.yield(task, 10) == nil
      # The pair is already merged in owner memory; a second merge cannot apply.
      assert {:error, _} = Region.merge_items(ctx.owner, proposal)
      :sys.resume(writer)
      assert {:ok, [_]} = Task.await(task, 60_000)
      assert [record] = disk(ctx).records
      assert record.uuid == <<2::128>> and record.stack.count == 5
      assert record.motion.age == 100 and record.motion.pickup_delay == 20

      assert disk(ctx).receipts == ctx.receipts and
               disk(ctx).ledger.generations == %{record.uuid => 3}

      assert {:error, :stale_item} = Region.merge_items(ctx.owner, proposal)
      {pid, _} = ctx.owner
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, next} = World.item_owner(ctx.key)
      assert Items.records(state(next).items) == [record]
      assert state(next).item_receipts == ctx.receipts
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  @tag simulation: true
end
