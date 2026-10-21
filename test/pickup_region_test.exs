defmodule Valimc.PickupRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{GameMode, Inventory, ItemMotionState, PlayerFood, PlayerSnapshot, PlayerStore}
  alias Valimc.{TransferDelivery, World}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, PickupTransfers, Region}

  setup do
    n = System.unique_integer([:positive])
    key = {51000 + rem(n, 3333) * 3, 1200}
    base = Path.join(System.tmp_dir!(), "valimc-pickup-region-#{n}")
    File.mkdir_p!(base)
    uuid = <<n::64, 1::64>>
    second = <<n::64, 3::64>>
    TestScope.isolate([key, uuid, second], world_path: base)
    x = elem(key, 0) * 128 + 8.5
    z = elem(key, 1) * 128 + 8.5

    record = %{
      uuid: <<n::64, 2::64>>,
      x: x,
      y: 64.0,
      z: z,
      stack: ItemStack.new("stone", 7),
      motion: %ItemMotionState{no_gravity: true}
    }

    {:ok, bytes} = ItemLedger.encode(key, [record], %{}, %ItemLedger{})
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, owner} = World.item_owner(key)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)

    snapshot = %{
      pose: %{x: x, y: 64.0, z: z, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{},
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 20.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 0,
      outbox: nil
    }

    actor = %{
      uuid: uuid,
      box: {x - 0.3, 64.0, z - 0.3, x + 0.3, 65.8, z + 0.3},
      game_mode: snapshot.game_mode,
      health: snapshot.health
    }

    on_exit(fn ->
      for source <- [uuid, second],
          {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, source),
          do: TestScope.kill(pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key) do
        store = state({pid, nil}).store
        if Process.alive?(store), do: :sys.resume(store)
        TestScope.kill(pid)
      end

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      owner: owner,
      writer: writer,
      fence: fence,
      uuid: uuid,
      second: second,
      record: record,
      snapshot: snapshot,
      actor: actor
    }
  end

  defp state({pid, _}), do: Valimc.TestConn.state(pid).resource

  defp disk(ctx) do
    {:ok, saved} = ItemLedger.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)
    saved
  end

  defp player(ctx) do
    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    saved
  end

  defp prepare(ctx, grant) do
    inventory = %{
      ctx.snapshot.inventory
      | infinite_materials: ctx.snapshot.game_mode.current == :creative
    }

    {:ok, _, remainder, _} = Inventory.pickup_stack(inventory, grant.before)

    request =
      grant
      |> Map.put(:source, ctx.uuid)
      |> Map.put(:sequence, 1)
      |> Map.put(:remainder, remainder)

    intent = %{kind: :pickup, key: ctx.key, request: request}
    ref = make_ref()
    PlayerStore.prepare_pickup(ctx.writer, ctx.fence, ctx.snapshot, intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, pending}}
    assert pending.inventory == ctx.snapshot.inventory
    assert player(ctx).outbox == pending.outbox
    {fence, pending}
  end

  defp deliver(ctx, pending) do
    token = make_ref()

    {:ok, %{pid: pid, monitor: monitor}} =
      TransferDelivery.start(self(), token, ctx.uuid, pending)

    assert_receive {:transfer_delivered, ^pid, ^token, result}
    Process.demonitor(monitor, [:flush])
    assert TransferDelivery.completed?(pending, result)
    result
  end

  defp complete(ctx, fence) do
    ref = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, next_fence, resolved}}
    {next_fence, resolved}
  end

  test "a live grant follows durable capacity; withdrawal and player grant survive replay/reopen",
       ctx do
    assert {:ok, grant} = Region.reserve_pickup(ctx.owner, ctx.actor, ctx.record.uuid)
    assert disk(ctx).receipts[ctx.uuid] == %{sequence: 0, digest: <<0::256>>}
    {fence, pending} = prepare(ctx, grant)
    assert {:ok, :applied} = deliver(ctx, pending)
    assert disk(ctx).records == []
    assert player(ctx).inventory.slots == %{}

    assert {:ok, :applied} =
             PickupTransfers.receipt_result(
               ctx.key,
               pending.outbox.request,
               disk(ctx).receipts[ctx.uuid]
             )

    assert {:ok, :already_applied} = deliver(ctx, pending)
    {_fence, resolved} = complete(ctx, fence)
    assert resolved.inventory.slots[36] == ctx.record.stack and resolved.outbox == nil
    DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    assert {:ok, _, restored, _} = PlayerStore.open(ctx.uuid)
    assert restored.inventory.slots == resolved.inventory.slots and restored.outbox == nil
    assert restored.transfer_sequence == 1
  end

  test "two prepared players racing one item receive one applied and one terminal rejection",
       ctx do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.second)

    second = %{
      ctx
      | uuid: ctx.second,
        writer: writer,
        fence: fence,
        actor: %{ctx.actor | uuid: ctx.second}
    }

    assert {:ok, first_grant} = Region.reserve_pickup(ctx.owner, ctx.actor, ctx.record.uuid)
    assert {:ok, second_grant} = Region.reserve_pickup(ctx.owner, second.actor, ctx.record.uuid)
    {fence, pending} = prepare(ctx, first_grant)
    {second_fence, second_pending} = prepare(second, second_grant)
    assert {:ok, :applied} = deliver(ctx, pending)
    assert {:ok, :rejected} = deliver(second, second_pending)
    assert {:ok, :already_rejected} = deliver(second, second_pending)
    {_, first} = complete(ctx, fence)
    {_, second} = complete(second, second_fence)
    assert first.inventory.slots[36] == ctx.record.stack
    assert second.inventory.slots == %{} and second.outbox == nil
    assert disk(ctx).records == [] and map_size(disk(ctx).receipts) == 2
  end
end
