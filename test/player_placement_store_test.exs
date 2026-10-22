defmodule Valimc.PlayerPlacementStoreTest do
  use ExUnit.Case, async: true

  alias Valimc.{
    Connection,
    GameMode,
    Inventory,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore,
    TransferDelivery
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region

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
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
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
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, pending, :overworld)
    assert_receive {:transfer_delivered, worker, ^token, result}
    assert worker == job.pid
    Process.demonitor(job.monitor, [:flush])
    result
  end

  defp restart(ctx) do
    :ok = DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, ctx.writer)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(ctx.owner, 0))
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    {:ok, writer, restored, fence} = PlayerStore.open(ctx.uuid)
    {%{ctx | writer: writer, owner: owner}, restored, fence}
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
    assert Valimc.TestBlocks.get(ctx.position) == 0
    assert {:ok, :already_rejected} = deliver(ctx, pending)
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
end
