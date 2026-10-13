defmodule Valimc.ItemStoreTest do
  use ExUnit.Case, async: false
  alias Valimc.World
  alias Valimc.World.{ItemRecords, Region, Store}
  alias Valimc.Protocol.ItemStack
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-items-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {230 + rem(nonce, 10_000), 230}
    {:ok, {pid, _} = owner} = World.item_owner(key)

    on_exit(fn ->
      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, live)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
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

  defp wait_pending(pid, retries \\ 100) do
    case :sys.get_state(pid).item_pending do
      nil ->
        assert(retries > 0)
        Process.sleep(1)
        wait_pending(pid, retries - 1)

      pending ->
        pending
    end
  end

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

    assert_receive {:DOWN, ^ref, :process, _, _}, 1500
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

    assert :sys.get_state(elem(owner, 0)).items.entries[elem(current, 2)].stack == egg
    assert :ok = Region.remove_item(current)
    next = replace_owner(%{ctx | pid: elem(owner, 0)}, :shutdown)
    assert {:error, :missing_item} = Region.find_item(next, uuid)
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "one stalled proposal is unpublished, rejects more mutations and leaves block operations live",
       ctx do
    {handle, uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).store
    :sys.suspend(writer)

    try do
      assert {:ok, ^handle} = Region.replace_item(handle, stone)
      assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
      task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
      pending = wait_pending(ctx.pid)
      assert Task.yield(task, 10) == nil
      assert World.item_snapshot(ctx.key)[elem(handle, 2)].revision == 1
      assert {:ok, ^handle} = Region.find_item(ctx.owner, uuid)
      assert {:error, :item_storage_busy} = Region.remove_item(handle)
      assert {:error, :item_storage_busy} = Region.create_item(ctx.owner, stone, ctx.position)
      {x, _, z} = ctx.position
      assert :ok = World.set_block({floor(x), 64, floor(z)}, 1)
      assert World.get_block({floor(x), 64, floor(z)}) == 1
      send(ctx.pid, {:items_saved, writer, make_ref(), :ok})
      send(ctx.pid, {:items_saved, self(), pending.token, :ok})
      send(ctx.pid, {:item_commit_deadline, make_ref()})
      assert :sys.get_state(ctx.pid).item_pending.token == pending.token
      assert {:message_queue_len, 1} = Process.info(writer, :message_queue_len)
      :sys.resume(writer)
      assert {:ok, updated} = Task.await(task)
      assert World.item_snapshot(ctx.key)[elem(updated, 2)].revision == 2
      assert :ok = Region.flush(ctx.pid)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a real rename failure fences the owner and preserves the old recoverable file", ctx do
    {handle, uuid, stone} = seed(ctx)
    path = Store.item_path(ctx.base, ctx.key)
    old = File.read!(path)
    File.rename!(path, path <> ".saved")
    File.mkdir_p!(path)
    ref = Process.monitor(ctx.pid)

    assert capture_log(fn ->
             assert {:error, :item_commit_uncertain} =
                      Region.replace_item(handle, ItemStack.new("egg", 3))

             assert_receive {:DOWN, ^ref, :process, _, {:item_storage_failed, _}}, 1500
           end) =~ "Region item commit failed"

    assert File.dir?(path) and File.read!(path <> ".saved") == old
    File.rm_rf!(path)
    File.rename!(path <> ".saved", path)
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).items.entries[elem(current, 2)].stack == stone
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "writer loss fences a pending operation and recovers the actual previous file", ctx do
    {handle, uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg")) end)
    wait_pending(ctx.pid)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      Process.exit(writer, :kill)
      assert {:error, :item_commit_uncertain} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, _, {:store_failed, :killed}}, 1500
    end)

    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).items.entries[elem(current, 2)].stack == stone
  end

  test "a pending deadline fences its writer and never publishes or overwrites the old item",
       ctx do
    {handle, uuid, stone} = seed(ctx)
    writer = :sys.get_state(ctx.pid).store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg")) end)
    pending = wait_pending(ctx.pid)
    ref = Process.monitor(ctx.pid)

    capture_log(fn ->
      send(ctx.pid, {:item_commit_deadline, pending.token})
      assert {:error, :item_commit_uncertain} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, _, :item_storage_timeout}, 2000
    end)

    refute Process.alive?(writer)
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).items.entries[elem(current, 2)].stack == stone
  end

  test "shutdown before delivery of an acknowledgment recovers a committed proposal without rollback",
       ctx do
    {handle, uuid, _} = seed(ctx)
    writer = :sys.get_state(ctx.pid).store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.replace_item(handle, ItemStack.new("egg", 3)) end)
    wait_pending(ctx.pid)
    :sys.suspend(ctx.pid)
    :sys.resume(writer)
    assert {:ok, [%{stack: stack}]} = Store.load_items(writer)
    assert stack == ItemStack.new("egg", 3)
    owner = replace_owner(ctx, :shutdown)
    assert {:error, :item_commit_uncertain} = Task.await(task)
    {:ok, current} = Region.find_item(owner, uuid)
    assert :sys.get_state(elem(owner, 0)).items.entries[elem(current, 2)].stack == stack
  end

  test "a corrupt item file is preserved and prevents only its region from publishing", ctx do
    seed(ctx)
    path = Store.item_path(ctx.base, ctx.key)
    bytes = File.read!(path)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    corrupt = bytes <> <<0>>
    File.write!(path, corrupt)

    capture_log(fn ->
      assert {:error, {:item_load_failed, :invalid_item_file}} = World.item_owner(ctx.key)
    end)

    assert World.item_snapshot(ctx.key) == %{} and File.read!(path) == corrupt
    {rx, rz} = ctx.key
    {:ok, healthy} = World.item_owner({rx + 1, rz})

    assert {:ok, _} =
             Region.create_item(healthy, ItemStack.new("stone"), {(rx + 1) * 128, 64, rz * 128})

    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(healthy, 0))
  end

  test "old block snapshots cannot overwrite a newer committed item file", ctx do
    {handle, _, _} = seed(ctx)
    {:ok, _} = Region.replace_item(handle, ItemStack.new("egg", 3))
    path = Store.item_path(ctx.base, ctx.key)
    bytes = File.read!(path)
    writer = :sys.get_state(ctx.pid).store
    Store.snapshot(writer, %{}, self(), 31)
    assert_receive {:saved, 31, :ok}
    assert File.read!(path) == bytes
    assert {:ok, [%{stack: stack}]} = ItemRecords.decode(bytes, ctx.key)
    assert stack == ItemStack.new("egg", 3)
  end
end
