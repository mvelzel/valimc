defmodule Valimc.PlayerCraftingStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-crafting-store-#{nonce}")
    key = {90_000 + rem(nonce, 3_333) * 3, 991}
    uuid = :crypto.strong_rand_bytes(16)
    TestScope.isolate([key, uuid], world_path: base)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: TestScope.kill(pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{base: base, key: key, uuid: uuid, writer: writer, fence: fence}
  end

  defp plan(ctx) do
    {rx, rz} = ctx.key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 0.5, y: 64.0, z: rz * span + 0.5, yaw: 0.0, pitch: 0.0}
    inv = %Inventory{slots: %{1 => ItemStack.new("oak_log")}}
    before = %{pose: pose, inventory: inv}
    {:ok, next, [stack]} = Inventory.plan_click(inv, :throw, 0, 0)

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: pose.x,
      y: pose.y + 1.3199999928474426,
      z: pose.z,
      stack: stack
    }

    {before, %{before | inventory: next}, [record]}
  end

  test "source fence and exact destination receipt survive both owners restarting and a consumed drop",
       ctx do
    {before, after_snapshot, [record] = records} = plan(ctx)
    ref = make_ref()

    PlayerStore.prepare_crafting(
      ctx.writer,
      ctx.fence,
      before,
      after_snapshot,
      ctx.key,
      records,
      {:throw, 0},
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, pending}}, 1_500
    assert pending.transfer_sequence == 1 and pending.inventory.slots == %{}
    assert pending.outbox.records == records
    stale = make_ref()

    PlayerStore.prepare_crafting(
      ctx.writer,
      ctx.fence,
      before,
      after_snapshot,
      ctx.key,
      records,
      {:throw, 0},
      stale
    )

    assert_receive {:player_transfer_saved, ^stale, {:error, :stale_player_snapshot}}, 1_000
    missing = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, missing)
    assert_receive {:player_transfer_saved, ^missing, {:error, :transfer_not_applied}}, 1_000
    {:ok, _, request, _} = PlayerSnapshot.transfer_request(ctx.uuid, pending)
    {:ok, {region, _} = destination} = World.item_owner(ctx.key)
    assert {:ok, :applied} = Region.apply_item_transfer(destination, request)
    {:ok, handle} = Region.find_item(destination, record.uuid)
    assert :ok = Region.remove_item(handle)
    monitor = Process.monitor(ctx.writer)
    Process.exit(ctx.writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    {:ok, writer, recovered, fence} = PlayerStore.open(ctx.uuid)
    assert recovered.outbox == pending.outbox and recovered.inventory.slots == %{}
    {:ok, destination} = World.item_owner(ctx.key)
    assert {:ok, :already_applied} = Region.apply_item_transfer(destination, request)
    assert World.item_snapshot(ctx.key) == %{}
    completed = make_ref()
    PlayerStore.complete_transfer(writer, fence, completed)
    assert_receive {:player_transfer_saved, ^completed, {:ok, fence, resolved}}, 1_500
    assert resolved.outbox == nil and resolved.transfer_sequence == 1
    assert :ok = PlayerStore.close(writer, fence, resolved)
    {:ok, writer, saved, fence} = PlayerStore.open(ctx.uuid)
    assert saved.outbox == nil and saved.transfer_sequence == 1 and saved.inventory.slots == %{}
    assert World.item_snapshot(ctx.key) == %{}
    assert :ok = PlayerStore.close(writer, fence, saved)
  end

  test "an invalid conversion cannot write a source intent", ctx do
    {before, _after_snapshot, records} = plan(ctx)
    ref = make_ref()

    PlayerStore.prepare_crafting(
      ctx.writer,
      ctx.fence,
      before,
      before,
      ctx.key,
      records,
      {:throw, 0},
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, {:error, :invalid_crafting_transfer}}, 1_000
    refute File.exists?(PlayerStore.path(ctx.base, ctx.uuid))
    assert World.item_snapshot(ctx.key) == %{}
    assert :ok = PlayerStore.close(ctx.writer, ctx.fence, %{before | inventory: %Inventory{}})
  end
end
