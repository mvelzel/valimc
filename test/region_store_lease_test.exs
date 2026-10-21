defmodule Valimc.RegionStoreLeaseTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.World.{Items, Store}
  alias Valimc.Protocol.ItemStack

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-store-lease-#{nonce}")
    key = {760, nonce}
    TestScope.isolate(key, world_path: base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, base: base}
  end

  test "one live owner excludes another claimant and its death closes the writer", ctx do
    parent = self()

    owner =
      Task.async(fn ->
        result = Store.open(ctx.key)
        send(parent, {:opened, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:opened, {:ok, writer, lease}}
    ref = Process.monitor(writer)
    assert {:error, :store_owned} = Store.open(ctx.key)
    assert :ok = Store.flush(writer, lease, %{})
    send(owner.pid, :finish)
    Task.await(owner, 60_000)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    assert {:ok, replacement, next_lease} = Store.open(ctx.key)
    assert replacement != writer and lease != next_lease
    assert Store.load(replacement) == %{}
  end

  test "claim after owner death fences queued old writes, flush and close on the same writer",
       ctx do
    parent = self()

    owner =
      Task.async(fn ->
        send(parent, {:opened, Store.open(ctx.key)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:opened, {:ok, writer, old_lease}}
    pos = {0, 64, 0}
    epoch = make_ref()
    token = make_ref()
    assert :ok = Store.flush(writer, old_lease, %{pos => 1})
    Store.commit_items(writer, old_lease, Items.new(), %{}, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:items_saved, ^writer, ^token, :ok}}
    original_items = Valimc.TestDisk.read(ctx.base, ctx.key, :items)
    {rx, rz} = ctx.key
    size = Valimc.config(:region_size) * 16

    {:ok, stale_items, _} =
      Items.create(
        Items.new(),
        ctx.key,
        ItemStack.new("stone", 3),
        {rx * size + 0.5, 64.5, rz * size + 0.5}
      )

    :sys.suspend(writer)

    try do
      # Queue the real claim ahead of DOWN. On execution its former owner is dead.
      claim = :gen_server.send_request(writer, :claim)
      Task.shutdown(owner, :brutal_kill)
      Store.snapshot(writer, old_lease, %{pos => 2}, {self(), epoch}, 99)
      Store.commit_items(writer, old_lease, stale_items, %{}, {self(), epoch}, token)
      :sys.resume(writer)
      assert {:reply, {:ok, lease}} = :gen_server.wait_response(claim, 1000)
      assert lease != old_lease
      assert_receive {:resource, ^epoch, {:saved, ^writer, 99, {:error, :stale_store_lease}}}

      assert_receive {:resource, ^epoch,
                      {:items_saved, ^writer, ^token, {:error, :stale_store_lease}}}

      assert {:error, :stale_store_lease} = Store.flush(writer, old_lease, %{pos => 3})
      assert {:error, :stale_store_lease} = Store.close(writer, old_lease)
      assert Store.load(writer) == %{pos => 1}
      assert Valimc.TestDisk.read(ctx.base, ctx.key, :items) == original_items
      assert :ok = Store.flush(writer, lease, %{pos => 4})
      assert Store.load(writer) == %{pos => 4}
      assert Process.alive?(writer)
      assert :ok = Store.close(writer, lease)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(owner, :brutal_kill)
    end
  end
end
