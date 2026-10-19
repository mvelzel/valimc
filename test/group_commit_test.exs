defmodule Valimc.GroupCommitTest do
  @moduledoc "Owner-level guarantees of the region write queue (VMC-063)."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-group-commit-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {50_000 + rem(nonce, 10_000), 777}
    {rx, rz} = key

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      key: key,
      position: {rx * 128 + 0.5, 64.5, rz * 128 + 0.5},
      block: {rx * 128 + 3, 64, rz * 128}
    }
  end

  defp writer({pid, _}), do: :sys.get_state(pid).resource.store

  defp uuids(key), do: MapSet.new(for {_, view} <- World.item_snapshot(key), do: view.uuid)

  test "nothing a queued write changed is observable before it is durable", ctx do
    {:ok, owner} = World.item_owner(ctx.key)
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    views = World.item_snapshot(ctx.key)
    {cx, _, cz} = ctx.block
    chunk = World.chunk({div(cx, 16), div(cz, 16)})
    writer = writer(owner)
    :sys.suspend(writer)

    try do
      created =
        Task.async(fn -> Region.create_item(owner, ItemStack.new("stone"), ctx.position) end)

      wait(fn -> Valimc.TestRegion.in_flight?(:sys.get_state(elem(owner, 0)).resource) end)
      # A raw edit after the queued write reaches subscribers after it, too.
      assert :ok = World.set_block(ctx.block, 1)
      packet = Task.async(fn -> World.chunk({div(cx, 16), div(cz, 16)}) end)
      refute_receive {:event, _}, 30
      assert Task.yield(created, 0) == nil
      assert Task.yield(packet, 0) == nil
      assert World.item_snapshot(ctx.key) == views
      assert Valimc.TestRegion.published_block(owner, ctx.block) == 0
      :sys.resume(writer)
      assert {:ok, _} = Task.await(created)
      assert Task.await(packet) != chunk
      assert_receive {:event, {:block, _, 1}}
      assert map_size(World.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a writer crash at any point loses no acknowledged write", ctx do
    for round <- 1..5 do
      {:ok, owner} = World.item_owner(ctx.key)
      writer = writer(owner)
      before = uuids(ctx.key)

      killer =
        Task.async(fn ->
          Process.sleep(:rand.uniform(15))
          Process.exit(writer, :kill)
        end)

      {handles, _log} = with_log(fn -> ack_until_failure(owner, ctx.position, 200, []) end)
      Task.await(killer)
      {:ok, _} = await_owner(ctx.key, elem(owner, 0))
      recovered = uuids(ctx.key)
      # Each acknowledged create added one item; unacknowledged ones may or may not
      # have reached the log, but nothing acknowledged or earlier is lost.
      assert MapSet.subset?(before, recovered)
      assert MapSet.size(recovered) >= MapSet.size(before) + length(handles), "round #{round}"
    end
  end

  defp ack_until_failure(_owner, _position, 0, acc), do: acc

  defp ack_until_failure(owner, position, left, acc) do
    case Region.create_item(owner, ItemStack.new("stone"), position) do
      {:ok, handle} -> ack_until_failure(owner, position, left - 1, [handle | acc])
      {:error, :storage_backpressure} -> ack_until_failure(owner, position, left, acc)
      {:error, :item_storage_busy} -> ack_until_failure(owner, position, left, acc)
      {:error, _} -> acc
    end
  catch
    :exit, _ -> acc
  end

  defp wait(fun, tries \\ 200) do
    unless fun.() do
      assert tries > 0
      Process.sleep(1)
      wait(fun, tries - 1)
    end
  end

  defp await_owner(key, old, tries \\ 200) do
    case World.item_owner(key) do
      {:ok, {pid, _} = owner} when pid != old ->
        {:ok, owner}

      _ ->
        assert tries > 0
        Process.sleep(5)
        await_owner(key, old, tries - 1)
    end
  end
end
