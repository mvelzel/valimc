defmodule Valimc.PlayerMiningStoreTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore,
    ToolDurability,
    TransferDelivery,
    World
  }

  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-source-#{nonce}")
    key = {30_000 + rem(nonce, 3_333) * 3, 600}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    name = "Mine#{nonce}"
    uuid = Connection.offline_uuid(name)
    Valimc.TestScope.isolate([uuid | Valimc.TestScope.neighborhood(key)], world_path: base)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)
    {:ok, {pid, _} = owner} = World.item_owner(key)
    assert :ok = World.set_block(position, Data.block("stone"))
    assert :ok = Region.flush(pid)
    {:ok, reservation} = Region.reserve_mining(owner, [position])

    before_tool = %{
      ItemStack.new("iron_pickaxe")
      | components: %{
          "minecraft:damage" => 249,
          "minecraft:custom_data" => {:compound, %{"proof" => {:string, "source"}}}
        }
    }

    {after_tool, _} = ToolDurability.mine(before_tool, Data.block("stone"), false)
    {x, _, z} = position

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: 63.5,
      z: z + 0.5,
      stack: ItemStack.new("cobblestone")
    }

    intent =
      Map.merge(reservation, %{
        kind: :mining,
        key: key,
        target: position,
        slot: 43,
        before: before_tool,
        after: after_tool,
        records: [record]
      })

    snapshot = %{
      pose: %{x: x + 5.5, y: 64.0, z: z + 5.5, yaw: 0.0, pitch: 0.0},
      inventory: %Inventory{
        selected: 7,
        slots: %{43 => before_tool, 5 => ItemStack.new("iron_helmet")}
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

  defp prepare(ctx) do
    ref = make_ref()
    PlayerStore.prepare_mining(ctx.writer, ctx.fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, snapshot}}
    assert snapshot.transfer_sequence == 1 and snapshot.outbox.before == ctx.intent.before
    assert Inventory.get(snapshot.inventory, 43) == ctx.intent.after

    assert {:ok, saved} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved == persisted(snapshot)

    {fence, snapshot}
  end

  defp persisted(snapshot),
    do: %{snapshot | inventory: %{snapshot.inventory | state_id: 0, drag: nil}}

  defp complete(ctx, fence) do
    ref = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, result}
    result
  end

  defp deliver(ctx, snapshot) do
    token = make_ref()
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, snapshot)
    assert_receive {:transfer_delivered, worker, ^token, result}
    assert worker == job.pid
    Process.demonitor(job.monitor, [:flush])
    result
  end

  defp restart_region(ctx) do
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(ctx.owner, 0))
    {:ok, next} = World.item_owner(ctx.key)
    next
  end

  test "source and destination restart reject an uncommitted permit and refund the exact tool once",
       ctx do
    {_fence, pending} = prepare(ctx)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    _owner = restart_region(ctx)
    {:ok, writer, restored, fence} = PlayerStore.open(ctx.uuid)
    assert restored == persisted(pending)
    ctx = %{ctx | writer: writer}
    assert {:ok, :rejected} = deliver(ctx, restored)
    assert {:ok, :already_rejected} = deliver(ctx, restored)
    assert {:ok, _, final} = complete(ctx, fence)
    assert final.transfer_sequence == 1 and final.outbox == nil
    assert Inventory.get(final.inventory, 43) == ctx.intent.before
    assert World.get_block(ctx.position) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}

    assert {:ok, saved} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved == persisted(final)

    assert {:ok, :already_rejected} = deliver(ctx, pending)
  end

  test "lost applied reply and removed drop keep wear without destroying a replacement block",
       ctx do
    {_fence, pending} = prepare(ctx)
    assert {:ok, :applied} = deliver(ctx, pending)
    {:ok, handle} = Region.find_item(ctx.owner, hd(ctx.intent.records).uuid)
    assert :ok = Region.remove_item(handle)
    assert :ok = World.set_block(ctx.position, Data.block("dirt"))
    assert :ok = Region.flush(elem(ctx.owner, 0))
    assert :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    _owner = restart_region(ctx)
    {:ok, writer, restored, fence} = PlayerStore.open(ctx.uuid)
    ctx = %{ctx | writer: writer}
    assert {:ok, :already_applied} = deliver(ctx, restored)
    assert {:ok, _, final} = complete(ctx, fence)
    assert Inventory.get(final.inventory, 43) == nil and final.outbox == nil
    assert final.transfer_sequence == 1 and World.item_snapshot(ctx.key) == %{}
    assert World.get_block(ctx.position) == Data.block("dirt")
  end

  test "closing rejection retains current food/health and death cleanup transfers the refunded gear",
       ctx do
    {fence, pending} = prepare(ctx)
    _owner = restart_region(ctx)

    later = %{
      pending
      | health: %{value: 0.0, hurt_ticks: 7, death_ticks: 0},
        food: %PlayerFood{level: 7, saturation: 0.0, exhaustion: 3.5, timer: 79}
    }

    later = Map.put(later, :fire_ticks, -20)

    monitor = Process.monitor(ctx.writer)
    assert :ok = PlayerStore.close_session(ctx.writer, fence, later)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}

    assert {:ok, final} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert final.outbox == nil and final.transfer_sequence == 2
    assert final.health == later.health and final.food == later.food
    assert final.fire_ticks == -20
    assert final.inventory.slots == %{}
    assert World.get_block(ctx.position) == Data.block("stone")

    {:ok, %{records: records}} =
      Valimc.World.ItemRecords.decode(
        Valimc.TestDisk.read(ctx.base, ctx.key, :items),
        ctx.key
      )

    assert length(records) == 2

    assert Enum.sort(Enum.map(records, & &1.stack)) ==
             Enum.sort([ctx.intent.before, ItemStack.new("iron_helmet")])
  end

  test "source preparation refuses unrelated tool changes, mode mismatches and stale journals",
       ctx do
    for invalid <- [
          %{ctx.intent | after: ctx.intent.before},
          %{ctx.intent | after: ItemStack.new("diamond_pickaxe")},
          %{ctx.intent | slot: 36},
          %{ctx.intent | before: nil}
        ] do
      assert {:error, :invalid_mining_plan} =
               Valimc.PlayerMiningTransfers.prepare(ctx.uuid, 0, ctx.snapshot, invalid)
    end

    for invalid <- [
          %{ctx.snapshot | game_mode: GameMode.new(:creative)},
          %{ctx.snapshot | game_mode: GameMode.new(:adventure)},
          %{ctx.snapshot | health: %{value: 0.0, hurt_ticks: 0, death_ticks: 0}},
          %{ctx.snapshot | transfer_sequence: 7},
          %{ctx.snapshot | outbox: %{key: ctx.key, records: ctx.intent.records}},
          %{ctx.snapshot | inventory: %{ctx.snapshot.inventory | infinite_materials: true}}
        ] do
      assert {:error, :invalid_mining_plan} =
               Valimc.PlayerMiningTransfers.prepare(ctx.uuid, 0, invalid, ctx.intent)
    end

    assert {:error, :invalid_mining_plan} =
             Valimc.PlayerMiningTransfers.prepare(
               ctx.uuid,
               18_446_744_073_709_551_615,
               ctx.snapshot,
               ctx.intent
             )
  end
end
