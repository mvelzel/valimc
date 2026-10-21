defmodule Valimc.ContainerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{Containers, Store}

  setup do
    nonce = System.unique_integer([:positive])
    key = {900, nonce}
    base = Path.join(System.tmp_dir!(), "valimc-containers-#{nonce}")
    TestScope.isolate(key, world_path: base)
    span = Valimc.config(:region_size) * 16
    position = {900 * span, 64, nonce * span}
    {:ok, empty, entry} = Containers.create(%Containers{}, key, position, 3)
    slots = put_elem(entry.slots, 26, ItemStack.new("diamond", 3))
    {:ok, filled, _} = Containers.replace(empty, position, entry.revision, slots)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, base: base, position: position, filled: filled, empty: empty}
  end

  test "queued commits share one frame and one datasync and are acknowledged in order", ctx do
    {:ok, writer, lease} = Store.open(ctx.key)
    dir = Store.log_dir(ctx.base, ctx.key)
    {:ok, %{frames: before}} = Valimc.World.RegionLog.read(dir)
    {x, _, z} = ctx.position
    epoch = make_ref()
    :sys.suspend(writer)

    sent =
      for {containers, i} <- Enum.with_index([ctx.empty, ctx.filled, ctx.empty, ctx.filled]) do
        token = make_ref()
        Store.commit_containers(writer, lease, containers, {self(), epoch}, token)
        Store.snapshot(writer, lease, %{{x + i, 64, z} => 1}, {self(), epoch}, i)
        token
      end

    :sys.resume(writer)

    for {token, i} <- Enum.with_index(sent) do
      assert_receive {:resource, ^epoch, message}
      assert message == {:containers_saved, writer, token, :ok}
      assert_receive {:resource, ^epoch, {:saved, ^writer, ^i, :ok}}
    end

    {:ok, %{frames: frames}} = Valimc.World.RegionLog.read(dir)
    assert length(frames) == length(before) + 1
    assert {:ok, ctx.filled} == Store.load_containers(writer)
    assert Map.take(Store.load(writer), for(i <- 0..3, do: {x + i, 64, z})) |> map_size() == 4
  end

  test "checkpoints run beside appends, prune covered segments and recover exactly", ctx do
    Valimc.TestScope.isolate(ctx.key, store_checkpoint_bytes: 1)
    {:ok, writer, lease} = Store.open(ctx.key)
    dir = Store.log_dir(ctx.base, ctx.key)
    {x, _, z} = ctx.position

    for i <- 1..20 do
      assert :ok =
               Store.flush_containers(
                 writer,
                 lease,
                 if(rem(i, 2) == 0, do: ctx.filled, else: ctx.empty)
               )

      Store.snapshot(writer, lease, %{{x + i, 64, z} => 1}, {self(), make_ref()}, i)
    end

    assert :ok = Store.flush_containers(writer, lease, ctx.filled)
    wait_checkpointed(writer)
    files = File.ls!(dir)
    assert Enum.count(files, &String.starts_with?(&1, "ckpt.")) == 1
    assert Enum.count(files, &String.starts_with?(&1, "log.")) <= 2
    assert :ok = Store.close(writer, lease)
    {:ok, writer, _lease} = Store.open(ctx.key)
    assert Store.load_containers(writer) == {:ok, ctx.filled}
    assert map_size(Map.take(Store.load(writer), for(i <- 1..20, do: {x + i, 64, z}))) == 20
  end

  defp wait_checkpointed(writer, _budget \\ nil),
    do: Valimc.TestWait.until(fn -> :sys.get_state(writer).checkpointing == nil end)

  test "malformed proposals do not replace durable contents and corrupt files are not treated as empty",
       ctx do
    {:ok, writer, lease} = Store.open(ctx.key)
    assert :ok = Store.flush_containers(writer, lease, ctx.filled)
    before = Valimc.TestDisk.read(ctx.base, ctx.key, :containers)

    assert {:error, :invalid_container_snapshot} =
             Store.flush_containers(writer, lease, %{ctx.filled | sequence: 0})

    assert Valimc.TestDisk.read(ctx.base, ctx.key, :containers) == before
    assert :ok = Store.close(writer, lease)

    for corrupt <- [<<>>, :binary.copy(<<0>>, Containers.max_bytes() + 1)] do
      Valimc.TestDisk.write(ctx.base, ctx.key, :containers, corrupt)
      {:ok, writer, lease} = Store.open(ctx.key)
      assert {:error, :invalid_container_snapshot} = Store.load_containers(writer)
      assert :ok = Store.close(writer, lease)
    end
  end
end
