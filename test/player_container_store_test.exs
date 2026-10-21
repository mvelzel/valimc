defmodule Valimc.PlayerContainerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope

  alias Valimc.{
    GameMode,
    Inventory,
    PlayerContainerIntent,
    PlayerFood,
    PlayerSnapshot,
    PlayerStore,
    TransferDelivery,
    World
  }

  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Containers, ContainerTransfers, Region, Store}

  setup do
    nonce = System.unique_integer([:positive])
    uuid = <<nonce::128>>
    key = {20000 + rem(nonce, 3333) * 3, 3300}
    span = Valimc.config(:region_size) * 16
    position = {elem(key, 0) * span + 1, 64, elem(key, 1) * span + 1}
    base = Path.join(System.tmp_dir!(), "valimc-container-player-#{nonce}")
    TestScope.isolate([key, uuid], world_path: base)
    File.mkdir_p!(base)

    inventory = %Inventory{
      carried: ItemStack.new("diamond", 3),
      slots: %{5 => ItemStack.new("iron_helmet")}
    }

    snapshot = %{
      pose: %{
        x: elem(position, 0) + 0.5,
        y: 64.0,
        z: elem(position, 2) + 0.5,
        yaw: 0.0,
        pitch: 0.0
      },
      inventory: inventory,
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 19.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      transfer_sequence: 0,
      outbox: nil
    }

    {:ok, containers, entry} = Containers.create(%Containers{}, key, position, 3)
    {:ok, containers, _} = ContainerTransfers.reserve(containers, uuid)

    intent = %{
      kind: :container,
      key: key,
      request: %{
        source: uuid,
        sequence: 1,
        permit: <<nonce + 1::128>>,
        position: position,
        revision: entry.revision,
        rows: 3,
        slots: entry.slots,
        inventory: inventory,
        action: :pickup,
        slot: 0,
        button: 0
      }
    }

    on_exit(fn ->
      for {registry, key} <- [
            {Valimc.PlayerStoreRegistry, uuid},
            {Valimc.RegionRegistry, key},
            {Valimc.RegionStoreRegistry, key}
          ],
          {pid, _} <- Registry.lookup(registry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{
      uuid: uuid,
      key: key,
      base: base,
      snapshot: snapshot,
      intent: intent,
      containers: containers
    }
  end

  defp prepare(ctx) do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    ref = make_ref()
    PlayerStore.prepare_container(writer, fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, next_fence, pending}}
    assert pending.inventory == ctx.snapshot.inventory and pending.outbox.kind == :container

    assert {:ok, disk} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert disk.inventory == pending.inventory and disk.outbox == pending.outbox
    {writer, next_fence, pending}
  end

  defp write_decision(ctx, pending, eligible) do
    {:ok, _, request, _} = PlayerContainerIntent.request(ctx.uuid, 1, pending.outbox)
    {:ok, decision} = ContainerTransfers.plan(ctx.containers, ctx.key, request, eligible)
    {:ok, writer, lease} = Store.open(ctx.key)
    assert :ok = Store.flush_containers(writer, lease, decision.containers)
    assert :ok = Store.close(writer, lease)
    decision
  end

  test "player writer death retains original items and sealing reads the owned durable container receipt",
       ctx do
    {writer, fence, pending} = prepare(ctx)
    ref = make_ref()
    PlayerStore.checkpoint(writer, fence, %{ctx.snapshot | inventory: %Inventory{}}, ref)
    assert_receive {:player_saved, ^ref, {:error, :transfer_pending}}
    decision = write_decision(ctx, pending, true)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
    {:ok, replacement, restored, next_fence} = PlayerStore.open(ctx.uuid)
    assert restored.inventory == ctx.snapshot.inventory and restored.outbox == pending.outbox
    ref = make_ref()
    PlayerStore.complete_transfer(replacement, next_fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, sealed_fence, sealed}}

    assert sealed.inventory.carried == nil and
             sealed.inventory.slots == ctx.snapshot.inventory.slots

    assert sealed.outbox == nil and sealed.transfer_sequence == 1 and
             sealed.health == ctx.snapshot.health

    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, {key, receipt}} = Region.container_transfer_receipt(owner, ctx.uuid)
    assert key == ctx.key and receipt == decision.containers.receipts[ctx.uuid]

    assert {:error, :stale_region} =
             Region.container_transfer_receipt({elem(owner, 0), make_ref()}, ctx.uuid)

    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, elem(owner, 0))
    assert {:ok, replacement_owner} = World.item_owner(ctx.key)
    assert replacement_owner != owner

    assert {:ok, {^key, ^receipt}} =
             Region.container_transfer_receipt(replacement_owner, ctx.uuid)

    ref = make_ref()
    PlayerStore.complete_transfer(replacement, sealed_fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:error, :no_pending_transfer}}

    assert {:ok, %{outbox: nil, transfer_sequence: 1, inventory: inventory}} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert inventory.carried == nil and inventory.slots == sealed.inventory.slots
  end

  defp admit(ctx) do
    {:ok, bytes} = Containers.encode(ctx.key, %{ctx.containers | receipts: %{}})
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    block = hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])
    :ok = World.set_block(ctx.intent.request.position, block)
    {:ok, owner} = World.item_owner(ctx.key)
    {x, y, z} = ctx.intent.request.position
    # The player's 250 ms grant starts now: not while the owner still writes the block.
    quiescent(owner)

    actor = %{
      uuid: ctx.uuid,
      mode: :survival,
      eye: {x + 0.5, y + 1.6, z + 0.5},
      health: 19.0,
      expires: Valimc.TestRegion.grant_expires()
    }

    assert {:ok, request} = Region.admit_container_transfer(owner, ctx.intent.request, actor)
    assert request.permit != ctx.intent.request.permit
    assert {:ok, {_, %{sequence: 0}}} = Region.container_transfer_receipt(owner, ctx.uuid)
    {owner, %{ctx | intent: %{ctx.intent | request: request}}, actor}
  end

  test "admitted source preparation and bounded delivery exchange items exactly once", ctx do
    {owner, ctx, _actor} = admit(ctx)
    {writer, fence, pending} = prepare(ctx)
    token = make_ref()
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, pending)
    assert_receive {:transfer_delivered, _, ^token, {:ok, :applied}}
    Process.demonitor(job.monitor, [:flush])
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}
    assert sealed.outbox == nil and sealed.inventory.carried == nil
    assert sealed.inventory.slots == ctx.snapshot.inventory.slots
    assert {:ok, :already_applied} = Region.container_transfer(owner, pending.outbox.request)

    {:ok, stored} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    assert elem(stored.entries[ctx.intent.request.position].slots, 0) ==
             ItemStack.new("diamond", 3)

    assert stored.sequence == 2 and stored.receipts[ctx.uuid].sequence == 1
  end

  test "two admitted players with the same view cannot both spend its container revision", ctx do
    {owner, ctx, actor} = admit(ctx)
    source = :crypto.strong_rand_bytes(16)
    request = %{ctx.intent.request | source: source}
    quiescent(owner)
    actor = %{actor | uuid: source, expires: Valimc.TestRegion.grant_expires()}
    assert {:ok, competing} = Region.admit_container_transfer(owner, request, actor)
    assert {:ok, :applied} = Region.container_transfer(owner, ctx.intent.request)
    assert {:ok, :rejected} = Region.container_transfer(owner, competing)
    assert {:ok, :already_applied} = Region.container_transfer(owner, ctx.intent.request)
    assert {:ok, :already_rejected} = Region.container_transfer(owner, competing)

    {:ok, stored} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    assert stored.sequence == 2
    assert elem(stored.entries[request.position].slots, 0) == ItemStack.new("diamond", 3)
    assert stored.receipts[ctx.uuid].sequence == 1 and stored.receipts[source].sequence == 1
  end

  # No durable write in flight, so a request computed now is answered at once (VMC-073).
  defp quiescent({pid, _}),
    do:
      Valimc.TestWait.until(fn ->
        not Valimc.TestRegion.writing?(:sys.get_state(pid).resource)
      end)
end
