defmodule Valimc.ItemCheckpointsTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.Entity.Store
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-item-checkpoints-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 320}
    TestScope.isolate(key, world_path: base)
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    position = {rx * 128 + 8.5, 65.5, rz * 128 + 8.5}
    {x, y, z} = position

    record = %{
      uuid: <<71::128>>,
      x: x,
      y: y,
      z: z,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{}
    }

    assert :ok = Region.drop_items(owner, [record])
    assert {:ok, handle} = Region.find_item(owner, record.uuid)

    on_exit(fn ->
      for {live, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(live)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      pid: pid,
      owner: owner,
      position: position,
      handle: handle
    }
  end

  defp step(ctx, {_, _, id, revision}, n) do
    {x, y, z} = ctx.position

    %{
      id: id,
      revision: revision,
      position: {x + n * 0.01, y, z},
      motion: %ItemMotionState{age: n, no_gravity: true, velocity: {0.01, 0, 0}}
    }
  end

  defp advance(ctx, handle, n) do
    assert {:ok, [next]} = Region.publish_item_motion(ctx.owner, [step(ctx, handle, n)])
    next
  end

  defp disk(ctx), do: Valimc.TestDisk.read(ctx.base, ctx.key, :items)

  defp read(ctx), do: disk(ctx)

  # Motion waits up to a second for a frame (VMC-077f); the kill comes sooner.
  test "normal shutdown checkpoints motion but a crash may roll back only ordinary motion", ctx do
    _first = advance(ctx, ctx.handle, 1)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, ctx.pid)
    assert [%{motion: %{age: 1}}] = read(ctx).records
    assert {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(ctx.key)
    fresh = %{ctx | pid: pid, owner: owner}
    assert {:ok, handle} = Region.find_item(owner, <<71::128>>)
    _second = advance(fresh, handle, 2)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)

    assert [%{motion: %{age: 1}}] =
             Store.records(Valimc.TestRegion.section(owner).entities.store)
  end
end
