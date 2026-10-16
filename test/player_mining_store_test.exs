defmodule Valimc.PlayerMiningStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

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
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-source-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {30_000 + rem(nonce, 10_000), 600}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    name = "Mine#{nonce}"
    uuid = Connection.offline_uuid(name)
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
      for {live, player} <- :ets.tab2list(Valimc.Players),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, live)

      for {live, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, live)

      for {live, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, live)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      position: position,
      name: name,
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
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, snapshot}}, 2000
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
    assert_receive {:player_transfer_saved, ^ref, result}, 2000
    result
  end

  defp deliver(ctx, snapshot) do
    token = make_ref()
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, snapshot)
    assert_receive {:transfer_delivered, worker, ^token, result}, 3000
    assert worker == job.pid
    Process.demonitor(job.monitor, [:flush])
    result
  end

  defp restart_region(ctx) do
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(ctx.owner, 0))
    {:ok, next} = World.item_owner(ctx.key)
    next
  end

  test "prepared final-use wear waits for the correct durable receipt and is not replayed", ctx do
    {fence, pending} = prepare(ctx)
    assert {:error, :transfer_not_applied} = complete(ctx, fence)
    assert {:error, :stale_player_snapshot} = complete(ctx, ctx.fence)
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, fence, ctx.snapshot, ref)
    assert_receive {:player_saved, ^ref, {:error, :transfer_pending}}
    assert World.get_block(ctx.position) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
    assert {:ok, :applied} = deliver(ctx, pending)
    assert {:ok, :already_applied} = deliver(ctx, pending)
    assert World.get_block(ctx.position) == Data.block("air")
    assert map_size(World.item_snapshot(ctx.key)) == 1
    assert {:ok, final_fence, final} = complete(ctx, fence)
    assert final.outbox == nil and final.transfer_sequence == 1
    assert Inventory.get(final.inventory, 43) == nil
    assert final.food == ctx.snapshot.food and final.air_supply == 154
    assert {:error, :no_pending_transfer} = complete(ctx, final_fence)
  end

  test "sampled random loot is journaled exactly and never changes on delivery or restart", ctx do
    :ok = Region.release_mining(ctx.owner, ctx.intent.permit)
    block = Data.item_block(Data.item("melon"))
    :ok = World.set_block(ctx.position, block)
    {:ok, reservation} = Region.reserve_mining(ctx.owner, [ctx.position])

    tool = %{
      ctx.intent.before
      | components:
          Map.put(ctx.intent.before.components, "minecraft:enchantments", %{
            "minecraft:fortune" => 2
          })
    }

    # Base3+draw2 and Fortune draw1 yield exactly6; no draw tape belongs in recovery.
    {:ok, [stack]} =
      Valimc.Physics.RandomMiningLoot.drops(block, tool, true, fn
        5 -> 2
        3 -> 1
      end)

    assert stack == ItemStack.new("melon_slice", 6)
    {after_tool, _} = ToolDurability.mine(tool, block, false)
    records = [%{hd(ctx.intent.records) | stack: stack}]

    intent =
      ctx.intent
      |> Map.merge(reservation)
      |> Map.merge(%{before: tool, after: after_tool, records: records})

    snapshot = put_in(ctx.snapshot, [:inventory, Access.key(:slots), 43], tool)
    ctx = %{ctx | intent: intent, snapshot: snapshot}
    {_fence, pending} = prepare(ctx)
    assert pending.outbox.records == records
    assert {:ok, :applied} = deliver(ctx, pending)
    assert {:ok, :already_applied} = deliver(ctx, pending)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    _owner = restart_region(ctx)
    {:ok, writer, restored, fence} = PlayerStore.open(ctx.uuid)
    ctx = %{ctx | writer: writer}
    assert restored.outbox.records == records
    assert {:ok, :already_applied} = deliver(ctx, restored)
    assert {:ok, _, final} = complete(ctx, fence)
    assert final.outbox == nil and final.transfer_sequence == 1
    assert Inventory.get(final.inventory, 43) == nil
    assert World.get_block(ctx.position) == 0

    {:ok, ledger} =
      Valimc.World.ItemRecords.decode(
        File.read!(Valimc.World.Store.item_path(ctx.base, ctx.key)),
        ctx.key
      )

    assert ledger.records == records
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
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000

    assert {:ok, final} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert final.outbox == nil and final.transfer_sequence == 2
    assert final.health == later.health and final.food == later.food
    assert final.fire_ticks == -20
    assert final.inventory.slots == %{}
    assert World.get_block(ctx.position) == Data.block("stone")

    {:ok, %{records: records}} =
      Valimc.World.ItemRecords.decode(
        File.read!(Valimc.World.Store.item_path(ctx.base, ctx.key)),
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

  test "failed source persistence retires the lease before any destination delivery", ctx do
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(path)
    monitor = Process.monitor(ctx.writer)
    ref = make_ref()

    capture_log(fn ->
      PlayerStore.prepare_mining(ctx.writer, ctx.fence, ctx.snapshot, ctx.intent, ref)
      assert_receive {:player_transfer_saved, ^ref, {:error, :player_commit_uncertain}}, 2000
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2000
    end)

    assert World.get_block(ctx.position) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "real TCP login resolves a rejected mining intent before publishing refunded inventory",
       ctx do
    {_fence, _pending} = prepare(ctx)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    _owner = restart_region(ctx)
    {uuid, client} = Client.login_session(Client.begin_login(ctx.name), ctx.name)
    assert uuid == ctx.uuid
    client = Client.load_world(client)
    assert Enum.at(client.inventory.items, 43) == ctx.intent.before

    assert {:ok, saved} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved.outbox == nil and saved.transfer_sequence == 1
    player = Enum.find(Valimc.Players.all(), &(&1.name == ctx.name))
    state = :sys.get_state(player.pid)
    assert state.recovery == nil and Inventory.get(state.inventory, 43) == ctx.intent.before
    assert state.player.food.level == 18 and state.player.air_supply == 154
    assert World.get_block(ctx.position) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
    Client.close(client)
  end
end
