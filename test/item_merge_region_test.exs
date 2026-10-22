defmodule Valimc.ItemMergeRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Entity.Store
  alias Valimc.World.Region

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
            kind: :item,
            stack: ItemStack.new("stone", i + 1),
            motion: %ItemMotionState{age: i * 100, pickup_delay: i * 10, no_gravity: true},
            hops: if(i == 2, do: 3, else: 0)
          }

    Valimc.TestDisk.write(base, key, :items, %{records: records})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{owner: owner, key: key, base: base, records: records}
  end

  def state(owner), do: Valimc.TestRegion.section(owner)

  def pairs(owner) do
    items = state(owner).entities.store
    {:ok, {_, a, ar}} = Store.find(items, <<1::128>>)
    {:ok, {_, b, br}} = Store.find(items, <<2::128>>)
    [%{a: {a, ar}, b: {b, br}}]
  end

  def disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  test "a merge applies and publishes at once; a competing merge refuses; restart keeps one stack",
       ctx do
    proposal = pairs(ctx.owner)
    assert {:ok, [_]} = Region.merge_items(ctx.owner, proposal)
    s = state(ctx.owner)
    assert map_size(Valimc.Entity.Publication.source(s.publication, :items)) == 1
    assert {:error, :stale_item} = Region.merge_items(ctx.owner, proposal)

    {pid, _} = ctx.owner
    assert :ok = Region.flush(pid)
    assert [record] = disk(ctx).records
    assert record.uuid == <<2::128>> and record.stack.count == 5
    assert record.motion.age == 100 and record.motion.pickup_delay == 20

    assert record.hops == 3

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:ok, next} = Valimc.TestWorld.item_owner(ctx.key)
    assert Store.records(state(next).entities.store) == [record]
  end
end
