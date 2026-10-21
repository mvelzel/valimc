defmodule Valimc.ItemStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region
  alias Valimc.Protocol.ItemStack
  import ExUnit.CaptureLog

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-items-#{nonce}")
    key = {230 + rem(nonce, 3_333) * 3, 230}
    TestScope.isolate(key, world_path: base)
    {:ok, {pid, _} = owner} = World.item_owner(key)

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    {rx, rz} = key

    %{
      base: base,
      key: key,
      pid: pid,
      owner: owner,
      position: {rx * 128 + 0.5, 64.5, rz * 128 + 0.5}
    }
  end

  defp wait_pending(pid, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        Valimc.TestRegion.in_flight(Valimc.TestConn.state(pid).resource)
      end)

  defp send_resource(ctx, message), do: send(ctx.pid, {:resource, elem(ctx.owner, 1), message})

  test "a full write queue answers retryable backpressure, and drained writes all commit", ctx do
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)

    try do
      created =
        for n <- 1..64 do
          task =
            Task.async(fn ->
              Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)
            end)

          wait_queued(ctx.pid, n)
          task
        end

      assert {:error, :storage_backpressure} =
               Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)

      :sys.resume(writer)
      assert Enum.all?(Task.await_many(created, 5000), &match?({:ok, _}, &1))
      assert {:ok, _} = Region.create_item(ctx.owner, ItemStack.new("stone"), ctx.position)
      assert map_size(World.item_snapshot(ctx.key)) == 65
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  defp wait_queued(pid, count, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        length(Valimc.TestConn.state(pid).resource.item_writes) >= count
      end)

  defp seed(ctx) do
    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:custom_data" => {:compound, %{"save" => {:string, "region"}}}},
        removed: MapSet.new(["minecraft:rarity"])
    }

    {:ok, handle} = Region.create_item(ctx.owner, stone, ctx.position)
    view = World.item_snapshot(ctx.key)[elem(handle, 2)]
    {handle, view.uuid, stone}
  end

  defp replace_owner(ctx, reason \\ :kill) do
    ref = Process.monitor(ctx.pid)

    if reason == :kill,
      do: Process.exit(ctx.pid, :kill),
      else: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)

    assert_receive {:DOWN, ^ref, :process, _, _}
    {:ok, owner} = World.item_owner(ctx.key)
    owner
  end

  test "acknowledged create/replace/remove survive owner replacement with UUID and fresh handles",
       ctx do
    {handle, uuid, _stone} = seed(ctx)
    egg = ItemStack.new("egg", 3)
    {:ok, updated} = Region.replace_item(handle, egg)
    owner = replace_owner(ctx)
    assert {:ok, current} = Region.find_item(owner, uuid)
    assert elem(current, 2) != elem(updated, 2) and elem(current, 1) != elem(updated, 1)

    assert {:error, :stale_region} =
             Region.remove_item(
               {elem(owner, 0), elem(updated, 1), elem(updated, 2), elem(updated, 3)}
             )

    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == egg
    assert :ok = Region.remove_item(current)
    next = replace_owner(%{ctx | pid: elem(owner, 0)}, :shutdown)
    assert {:error, :missing_item} = Region.find_item(next, uuid)
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "a stalled write holds replies and publication while later mutations queue behind it",
       ctx do
    {handle, _uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    :sys.suspend(writer)

    try do
      assert {:ok, ^handle} = Region.replace_item(handle, stone)
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
      task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
      pending = wait_pending(ctx.pid)
      created = Task.async(fn -> Region.create_item(ctx.owner, stone, ctx.position) end)
      assert Task.yield(task, 10) == nil and Task.yield(created, 10) == nil
      assert map_size(World.item_snapshot(ctx.key)) == 1
      assert World.item_snapshot(ctx.key)[elem(handle, 2)].revision == 1
      {x, _, z} = ctx.position
      assert :ok = World.set_block({floor(x), 64, floor(z)}, 1)
      assert World.get_block({floor(x), 64, floor(z)}) == 1
      send_resource(ctx, {:items_saved, writer, make_ref(), :ok})
      send_resource(ctx, {:items_saved, self(), pending.token, :ok})
      send_resource(ctx, {:item_commit_deadline, make_ref()})
      assert Valimc.TestRegion.write_token(:sys.get_state(ctx.pid).resource) == pending.token
      assert {:message_queue_len, 2} = Process.info(writer, :message_queue_len)
      :sys.resume(writer)
      assert {:ok, updated} = Task.await(task, 60_000)
      assert {:ok, _} = Task.await(created, 60_000)
      assert World.item_snapshot(ctx.key)[elem(updated, 2)].revision == 2
      assert map_size(World.item_snapshot(ctx.key)) == 2
      assert :ok = Region.flush(ctx.pid)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a real write failure fences the owner and preserves the old recoverable state", ctx do
    {handle, uuid, stone} = seed(ctx)
    old = disk(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    Valimc.TestDisk.break_writer(writer)
    ref = Process.monitor(ctx.pid)

    assert capture_log(fn ->
             assert {:error, :item_commit_uncertain} =
                      Region.replace_item(handle, ItemStack.new("egg", 3))

             assert_receive {:DOWN, ^ref, :process, _, {:item_storage_failed, _}}
           end) =~ "Region commit failed"

    Valimc.TestDisk.await_exit(writer)
    assert disk(ctx) == old
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).resource.items.entries[elem(current, 2)].stack == stone
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "a corrupt item file is preserved and prevents only its region from publishing", ctx do
    seed(ctx)
    bytes = disk(ctx)
    writer = :sys.get_state(ctx.pid).resource.store
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    Valimc.TestDisk.await_exit(writer)
    corrupt = bytes <> <<0>>
    Valimc.TestDisk.write(ctx.base, ctx.key, :items, corrupt)

    capture_log(fn ->
      assert {:error, reason} = World.item_owner(ctx.key)
      assert reason in [{:item_load_failed, :invalid_item_file}, :region_restarting]
    end)

    assert World.item_snapshot(ctx.key) == %{} and disk(ctx) == corrupt
    {rx, rz} = ctx.key
    {:ok, healthy} = World.item_owner({rx + 1, rz})

    assert {:ok, _} =
             Region.create_item(healthy, ItemStack.new("stone"), {(rx + 1) * 128, 64, rz * 128})

    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(healthy, 0))
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  def transfer(ctx, sequence \\ 1) do
    {x, y, z} = ctx.position
    record = %{uuid: <<sequence::128>>, x: x, y: y, z: z, stack: ItemStack.new("stone", 7)}
    %{source: <<99::128>>, sequence: sequence, records: [record]}
  end
end
