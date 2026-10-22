defmodule Valimc.GroupCommitTest do
  @moduledoc """
  Owner-level guarantees of the shared log (VMC-077f): changes show at once
  (D2) and a crash loses only a suffix of an owner's frames.
  """
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
    key = {50_000 + rem(nonce, 3_333) * 3, 777}
    {rx, rz} = key

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_neighbourhood(key)
      File.rm_rf!(base)
    end)

    %{
      key: key,
      position: {rx * 128 + 0.5, 64.5, rz * 128 + 0.5},
      block: {rx * 128 + 3, 64, rz * 128}
    }
  end

  defp uuids(key), do: MapSet.new(for {_, view} <- World.item_snapshot(key), do: view.uuid)

  test "changes are observable at once while their frame waits for the disk", ctx do
    {:ok, owner} = World.item_owner(ctx.key)
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    {cx, _, cz} = ctx.block
    chunk = World.chunk({div(cx, 16), div(cz, 16)})
    stripe = Valimc.TestDisk.stripe(Valimc.config(:world_path), ctx.key)
    :sys.suspend(stripe)

    try do
      assert {:ok, _} = Region.create_item(owner, ItemStack.new("stone"), ctx.position)
      assert :ok = Valimc.TestBlocks.set(ctx.block, 1)
      wait(fn -> Valimc.TestRegion.in_flight?(Valimc.TestRegion.section(owner)) end)
      assert_receive {:event, {:block_batch, _}}
      assert World.chunk({div(cx, 16), div(cz, 16)}) != chunk
      assert map_size(World.item_snapshot(ctx.key)) == 1
      assert Valimc.TestRegion.published_block(owner, ctx.block) == 1
    after
      :sys.resume(stripe)
    end
  end

  test "a log crash at any point loses only a suffix of an owner's changes", ctx do
    base = Valimc.config(:world_path)

    for round <- 1..5 do
      {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
      :ok = Region.flush(pid)
      before = uuids(ctx.key)
      stripe = Valimc.TestDisk.stripe(base, ctx.key)

      killer =
        Task.async(fn ->
          Process.sleep(:rand.uniform(15))
          Process.exit(stripe, :kill)
        end)

      {created, _log} = with_log(fn -> create_until_down(owner, ctx, 200, []) end)
      Task.await(killer, 60_000)
      # What only the owner's memory held goes with it, as in a crash.
      if Process.alive?(pid), do: Valimc.TestScope.kill(pid)
      {:ok, _} = await_owner(ctx.key, pid)
      kept = MapSet.difference(uuids(ctx.key), before)
      created = Enum.reverse(created)
      assert MapSet.subset?(before, uuids(ctx.key)), "round #{round}"
      assert kept == MapSet.new(Enum.take(created, MapSet.size(kept))), "round #{round}"
    end
  end

  defp create_until_down(_owner, _ctx, 0, acc), do: acc

  defp create_until_down(owner, ctx, left, acc) do
    case Region.create_item(owner, ItemStack.new("stone"), ctx.position) do
      {:ok, handle} ->
        uuid = World.item_snapshot(ctx.key)[elem(handle, 2)].uuid
        create_until_down(owner, ctx, left - 1, [uuid | acc])

      {:error, {:retry, :item_storage_busy}} ->
        create_until_down(owner, ctx, left, acc)

      {:error, _} ->
        acc
    end
  catch
    :exit, _ -> acc
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp await_owner(key, old, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      case World.item_owner(key) do
        {:ok, {pid, _} = owner} when pid != old -> {:ok, owner}
        _ -> nil
      end
    end)
  end
end
