defmodule Valimc.PlayerPickupStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Valimc.{
    GameMode,
    Inventory,
    ItemMotionState,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore,
    World
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, ItemReceipts, Items, PickupTransfers, Store}

  setup do
    n = System.unique_integer([:positive])
    key = {51000 + rem(n, 10000), 1100}
    base = Path.join(System.tmp_dir!(), "valimc-pickup-source-#{n}")
    File.mkdir_p!(base)
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    uuid = <<n::128>>

    stack = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    record = %{
      uuid: <<n + 1::128>>,
      x: elem(key, 0) * 128 + 8.5,
      y: 64.0,
      z: elem(key, 1) * 128 + 8.5,
      stack: stack,
      motion: %ItemMotionState{}
    }

    {:ok, items} = Items.restore(key, [record])
    {:ok, receipts, :reserved} = ItemReceipts.reserve(%{}, uuid)
    {:ok, bytes} = ItemLedger.encode(key, [record], receipts, items.ledger)
    File.write!(Store.item_path(base, key), bytes)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)

    snapshot = %{
      pose: Map.merge(Map.take(record, [:x, :y, :z]), %{yaw: 0.0, pitch: 0.0}),
      inventory: %Inventory{selected: 3, slots: %{5 => ItemStack.new("iron_helmet")}},
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

    intent = %{
      kind: :pickup,
      key: key,
      request: %{
        source: uuid,
        sequence: 1,
        permit: <<n + 2::128>>,
        item_uuid: record.uuid,
        generation: 0,
        before: stack,
        remainder: nil
      }
    }

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      key: key,
      base: base,
      uuid: uuid,
      writer: writer,
      fence: fence,
      snapshot: snapshot,
      intent: intent,
      items: items,
      receipts: receipts
    }
  end

  defp read(ctx) do
    {:ok, s} = PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)
    s
  end

  defp prepare(ctx) do
    ref = make_ref()
    PlayerStore.prepare_pickup(ctx.writer, ctx.fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, pending}}, 2000
    assert pending.inventory == ctx.snapshot.inventory and read(ctx) == pending
    {fence, pending}
  end

  defp complete(ctx, fence) do
    ref = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, result}, 2000
    result
  end

  # A consistent recovery cut: source intent already fsynced; write the complete
  # pure region commit before its lazy owner exists, then verify real owner proof.
  defp terminal(ctx, eligible, corrupt \\ false) do
    assert Registry.lookup(Valimc.RegionRegistry, ctx.key) == []

    {:ok, plan} =
      PickupTransfers.plan(ctx.items, ctx.receipts, ctx.key, ctx.intent.request, eligible)

    receipts =
      if corrupt,
        do: Map.update!(plan.receipts, ctx.uuid, &%{&1 | digest: <<1::256>>}),
        else: plan.receipts

    {:ok, bytes} =
      ItemLedger.encode(ctx.key, Items.records(plan.items), receipts, plan.items.ledger)

    File.write!(Store.item_path(ctx.base, ctx.key), bytes)
  end

  defp reopen(ctx) do
    if Process.alive?(ctx.writer),
      do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)

    {:ok, writer, snapshot, fence} = PlayerStore.open(ctx.uuid)
    {%{ctx | writer: writer, fence: fence}, snapshot}
  end

  test "a saved intent blocks competing writes and a reservation never grants inventory", ctx do
    {fence, pending} = prepare(ctx)
    assert {:error, :stale_player_snapshot} = complete(ctx, ctx.fence)
    assert {:error, :stale_transfer} = complete(ctx, fence)
    assert read(ctx) == pending
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, fence, ctx.snapshot, ref)
    assert_receive {:player_saved, ^ref, {:error, :transfer_pending}}, 2000
    ref = make_ref()
    PlayerStore.prepare_pickup(ctx.writer, fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:error, :transfer_pending}}, 2000
  end

  test "source restart resolves actual region proof once and persists the gained inventory",
       ctx do
    effects = %{11 => [{2, 1, false, true, true}, {-1, 0, true, false, true}]}
    ctx = %{ctx | snapshot: Map.put(ctx.snapshot, :effects, effects)}
    {_fence, pending} = prepare(ctx)
    terminal(ctx, true)
    {ctx, ^pending} = reopen(ctx)
    assert {:ok, _fence, resolved} = complete(ctx, ctx.fence)
    assert resolved.inventory.slots[36] == ctx.intent.request.before and resolved.outbox == nil
    assert resolved.transfer_sequence == 1
    {ctx, restored} = reopen(ctx)
    assert restored.inventory.slots == resolved.inventory.slots and restored.outbox == nil
    assert restored.effects == effects and resolved.effects == effects
    assert {:error, :no_pending_transfer} = complete(ctx, ctx.fence)
    assert {:ok, {owner, _}} = World.item_owner(ctx.key)
    assert :sys.get_state(owner).resource.items.entries == %{}
  end

  test "terminal rejection clears without gain", ctx do
    {fence, _} = prepare(ctx)
    terminal(ctx, false)
    assert {:ok, _fence, resolved} = complete(ctx, fence)
    assert resolved.inventory == ctx.snapshot.inventory and resolved.outbox == nil
    assert read(ctx).transfer_sequence == 1
  end

  test "counterfeit region proof cannot grant inventory", ctx do
    {fence, pending} = prepare(ctx)
    terminal(ctx, true, true)
    assert {:error, :transfer_conflict} = complete(ctx, fence)
    assert read(ctx) == pending
  end

  test "failed final source save retains recoverable intent without restoring the withdrawn world item",
       ctx do
    {fence, pending} = prepare(ctx)
    terminal(ctx, true)
    File.write!(Path.join(ctx.base, "blocked"), "file")
    :sys.replace_state(ctx.writer, &%{&1 | path: Path.join(ctx.base, "blocked/player")})
    monitor = Process.monitor(ctx.writer)

    capture_log(fn ->
      assert {:error, :player_commit_uncertain} = complete(ctx, fence)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2000
    end)

    assert read(ctx) == pending
    {ctx, ^pending} = reopen(ctx)
    assert {:ok, _fence, resolved} = complete(ctx, ctx.fence)
    assert resolved.inventory.slots[36] == ctx.intent.request.before and resolved.outbox == nil
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    assert :sys.get_state(pid).resource.items.entries == %{}
  end
end
