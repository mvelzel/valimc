defmodule Valimc.ContainerStoreTest do
  use ExUnit.Case, async: false
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, Store}

  setup do
    nonce = System.unique_integer([:positive])
    key = {900, nonce}
    base = Path.join(System.tmp_dir!(), "valimc-containers-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    span = Valimc.config(:region_size) * 16
    position = {900 * span, 64, nonce * span}
    {:ok, empty, entry} = Containers.create(%Containers{}, key, position, 3)
    slots = put_elem(entry.slots, 26, ItemStack.new("diamond", 3))
    {:ok, filled, _} = Containers.replace(empty, position, entry.revision, slots)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{key: key, base: base, position: position, filled: filled, empty: empty}
  end

  test "leased asynchronous commit survives writer replacement with exact contents and revisions",
       ctx do
    assert {:ok, writer, lease} = Store.open(ctx.key)
    assert {:ok, %Containers{sequence: 0, entries: entries}} = Store.load_containers(writer)
    assert entries == %{}
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, ctx.filled, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, :ok}}, 1000
    assert {:ok, saved} = Store.load_containers(writer)
    assert saved == ctx.filled

    assert {:ok, saved} =
             Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert saved == ctx.filled
    assert :ok = Store.close(writer, lease)
    assert {:ok, replacement, next_lease} = Store.open(ctx.key)
    assert replacement != writer and next_lease != lease
    assert {:ok, ^saved} = Store.load_containers(replacement)

    assert {:error, :stale_container} =
             Containers.replace(saved, ctx.position, 1, ctx.empty.entries[ctx.position].slots)
  end

  test "claim queued before owner death fences old container commits and flushes", ctx do
    parent = self()

    owner =
      Task.async(fn ->
        send(parent, {:opened, Store.open(ctx.key)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:opened, {:ok, writer, old_lease}}
    assert :ok = Store.flush_containers(writer, old_lease, ctx.filled)
    epoch = make_ref()
    token = make_ref()
    :sys.suspend(writer)

    try do
      claim = :gen_server.send_request(writer, :claim)
      Task.shutdown(owner, :brutal_kill)
      Store.commit_containers(writer, old_lease, ctx.empty, {self(), epoch}, token)
      :sys.resume(writer)
      assert {:reply, {:ok, lease}} = :gen_server.wait_response(claim, 1000)
      assert lease != old_lease

      assert_receive {:resource, ^epoch,
                      {:containers_saved, ^writer, ^token, {:error, :stale_store_lease}}}

      assert {:error, :stale_store_lease} = Store.flush_containers(writer, old_lease, ctx.empty)
      assert {:ok, saved} = Store.load_containers(writer)
      assert saved == ctx.filled
      assert :ok = Store.flush_containers(writer, lease, ctx.empty)
      assert {:ok, empty} = Store.load_containers(writer)
      assert empty == ctx.empty
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(owner, :brutal_kill)
    end
  end

  test "malformed proposals do not replace durable contents and corrupt files are not treated as empty",
       ctx do
    {:ok, writer, lease} = Store.open(ctx.key)
    assert :ok = Store.flush_containers(writer, lease, ctx.filled)
    path = Store.container_path(ctx.base, ctx.key)
    before = File.read!(path)

    assert {:error, :invalid_container_snapshot} =
             Store.flush_containers(writer, lease, %{ctx.filled | sequence: 0})

    assert File.read!(path) == before
    File.write!(path, <<>>)
    assert {:error, :invalid_container_snapshot} = Store.load_containers(writer)
    File.write!(path, :binary.copy(<<0>>, Containers.max_bytes() + 1))
    assert {:error, :invalid_container_snapshot} = Store.load_containers(writer)
  end

  test "I/O failure is reported instead of acknowledging a container commit", ctx do
    File.mkdir_p!(ctx.base)
    File.mkdir_p!(Store.container_path(ctx.base, ctx.key))
    {:ok, writer, lease} = Store.open(ctx.key)
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, ctx.filled, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, {:error, _}}}, 1000
    refute File.regular?(Store.container_path(ctx.base, ctx.key))
  end
end
