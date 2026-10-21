defmodule Valimc.ItemHandoffRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemLedger, ItemRecords, Items, Region}

  setup tags do
    nonce = System.unique_integer([:positive])
    key = {31_000 + rem(nonce, 3_333) * 3, 700}
    destination = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-handoff-#{nonce}")
    TestScope.isolate(TestScope.neighborhood(key), world_path: base)
    File.mkdir_p!(base)
    count = Map.get(tags, :population, 1)

    records = fn region, first ->
      {rx, rz} = region

      for n <- first..(first + count - 1),
          do: %{
            uuid: <<n::128>>,
            x: rx * 128 + 127.5,
            y: 64.25,
            z: rz * 128 + 0.5,
            stack: ItemStack.new("stone", 3),
            motion: %ItemMotionState{no_gravity: true}
          }
    end

    receipts = %{<<99::128>> => %{sequence: 1, digest: <<99::256>>}}
    source_records = records.(key, 1)
    destination_records = if count == 1, do: [], else: records.(destination, 1000)
    {:ok, bytes} = ItemRecords.encode(key, source_records, receipts)
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, bytes} = ItemRecords.encode(destination, destination_records)
    Valimc.TestDisk.write(base, destination, :items, bytes)
    {:ok, owner} = World.item_owner(key)
    {:ok, other} = World.item_owner(destination)

    on_exit(fn ->
      for region <- [key, destination],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, region) do
        :sys.resume(pid)
        TestScope.kill(pid)
      end

      File.rm_rf(base)
    end)

    %{
      key: key,
      destination: destination,
      base: base,
      owner: owner,
      other: other,
      uuid: <<1::128>>,
      receipts: receipts,
      record: hd(source_records)
    }
  end

  defp resource({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp steps(owner, destination, uuids) do
    state = resource(owner)
    {rx, rz} = destination

    Enum.map(uuids, fn uuid ->
      {:ok, {epoch, id, revision}} = Items.find(state.items, uuid)
      assert epoch == elem(owner, 1)

      %{
        id: id,
        revision: revision,
        position: {rx * 128 + 0.5, 64.25, rz * 128 + 0.5},
        motion: %ItemMotionState{velocity: {0.1, 0.0, 0.0}, age: 2, no_gravity: true}
      }
    end)
  end

  # The handoff finished and the source's side of it is durable.
  defp complete({pid, _} = owner) do
    wait(fn ->
      s = resource(owner)
      s.items.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s)
    end)

    :ok = Region.flush(pid)
  end

  # Durably present in that owner's region (what a restart or any reader would see).
  defp published({pid, _}, uuid) do
    [key] = Registry.keys(Valimc.RegionRegistry, pid)

    {:ok, saved} =
      ItemLedger.decode(Valimc.TestDisk.read(Valimc.config(:world_path, key), key, :items), key)

    Enum.any?(saved.records, &(&1.uuid == uuid))
  end

  defp disk(ctx, key) do
    assert {:ok, snapshot} = ItemLedger.decode(Valimc.TestDisk.read(ctx.base, key, :items), key)
    snapshot
  end

  defp replace_owner(owner, key) do
    {pid, _} = owner
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:ok, next} = World.item_owner(key)
    next
  end

  test "both directions and owner recovery conserve one item and leave original player receipts",
       ctx do
    assert {:ok, 1} =
             Region.handoff_items(
               ctx.owner,
               ctx.destination,
               steps(ctx.owner, ctx.destination, [ctx.uuid])
             )

    complete(ctx.owner)
    refute published(ctx.owner, ctx.uuid)
    assert published(ctx.other, ctx.uuid)
    assert disk(ctx, ctx.key).receipts == ctx.receipts
    assert disk(ctx, ctx.destination).receipts == %{}
    assert disk(ctx, ctx.destination).ledger.generations == %{ctx.uuid => 1}
    receipt = ctx.receipts[<<99::128>>]
    # The existing player receipt still fences a retry after the item has left.
    assert {:ok, {key, ^receipt}} = Region.item_transfer_receipt(ctx.owner, <<99::128>>)
    assert key == ctx.key

    assert {:ok, 1} =
             Region.handoff_items(ctx.other, ctx.key, steps(ctx.other, ctx.key, [ctx.uuid]))

    complete(ctx.other)
    owner = replace_owner(ctx.owner, ctx.key)
    other = replace_owner(ctx.other, ctx.destination)
    assert published(owner, ctx.uuid) and not published(other, ctx.uuid)
    assert disk(ctx, ctx.key).ledger.generations == %{ctx.uuid => 2}
    assert disk(ctx, ctx.destination).ledger.incoming[ctx.key].sequence == 1
    assert disk(ctx, ctx.key).receipts == ctx.receipts
  end

  @tag population: 256
  test "full neighbors simultaneously exchange cohorts without a destination lock cycle", ctx do
    a_uuids = Enum.map(1..32, &<<&1::128>>)
    b_uuids = Enum.map(1000..1031, &<<&1::128>>)
    a_steps = steps(ctx.owner, ctx.destination, a_uuids)
    b_steps = steps(ctx.other, ctx.key, b_uuids)
    a = Task.async(fn -> Region.handoff_items(ctx.owner, ctx.destination, a_steps) end)
    b = Task.async(fn -> Region.handoff_items(ctx.other, ctx.key, b_steps) end)
    assert {:ok, 1} = Task.await(a, 60_000)
    assert {:ok, 1} = Task.await(b, 60_000)
    complete(ctx.owner)
    complete(ctx.other)
    records = disk(ctx, ctx.key).records ++ disk(ctx, ctx.destination).records
    assert length(records) == 512 and length(Enum.uniq_by(records, & &1.uuid)) == 512
    assert map_size(resource(ctx.owner).items.entries) == 256
    assert map_size(resource(ctx.other).items.entries) == 256
    assert Enum.all?(a_uuids, &published(ctx.other, &1))
    assert Enum.all?(b_uuids, &published(ctx.owner, &1))
  end
end
