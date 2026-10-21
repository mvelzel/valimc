defmodule Valimc.PlayerPlacementStoreTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore,
    TransferDelivery,
    World
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemRecords, Region}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-placement-source-#{nonce}")
    key = {30_000 + rem(nonce, 3_333) * 3, 800}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 64, rz * span}
    {x, _, z} = position
    name = "Place#{nonce}"
    uuid = Connection.offline_uuid(name)
    Valimc.TestScope.isolate([uuid | Valimc.TestScope.neighborhood(key)], world_path: base)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)
    {:ok, owner} = World.item_owner(key)
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, reservation} = Region.reserve_placement(owner, observed.revision, observed.blocks)

    before = %{
      ItemStack.new("stone", 1)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"exact" => {:string, "refund"}}}
        }
    }

    intent =
      Map.merge(reservation, %{
        kind: :placement,
        key: key,
        slot: 45,
        before: before,
        after: nil,
        request: %{
          hand: :off,
          position: position,
          face: 1,
          cursor: {0.5, 0.5, 0.5},
          inside: false,
          border: false,
          sequence: 7
        },
        edits: %{position => 1}
      })

    snapshot = %{
      pose: %{x: x + 5.5, y: 64.0, z: z + 5.5, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{
        selected: 7,
        slots: %{45 => before, 5 => ItemStack.new("iron_helmet")}
      },
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 20.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 154,
      food: %PlayerFood{level: 18, saturation: 0.0},
      transfer_sequence: 0,
      outbox: nil
    }

    on_exit(fn ->
      for {registry, scope} <- [{Valimc.PlayerStoreRegistry, uuid}, {Valimc.RegionRegistry, key}],
          {live, _} <- Registry.lookup(registry, scope),
          do: Valimc.TestScope.kill(live)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      position: position,
      uuid: uuid,
      writer: writer,
      fence: fence,
      owner: owner,
      intent: intent,
      snapshot: snapshot
    }
  end

  defp persisted(snapshot),
    do: %{snapshot | inventory: %{snapshot.inventory | state_id: 0, drag: nil}}

  defp read(ctx) do
    {:ok, saved} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    saved
  end

  defp prepare(ctx) do
    ref = make_ref()
    PlayerStore.prepare_placement(ctx.writer, ctx.fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, pending}}
    assert pending.transfer_sequence == 1 and pending.outbox == ctx.intent
    assert Inventory.get(pending.inventory, 45) == nil
    assert read(ctx) == persisted(pending)
    {fence, pending}
  end

  defp complete(ctx, fence) do
    ref = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, result}
    result
  end

  defp deliver(ctx, pending) do
    token = make_ref()
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, pending)
    assert_receive {:transfer_delivered, worker, ^token, result}
    assert worker == job.pid
    Process.demonitor(job.monitor, [:flush])
    result
  end

  defp restart(ctx) do
    :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(ctx.owner, 0))
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, writer, restored, fence} = PlayerStore.open(ctx.uuid)
    {%{ctx | writer: writer, owner: owner}, restored, fence}
  end

  test "durable consumption waits for matching proof and repeated completion cannot consume again",
       ctx do
    {fence, pending} = prepare(ctx)
    assert {:error, :transfer_not_applied} = complete(ctx, fence)
    assert {:error, :stale_player_snapshot} = complete(ctx, ctx.fence)
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, fence, ctx.snapshot, ref)
    assert_receive {:player_saved, ^ref, {:error, :transfer_pending}}
    assert World.get_block(ctx.position) == 0
    assert {:ok, :applied} = deliver(ctx, pending)
    assert {:ok, :already_applied} = deliver(ctx, pending)
    assert {:ok, next_fence, final} = complete(ctx, fence)
    assert final.outbox == nil and final.transfer_sequence == 1
    assert Inventory.get(final.inventory, 45) == nil
    assert World.get_block(ctx.position) == 1
    assert read(ctx) == persisted(final)
    assert {:error, :no_pending_transfer} = complete(ctx, next_fence)
    assert {:error, :stale_player_snapshot} = complete(ctx, fence)
  end

  test "source and destination restart reject an uncommitted permit and refund the exact last item",
       ctx do
    effects = %{11 => [{300, 0, false, true, true}]}
    ctx = %{ctx | snapshot: Map.put(ctx.snapshot, :effects, effects)}
    {_fence, pending} = prepare(ctx)
    {ctx, restored, fence} = restart(ctx)
    assert restored == persisted(pending)
    assert {:ok, :rejected} = deliver(ctx, restored)
    assert {:ok, :already_rejected} = deliver(ctx, restored)
    assert {:ok, _, final} = complete(ctx, fence)
    assert final.transfer_sequence == 1 and final.outbox == nil
    assert Inventory.get(final.inventory, 45) == ctx.intent.before
    assert read(ctx) == persisted(final)
    assert final.effects == effects
    assert World.get_block(ctx.position) == 0
    assert {:ok, :already_rejected} = deliver(ctx, pending)
  end

  test "lost applied reply survives both restarts and cannot overwrite a later replacement",
       ctx do
    {_fence, pending} = prepare(ctx)
    assert {:ok, :applied} = deliver(ctx, pending)
    assert :ok = World.set_block(ctx.position, 10)
    assert :ok = Region.flush(elem(ctx.owner, 0))
    {ctx, restored, fence} = restart(ctx)
    assert {:ok, :already_applied} = deliver(ctx, restored)
    assert {:ok, _, final} = complete(ctx, fence)
    assert final.outbox == nil and Inventory.get(final.inventory, 45) == nil
    assert World.get_block(ctx.position) == 10
  end

  test "a mining receipt with the same source and sequence cannot clear a placement journal",
       ctx do
    {fence, pending} = prepare(ctx)
    {:ok, mining} = Region.reserve_mining(ctx.owner, [ctx.position])
    request = Map.merge(mining, %{source: ctx.uuid, sequence: 1, records: []})
    assert {:ok, :applied} = Region.apply_mining_transfer(ctx.owner, request)
    assert {:error, :transfer_conflict} = complete(ctx, fence)
    assert {:error, :transfer_conflict} = deliver(ctx, pending)
    assert read(ctx) == persisted(pending)
    assert :sys.get_state(ctx.writer).snapshot == pending
  end

  test "failed source persistence retires its lease without delivering a block mutation", ctx do
    File.mkdir_p!(PlayerStore.path(ctx.base, ctx.uuid))
    monitor = Process.monitor(ctx.writer)
    ref = make_ref()

    capture_log(fn ->
      PlayerStore.prepare_placement(ctx.writer, ctx.fence, ctx.snapshot, ctx.intent, ref)
      assert_receive {:player_transfer_saved, ^ref, {:error, :player_commit_uncertain}}
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end)

    assert World.get_block(ctx.position) == 0
    assert {:error, :missing_transfer_receipt} = Region.item_transfer_receipt(ctx.owner, ctx.uuid)
  end

  test "closing after death resolves rejection before transferring the refunded item", ctx do
    {fence, pending} = prepare(ctx)
    assert :ok = Region.release_placement(ctx.owner, ctx.intent.permit)

    later = %{
      pending
      | health: %{value: 0.0, hurt_ticks: 7, death_ticks: 0},
        food: %PlayerFood{level: 7, saturation: 0.0, exhaustion: 3.5, timer: 79}
    }

    later = Map.put(later, :fire_ticks, -20)
    later = Map.put(later, :effects, %{11 => [{7, 0, false, true, true}]})

    monitor = Process.monitor(ctx.writer)
    assert :ok = PlayerStore.close_session(ctx.writer, fence, later)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    final = read(ctx)
    assert final.outbox == nil and final.transfer_sequence == 2 and final.inventory.slots == %{}
    assert final.health == later.health and final.food == later.food
    assert final.fire_ticks == -20
    assert final.effects == later.effects
    assert World.get_block(ctx.position) == 0

    {:ok, %{records: records}} =
      ItemRecords.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)

    assert Enum.sort(Enum.map(records, & &1.stack)) ==
             Enum.sort([ctx.intent.before, ItemStack.new("iron_helmet")])
  end
end
