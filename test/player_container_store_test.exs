defmodule Valimc.PlayerContainerStoreTest do
  use ExUnit.Case, async: false

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
  alias Valimc.World.{Containers, ContainerTransfers, ItemLedger, Region, Store}

  setup do
    nonce = System.unique_integer([:positive])
    uuid = <<nonce::128>>
    key = {20000 + rem(nonce, 10000), 3300}
    span = Valimc.config(:region_size) * 16
    position = {elem(key, 0) * span + 1, 64, elem(key, 1) * span + 1}
    base = Path.join(System.tmp_dir!(), "valimc-container-player-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
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
      for {registry, supervisor, key} <- [
            {Valimc.PlayerStoreRegistry, Valimc.PlayerStoreSupervisor, uuid},
            {Valimc.RegionRegistry, Valimc.RegionSupervisor, key},
            {Valimc.RegionStoreRegistry, Valimc.RegionStoreSupervisor, key}
          ],
          {pid, _} <- Registry.lookup(registry, key),
          do: DynamicSupervisor.terminate_child(supervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
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
    assert_receive {:player_transfer_saved, ^ref, {:ok, next_fence, pending}}, 1500
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
    assert_receive {:player_saved, ^ref, {:error, :transfer_pending}}, 1000
    decision = write_decision(ctx, pending, true)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, 1000
    {:ok, replacement, restored, next_fence} = PlayerStore.open(ctx.uuid)
    assert restored.inventory == ctx.snapshot.inventory and restored.outbox == pending.outbox
    ref = make_ref()
    PlayerStore.complete_transfer(replacement, next_fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, sealed_fence, sealed}}, 1500

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
    assert_receive {:player_transfer_saved, ^ref, {:error, :no_pending_transfer}}, 1000

    assert {:ok, %{outbox: nil, transfer_sequence: 1, inventory: inventory}} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert inventory.carried == nil and inventory.slots == sealed.inventory.slots
  end

  test "durable rejected proof retains the original player items without rewinding its sequence",
       ctx do
    {writer, fence, pending} = prepare(ctx)
    write_decision(ctx, pending, false)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500

    assert sealed.inventory == ctx.snapshot.inventory and sealed.outbox == nil and
             sealed.transfer_sequence == 1
  end

  test "an item-transfer receipt cannot seal a container intent", ctx do
    {writer, fence, pending} = prepare(ctx)

    {:ok, bytes} =
      ItemLedger.encode(ctx.key, [], %{ctx.uuid => %{sequence: 1, digest: <<77::256>>}})

    File.write!(Store.item_path(ctx.base, ctx.key), bytes)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:error, :transfer_not_applied}}, 1500

    assert {:ok, saved} =
             PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    assert saved.inventory == pending.inventory and saved.outbox == pending.outbox
  end

  test "bounded delivery rejects an unadmitted intent once and lets the source seal without losing its items",
       ctx do
    {writer, fence, pending} = prepare(ctx)
    token = make_ref()
    assert {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, pending)
    assert_receive {:transfer_delivered, _, ^token, {:ok, :rejected} = result}, 1500
    Process.demonitor(job.monitor, [:flush])
    assert TransferDelivery.completed?(pending, result)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500

    assert sealed.inventory == ctx.snapshot.inventory and sealed.outbox == nil and
             sealed.transfer_sequence == 1

    {:ok, owner} = World.item_owner(ctx.key)

    assert {:ok, :already_rejected} =
             Region.recover_container_transfer(owner, pending.outbox.request)

    assert {:ok, containers} =
             Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert containers.entries == %{} and containers.receipts[ctx.uuid].sequence == 1
  end

  test "recovery returns an applied receipt even though the original gameplay grant is gone",
       ctx do
    {writer, fence, pending} = prepare(ctx)
    decision = write_decision(ctx, pending, true)
    token = make_ref()
    {:ok, job} = TransferDelivery.start(self(), token, ctx.uuid, pending)
    assert_receive {:transfer_delivered, _, ^token, {:ok, :already_applied}}, 1500
    Process.demonitor(job.monitor, [:flush])
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500
    assert sealed.inventory.carried == nil and sealed.outbox == nil

    {:ok, containers} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert containers == decision.containers
  end

  test "a recovery outcome is not published or acknowledged before the suspended writer commits",
       ctx do
    {_writer, _fence, pending} = prepare(ctx)
    {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    writer = :sys.get_state(pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.recover_container_transfer(owner, pending.outbox.request) end)

    try do
      await(fn ->
        match?(%{phase: :writing, kind: :container}, :sys.get_state(pid).resource.item_pending)
      end)

      assert Task.yield(task, 20) == nil

      assert {:error, :item_storage_busy} =
               Region.recover_container_transfer(owner, pending.outbox.request)

      assert {:error, :stale_region} =
               Region.recover_container_transfer({pid, make_ref()}, pending.outbox.request)

      assert {:error, :missing_container_receipt} =
               Region.container_transfer_receipt(owner, ctx.uuid)

      :sys.resume(writer)
      assert Task.await(task, 1500) == {:ok, :rejected}
      assert {:ok, {_, %{sequence: 1}}} = Region.container_transfer_receipt(owner, ctx.uuid)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "owner replacement recovers a committed rejection after its source has not sealed", ctx do
    {writer, fence, pending} = prepare(ctx)
    {:ok, {pid, _} = owner} = World.item_owner(ctx.key)
    assert {:ok, :rejected} = Region.recover_container_transfer(owner, pending.outbox.request)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
    {:ok, replacement} = World.item_owner(ctx.key)
    assert replacement != owner

    assert {:ok, :already_rejected} =
             Region.recover_container_transfer(replacement, pending.outbox.request)

    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500
    assert sealed.outbox == nil and sealed.inventory == ctx.snapshot.inventory
    assert sealed.transfer_sequence == 1
  end

  defp admit(ctx) do
    {:ok, bytes} = Containers.encode(ctx.key, %{ctx.containers | receipts: %{}})
    File.write!(Store.container_path(ctx.base, ctx.key), bytes)
    block = hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])
    :ok = World.set_block(ctx.intent.request.position, block)
    {:ok, owner} = World.item_owner(ctx.key)
    {x, y, z} = ctx.intent.request.position

    actor = %{
      uuid: ctx.uuid,
      mode: :survival,
      eye: {x + 0.5, y + 1.6, z + 0.5},
      health: 19.0,
      expires: System.monotonic_time(:millisecond) + 250
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
    assert_receive {:transfer_delivered, _, ^token, {:ok, :applied}}, 1500
    Process.demonitor(job.monitor, [:flush])
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500
    assert sealed.outbox == nil and sealed.inventory.carried == nil
    assert sealed.inventory.slots == ctx.snapshot.inventory.slots
    assert {:ok, :already_applied} = Region.container_transfer(owner, pending.outbox.request)

    {:ok, stored} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert elem(stored.entries[ctx.intent.request.position].slots, 0) ==
             ItemStack.new("diamond", 3)

    assert stored.sequence == 2 and stored.receipts[ctx.uuid].sequence == 1
  end

  test "owner replacement loses the uncommitted grant and rejects without taking source items",
       ctx do
    {{pid, _}, ctx, _actor} = admit(ctx)
    {writer, fence, pending} = prepare(ctx)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, :rejected} = Region.container_transfer(owner, pending.outbox.request)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, sealed}}, 1500
    assert sealed.inventory == ctx.snapshot.inventory and sealed.outbox == nil
  end

  test "admission checks fresh ownership, exact view and player context; removed blocks cannot apply",
       ctx do
    {{pid, _} = owner, ctx, actor} = admit(ctx)
    request = ctx.intent.request

    assert {:error, :stale_region} =
             Region.admit_container_transfer({pid, make_ref()}, request, actor)

    for actor <- [
          %{actor | uuid: <<99::128>>},
          %{actor | mode: :spectator},
          %{actor | mode: :creative},
          %{actor | health: 0},
          %{actor | eye: {0.0, 0.0, 0.0}}
        ] do
      assert {:error, :invalid_container_context} =
               Region.admit_container_transfer(owner, request, actor)
    end

    assert {:error, :invalid_container_admission} =
             Region.admit_container_transfer(
               owner,
               %{request | revision: request.revision + 1},
               actor
             )

    assert {:error, :invalid_container_context} =
             Region.admit_container_transfer(owner, %{request | rows: 6}, actor)

    :ok = World.set_block(request.position, 0)
    assert {:ok, :rejected} = Region.container_transfer(owner, request)
    assert {:ok, :already_rejected} = Region.recover_container_transfer(owner, request)

    assert {:error, :invalid_container_context} =
             Region.admit_container_transfer(owner, request, actor)
  end

  test "removing and recreating the same block cannot revive its old action permit", ctx do
    {owner, ctx, _actor} = admit(ctx)
    position = ctx.intent.request.position
    block = World.get_block(position)
    :ok = World.set_block(position, 0)
    :ok = World.set_block(position, block)
    assert {:ok, :rejected} = Region.container_transfer(owner, ctx.intent.request)

    {:ok, stored} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert stored.entries[position].slots == Tuple.duplicate(nil, 27)
  end

  test "a new player gets no permit before receipt reservation is durable; block edits cannot interleave",
       ctx do
    {{pid, _} = owner, ctx, actor} = admit(ctx)
    source = :crypto.strong_rand_bytes(16)
    request = %{ctx.intent.request | source: source}
    actor = %{actor | uuid: source, expires: System.monotonic_time(:millisecond) + 250}
    writer = :sys.get_state(pid).resource.store
    :sys.suspend(writer)
    task = Task.async(fn -> Region.admit_container_transfer(owner, request, actor) end)

    try do
      await(fn ->
        match?(%{phase: :writing, kind: :container}, :sys.get_state(pid).resource.item_pending)
      end)

      assert Task.yield(task, 20) == nil

      assert {:error, :missing_container_receipt} =
               Region.container_transfer_receipt(owner, source)

      assert {:error, :mining_storage_busy} = World.set_block(request.position, 0)

      refute Enum.any?(
               :sys.get_state(pid).resource.container_permits.entries,
               fn {_, grant} -> grant.source == source end
             )

      :sys.resume(writer)
      assert {:ok, admitted} = Task.await(task, 1500)
      assert {:ok, {_, %{sequence: 0}}} = Region.container_transfer_receipt(owner, source)
      assert Map.has_key?(:sys.get_state(pid).resource.container_permits.entries, admitted.permit)
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "two admitted players with the same view cannot both spend its container revision", ctx do
    {owner, ctx, actor} = admit(ctx)
    source = :crypto.strong_rand_bytes(16)
    request = %{ctx.intent.request | source: source}
    actor = %{actor | uuid: source, expires: System.monotonic_time(:millisecond) + 250}
    assert {:ok, competing} = Region.admit_container_transfer(owner, request, actor)
    assert {:ok, :applied} = Region.container_transfer(owner, ctx.intent.request)
    assert {:ok, :rejected} = Region.container_transfer(owner, competing)
    assert {:ok, :already_applied} = Region.container_transfer(owner, ctx.intent.request)
    assert {:ok, :already_rejected} = Region.container_transfer(owner, competing)

    {:ok, stored} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert stored.sequence == 2
    assert elem(stored.entries[request.position].slots, 0) == ItemStack.new("diamond", 3)
    assert stored.receipts[ctx.uuid].sequence == 1 and stored.receipts[source].sequence == 1
  end

  test "canonical candidate needs no socket-side sequence and does not persist until real preparation",
       ctx do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    draft = %{ctx.intent | request: Map.drop(ctx.intent.request, [:source, :sequence])}
    snapshot = %{ctx.snapshot | inventory: %{ctx.snapshot.inventory | state_id: 123}}
    ref = make_ref()
    PlayerStore.container_candidate(writer, fence, snapshot, draft, ref)
    assert_receive {:container_candidate, ^ref, {:ok, candidate}}, 1000
    assert candidate.request.source == ctx.uuid and candidate.request.sequence == 1
    assert candidate.request.inventory.state_id == 0
    refute File.exists?(PlayerStore.path(ctx.base, ctx.uuid))
    assert :sys.get_state(writer).snapshot == nil
    {_owner, ctx, _actor} = admit(%{ctx | intent: candidate})
    ref = make_ref()
    PlayerStore.prepare_container(writer, fence, snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _, prepared}}, 1000
    assert prepared.outbox == ctx.intent
    assert prepared.transfer_sequence == 1 and prepared.inventory == snapshot.inventory
  end

  test "occupied containers refuse direct/batch mutation and durably reject mining without item loss",
       ctx do
    position = ctx.intent.request.position
    entry = ctx.containers.entries[position]
    slots = put_elem(entry.slots, 0, ItemStack.new("diamond", 3))
    {:ok, containers, entry} = Containers.replace(ctx.containers, position, entry.revision, slots)
    request = %{ctx.intent.request | revision: entry.revision, slots: slots}

    block = hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])
    {rx, rz} = ctx.key

    File.write!(
      Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary({:valimc_region, 1, %{position => block}})
    )

    {owner, ctx, _actor} =
      admit(%{ctx | containers: containers, intent: %{ctx.intent | request: request}})

    block = World.get_block(position)
    {x, y, z} = position
    other = {x + 1, y, z}
    before = File.read!(Store.container_path(ctx.base, ctx.key))
    {:ok, observed} = Region.observe_blocks(owner, [position, other])
    assert {:error, :occupied_container} = World.remove_block(position)
    assert {:error, :occupied_container} = World.set_block(position, 0)

    assert {:error, :occupied_container} =
             Region.set_blocks(owner, observed.revision, %{position => 0, other => 1})

    assert World.get_block(position) == block and World.get_block(other) == observed.blocks[other]
    {:ok, unchanged} = Region.observe_blocks(owner, [])
    assert unchanged.revision == observed.revision
    {:ok, reservation} = Region.reserve_mining(owner, [position])
    transfer = Map.merge(reservation, %{source: ctx.uuid, sequence: 1, records: []})
    assert {:ok, :rejected} = Region.apply_mining_transfer(owner, transfer)
    assert {:ok, :already_rejected} = Region.apply_mining_transfer(owner, transfer)
    assert World.get_block(position) == block and World.item_snapshot(ctx.key) == %{}
    assert File.read!(Store.container_path(ctx.base, ctx.key)) == before
    assert {:ok, {_, receipt}} = Region.item_transfer_receipt(owner, ctx.uuid)

    assert {:ok, :rejected} =
             Valimc.World.MiningTransfers.receipt_result(ctx.key, transfer, receipt)

    assert :ok = World.set_block(position, block)
  end

  test "candidate refuses stale fences or pending transfers and never rewrites their journal",
       ctx do
    {writer, fence, pending} = prepare(ctx)
    before = File.read!(PlayerStore.path(ctx.base, ctx.uuid))

    for {fence, expected} <- [{make_ref(), :stale_player_snapshot}, {fence, :transfer_pending}] do
      ref = make_ref()
      PlayerStore.container_candidate(writer, fence, ctx.snapshot, ctx.intent, ref)
      assert_receive {:container_candidate, ^ref, {:error, ^expected}}, 1000
    end

    assert File.read!(PlayerStore.path(ctx.base, ctx.uuid)) == before
    assert :sys.get_state(writer).snapshot.outbox == pending.outbox
  end

  test "an old candidate cannot reuse a sequence after another action sealed", ctx do
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    draft = %{ctx.intent | request: Map.drop(ctx.intent.request, [:source, :sequence])}
    ref = make_ref()
    PlayerStore.container_candidate(writer, fence, ctx.snapshot, draft, ref)
    assert_receive {:container_candidate, ^ref, {:ok, old}}, 1000
    ref = make_ref()
    PlayerStore.prepare_container(writer, fence, ctx.snapshot, ctx.intent, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, pending}}, 1000
    write_decision(ctx, pending, false)
    ref = make_ref()
    PlayerStore.complete_transfer(writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, fence, _sealed}}, 1000
    before = File.read!(PlayerStore.path(ctx.base, ctx.uuid))
    snapshot = Map.delete(ctx.snapshot, :transfer_sequence)
    ref = make_ref()
    PlayerStore.prepare_container(writer, fence, snapshot, old, ref)
    assert_receive {:player_transfer_saved, ^ref, {:error, :invalid_container_plan}}, 1000
    ref = make_ref()
    PlayerStore.container_candidate(writer, fence, snapshot, draft, ref)
    assert_receive {:container_candidate, ^ref, {:ok, fresh}}, 1000
    assert fresh.request.sequence == 2 and fresh.request.source == ctx.uuid
    assert File.read!(PlayerStore.path(ctx.base, ctx.uuid)) == before
    assert :sys.get_state(writer).snapshot.transfer_sequence == 1
  end

  defp await(check, remaining \\ 100)
  defp await(_, 0), do: flunk("container recovery did not reach its expected boundary")

  defp await(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(check, remaining - 1)
        )
  end
end
