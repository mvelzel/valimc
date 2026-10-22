defmodule Valimc.RegionDirectoryTest do
  use ExUnit.Case, async: false
  alias Valimc.World
  alias Valimc.World.Directory

  setup do
    n = rem(System.unique_integer([:positive]), 10_000)
    keys = [{780, n}, {781, n}]

    on_exit(fn ->
      for key <- keys,
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    %{key: hd(keys), other: List.last(keys)}
  end

  test "ready routing and item observations work while the cold directory is suspended", ctx do
    assert {:ok, {pid, epoch} = owner} = World.owner(ctx.key)
    size = Valimc.config(:region_size) * 16
    position = {elem(ctx.key, 0) * size, 64, elem(ctx.key, 1) * size}
    assert :ok = Valimc.TestBlocks.set(position, 1)
    {^pid, _, %{publication: table}} = Directory.lookup(ctx.key)
    assert_raise ArgumentError, fn -> :ets.insert(Valimc.RegionRoutes, {:bad, self()}) end
    :sys.suspend(Directory)

    try do
      assert World.region(ctx.key) == {:ok, pid}
      assert World.owner(ctx.key) == {:ok, {pid, epoch}}
      assert World.existing_owner(ctx.key) == {:ok, owner}
      assert World.item_snapshot(ctx.key) == Valimc.World.EntityPublication.source(table, :items)
      assert Valimc.TestBlocks.get(position) == 1
      assert :ok = Valimc.TestBlocks.set(position, 0)
      assert World.existing_owner(ctx.other) == {:error, {:retry, :region_unavailable}}
      assert World.item_snapshot(ctx.other) == %{}
      assert Registry.lookup(Valimc.RegionRegistry, ctx.other) == []
    after
      :sys.resume(Directory)
    end
  end

  test "replacement before old DOWN fences late monitor messages and publications", ctx do
    assert {:ok, {old, _}} = World.owner(ctx.key)
    [{_, ^old, old_token, old_monitor, _}] = :ets.lookup(Valimc.RegionRoutes, ctx.key)
    :sys.suspend(Directory)

    try do
      request = :gen_server.send_request(Directory, {:admit, ctx.key})
      assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, old)
      await_name_release(ctx.key)
      :sys.resume(Directory)
      assert {:reply, {:ok, pid}} = :gen_server.wait_response(request, 1000)
      assert pid != old
      assert {:ok, {^pid, epoch}} = World.owner(ctx.key)
      {^pid, token, publication} = Directory.lookup(ctx.key)
      assert token != old_token
      send(Directory, {:DOWN, old_monitor, :process, old, :normal})
      assert Directory.admit(ctx.key) == {:ok, pid}

      parent = self()

      :sys.replace_state(pid, fn state ->
        send(parent, {:stale, Directory.publish(ctx.key, old_token, publication)})
        send(parent, {:replay, Directory.publish(ctx.key, token, publication)})
        state
      end)

      assert_receive {:stale, {:error, :stale_admission}}
      assert_receive {:replay, {:error, :stale_admission}}
      assert World.existing_owner(ctx.key) == {:ok, {pid, epoch}}
    after
      :sys.resume(Directory)
    end
  end

  test "capacity rejects cold starts while existing routes remain usable", ctx do
    assert {:ok, owner} = World.owner(ctx.key)
    limit = Valimc.config(:max_regions)
    Application.put_env(:valimc, :max_regions, :ets.info(Valimc.RegionRoutes, :size))

    try do
      assert World.region(ctx.other) == {:error, {:retry, :max_children}}
      assert Directory.lookup(ctx.other) == nil
      assert Registry.lookup(Valimc.RegionRegistry, ctx.other) == []
      assert World.existing_owner(ctx.key) == {:ok, owner}

      assert {:error, :invalid_publication} =
               Directory.publish(ctx.key, make_ref(), %{epoch: make_ref(), items: :bad})

      assert Process.alive?(Process.whereis(Directory))
    after
      Application.put_env(:valimc, :max_regions, limit)
    end

    assert {:ok, _} = World.owner(ctx.other)
  end

  defp await_name_release(key, _budget \\ nil) do
    Valimc.TestWait.until(fn -> Registry.lookup(Valimc.RegionRegistry, key) == [] end)
    :ok
  end
end
