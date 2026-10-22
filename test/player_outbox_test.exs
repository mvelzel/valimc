defmodule Valimc.PlayerOutboxTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerStore, TestScope}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.Region
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-outbox-#{nonce}")
    uuid = :crypto.strong_rand_bytes(16)
    key = {300 + rem(nonce, 3_333) * 3, 300}
    TestScope.isolate([uuid, key], world_path: base)
    {:ok, writer, nil, fence} = PlayerStore.open(uuid)
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    before = PlayerState.capture(pose, %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})

    after_state =
      PlayerState.capture(pose, %Inventory{slots: %{36 => ItemStack.new("stone", 4)}})

    {rx, rz} = key

    records = [
      %{
        uuid: <<3::128>>,
        x: rx * 128 + 0.5,
        y: 64.5,
        z: rz * 128 + 0.5,
        stack: ItemStack.new("stone", 3)
      }
    ]

    on_exit(fn ->
      for {registry, scope} <- [{Valimc.PlayerStoreRegistry, uuid}, {Valimc.RegionRegistry, key}],
          {pid, _} <- Registry.lookup(registry, scope),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      uuid: uuid,
      writer: writer,
      fence: fence,
      key: key,
      before: before,
      after: after_state,
      records: records
    }
  end

  defp prepare(ctx, fence \\ nil) do
    ref = make_ref()

    PlayerStore.prepare_transfer(
      ctx.writer,
      fence || ctx.fence,
      ctx.before,
      ctx.after,
      ctx.key,
      ctx.records,
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, {:ok, next_fence, snapshot}}
    {next_fence, snapshot}
  end

  defp complete(ctx, fence) do
    ref = make_ref()
    PlayerStore.complete_transfer(ctx.writer, fence, ref)
    assert_receive {:player_transfer_saved, ^ref, result}
    result
  end

  defp deliver(ctx, snapshot) do
    {:ok, key, request, _} = PlayerState.transfer_request(ctx.uuid, snapshot)
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    Region.apply_item_transfer(owner, request)
  end

  defp saved(ctx),
    do: PlayerState.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

  defp kill_writer(ctx) do
    monitor = Process.monitor(ctx.writer)
    Process.exit(ctx.writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
  end

  defp creative(snapshot),
    do: %{snapshot | inventory: %{snapshot.inventory | infinite_materials: true}}

  defp create(ctx, snapshot, record, fence \\ nil) do
    ref = make_ref()

    PlayerStore.prepare_creative_drop(
      ctx.writer,
      fence || ctx.fence,
      snapshot,
      ctx.key,
      record,
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, result}
    result
  end

  test "creative source guards reject foreign, unauthorized, invalid, stale and disabled creation",
       ctx do
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, ctx.fence, ctx.before, ref)
    assert_receive {:player_saved, ^ref, :ok}
    original = File.read!(PlayerStore.path(ctx.base, ctx.uuid))
    [record] = ctx.records
    authorized = creative(ctx.before)
    assert {:error, :creative_drop_not_authorized} = create(ctx, ctx.before, record)
    assert {:error, :invalid_transfer_plan} = create(ctx, authorized, [record])
    assert {:error, :stale_player_snapshot} = create(ctx, authorized, record, make_ref())

    task =
      Task.async(fn ->
        PlayerStore.prepare_creative_drop(
          ctx.writer,
          ctx.fence,
          authorized,
          ctx.key,
          record,
          make_ref()
        )
      end)

    Task.await(task, 60_000)
    assert {:ok, loaded, _} = GenServer.call(ctx.writer, :load)
    assert loaded.outbox == nil and loaded.transfer_sequence == 0
    assert File.read!(PlayerStore.path(ctx.base, ctx.uuid)) == original
    assert Valimc.TestWorld.item_snapshot(ctx.key) == %{}
    :sys.replace_state(ctx.writer, &%{&1 | path: nil})
    assert {:error, :transfer_storage_disabled} = create(ctx, authorized, record)
    assert File.read!(PlayerStore.path(ctx.base, ctx.uuid)) == original
  end

  test "a lost creation acknowledgment recovers pinned records without persisted permission",
       ctx do
    [record] = ctx.records
    ref = make_ref()

    PlayerStore.prepare_creative_drop(
      ctx.writer,
      ctx.fence,
      creative(ctx.before),
      ctx.key,
      record,
      ref
    )

    {:ok, committed, committed_fence} = GenServer.call(ctx.writer, :load)
    kill_writer(ctx)
    assert_receive {:player_transfer_saved, ^ref, {:ok, ^committed_fence, ^committed}}
    {:ok, writer, recovered, fence} = PlayerStore.open(ctx.uuid)
    next = %{ctx | writer: writer, fence: fence}
    assert recovered.outbox.records == [record] and recovered.inventory == ctx.before.inventory
    refute recovered.inventory.infinite_materials
    assert {:error, :transfer_pending} = create(next, creative(ctx.before), record)
    assert {:ok, :applied} = deliver(next, recovered)
    assert {:ok, :already_applied} = deliver(next, recovered)
    assert {:ok, _, cleared} = complete(next, fence)
    assert cleared.outbox == nil and map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
  end

  test "prepare/complete fence old saves and retain the sequence in ordinary checkpoints", ctx do
    {prepared_fence, snapshot} = prepare(ctx)
    assert prepared_fence != ctx.fence
    assert snapshot.transfer_sequence == 1 and snapshot.inventory == ctx.after.inventory
    assert saved(ctx) == {:ok, snapshot}
    original = File.read!(PlayerStore.path(ctx.base, ctx.uuid))

    for {fence, reason} <- [
          {ctx.fence, :stale_player_snapshot},
          {prepared_fence, :transfer_pending}
        ] do
      ref = make_ref()
      PlayerStore.checkpoint(ctx.writer, fence, ctx.before, ref)
      assert_receive {:player_saved, ^ref, {:error, ^reason}}
      assert File.read!(PlayerStore.path(ctx.base, ctx.uuid)) == original
    end

    ref = make_ref()

    PlayerStore.prepare_transfer(
      ctx.writer,
      prepared_fence,
      ctx.before,
      ctx.after,
      ctx.key,
      ctx.records,
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, {:error, :transfer_pending}}
    assert {:error, {:retry, :transfer_not_applied}} = complete(ctx, prepared_fence)
    assert saved(ctx) == {:ok, snapshot}
    assert {:ok, :applied} = deliver(ctx, snapshot)
    assert {:ok, completed_fence, cleared} = complete(ctx, prepared_fence)
    assert completed_fence != prepared_fence and cleared.outbox == nil
    assert cleared.transfer_sequence == 1
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, prepared_fence, ctx.before, ref)
    assert_receive {:player_saved, ^ref, {:error, :stale_player_snapshot}}
    ref = make_ref()

    PlayerStore.checkpoint(
      ctx.writer,
      completed_fence,
      Map.merge(ctx.after, %{transfer_sequence: 0, outbox: snapshot.outbox}),
      ref
    )

    assert_receive {:player_saved, ^ref, :ok}
    assert {:ok, ^cleared} = saved(ctx)
    assert :ok = PlayerStore.close(ctx.writer, completed_fence, ctx.after)
  end

  test "lost prepare reply and owner replacement recover reduced inventory and pinned intent",
       ctx do
    ref = make_ref()

    PlayerStore.prepare_transfer(
      ctx.writer,
      ctx.fence,
      ctx.before,
      ctx.after,
      ctx.key,
      ctx.records,
      ref
    )

    {:ok, pending, prepared_fence} = GenServer.call(ctx.writer, :load)
    kill_writer(ctx)
    assert_receive {:player_transfer_saved, ^ref, {:ok, ^prepared_fence, ^pending}}
    {:ok, writer, recovered, fence} = PlayerStore.open(ctx.uuid)
    assert recovered == pending and fence != prepared_fence
    next = %{ctx | writer: writer, fence: fence}
    assert recovered.inventory == ctx.after.inventory
    assert {:ok, :applied} = deliver(next, recovered)
    assert {:ok, _, cleared} = complete(next, fence)
    assert cleared.outbox == nil and cleared.transfer_sequence == 1
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
  end

  test "pending disconnect keeps latest health/food without restoring spent inventory", ctx do
    fields = %{
      game_mode: Valimc.GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 17.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %Valimc.PlayerFood{}
    }

    ctx = %{ctx | before: Map.merge(ctx.before, fields), after: Map.merge(ctx.after, fields)}
    {fence, pending} = prepare(ctx)
    assert pending.health == fields.health

    latest = %{
      ctx.before
      | health: %{value: 6.25, hurt_ticks: 7, death_ticks: 0},
        food: %Valimc.PlayerFood{level: 3, saturation: 0.0, exhaustion: 3.5, timer: 79}
    }

    {:ok, {region, _} = owner} = Valimc.TestWorld.item_owner(ctx.key)
    :sys.suspend(region)

    {recovered, recovered_fence} =
      try do
        assert :ok = PlayerStore.close_session(ctx.writer, fence, latest)
        assert {:ok, stored} = saved(ctx)
        assert stored.health == latest.health and stored.inventory == ctx.after.inventory
        assert stored.outbox == pending.outbox and stored.transfer_sequence == 1
        assert stored.food == latest.food
        assert {:ok, writer, recovered, recovered_fence} = PlayerStore.open(ctx.uuid)
        assert writer == ctx.writer and recovered.health == latest.health
        assert recovered.outbox == pending.outbox and recovered.inventory == ctx.after.inventory
        assert recovered.food == latest.food
        {recovered, recovered_fence}
      after
        :sys.resume(region)
      end

    {:ok, _, request, _} = PlayerState.transfer_request(ctx.uuid, recovered)
    assert {:ok, disposition} = Region.apply_item_transfer(owner, request)
    assert disposition in [:applied, :already_applied]
    assert {:ok, next_fence, cleared} = complete(ctx, recovered_fence)
    assert cleared.health == latest.health and cleared.outbox == nil
    assert cleared.food == latest.food

    assert cleared.inventory == ctx.after.inventory and
             map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1

    assert :ok = PlayerStore.close(ctx.writer, next_fence, cleared)
  end

  test "destination receipt must match the exact source sequence and batch", ctx do
    {fence, pending} = prepare(ctx)
    {:ok, key, request, _} = PlayerState.transfer_request(ctx.uuid, pending)
    [record] = request.records
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    assert {:ok, :applied} =
             Region.apply_item_transfer(owner, %{
               request
               | records: [%{record | stack: ItemStack.new("stone", 2)}]
             })

    assert {:error, :transfer_receipt_conflict} = complete(ctx, fence)
    assert saved(ctx) == {:ok, pending}

    assert {:error, {:retry, :stale_owner}} =
             Region.item_transfer_receipt({elem(owner, 0), make_ref()}, ctx.uuid)

    assert {:error, :invalid_transfer_source} = Region.item_transfer_receipt(owner, <<0>>)
  end

  test "prepare write failure fences the writer without rolling over the old inventory", ctx do
    ref = make_ref()
    PlayerStore.checkpoint(ctx.writer, ctx.fence, ctx.before, ref)
    assert_receive {:player_saved, ^ref, :ok}
    path = PlayerStore.path(ctx.base, ctx.uuid)
    old = File.read!(path)
    File.rename!(path, path <> ".saved")
    File.mkdir_p!(path)
    monitor = Process.monitor(ctx.writer)

    capture_log(fn ->
      ref = make_ref()

      PlayerStore.prepare_transfer(
        ctx.writer,
        ctx.fence,
        ctx.before,
        ctx.after,
        ctx.key,
        ctx.records,
        ref
      )

      assert_receive {:player_transfer_saved, ^ref, {:error, :player_commit_uncertain}}
      assert_receive {:DOWN, ^monitor, :process, _, :normal}
    end)

    assert File.read!(path <> ".saved") == old
    File.rm_rf!(path)
    File.rename!(path <> ".saved", path)
    {:ok, _, recovered, _} = PlayerStore.open(ctx.uuid)
    assert recovered.inventory == ctx.before.inventory and recovered.outbox == nil
    assert Valimc.TestWorld.item_snapshot(ctx.key) == %{}
  end

  test "foreign callers, disabled storage and queued stale checkpoints cannot replace an intent",
       ctx do
    foreign =
      Task.async(fn ->
        PlayerStore.prepare_transfer(
          ctx.writer,
          ctx.fence,
          ctx.before,
          ctx.after,
          ctx.key,
          ctx.records,
          make_ref()
        )

        GenServer.call(ctx.writer, :load)
      end)

    assert {:error, :not_owner} = Task.await(foreign, 60_000)
    :sys.suspend(ctx.writer)
    prepare_ref = make_ref()
    stale_ref = make_ref()

    PlayerStore.prepare_transfer(
      ctx.writer,
      ctx.fence,
      ctx.before,
      ctx.after,
      ctx.key,
      ctx.records,
      prepare_ref
    )

    PlayerStore.checkpoint(ctx.writer, ctx.fence, ctx.before, stale_ref)
    # A store without a world path (the test default) keeps nothing durable.
    id = :crypto.strong_rand_bytes(16)
    {:ok, other, nil, other_fence} = PlayerStore.open(id)
    ref = make_ref()

    PlayerStore.prepare_transfer(
      other,
      other_fence,
      ctx.before,
      ctx.after,
      ctx.key,
      ctx.records,
      ref
    )

    assert_receive {:player_transfer_saved, ^ref, {:error, :transfer_storage_disabled}}
    assert :ok = PlayerStore.close(other, other_fence, ctx.before)
    :sys.resume(ctx.writer)
    assert_receive {:player_transfer_saved, ^prepare_ref, {:ok, _, pending}}
    assert_receive {:player_saved, ^stale_ref, {:error, :stale_player_snapshot}}
    assert saved(ctx) == {:ok, pending}
  end

  test "an ephemeral destination receipt cannot clear a durable source outbox", ctx do
    TestScope.isolate(ctx.key, world_path: nil)
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    {fence, pending} = prepare(ctx)
    {:ok, _, request, _} = PlayerState.transfer_request(ctx.uuid, pending)
    assert {:ok, :applied} = Region.apply_item_transfer(owner, request)
    assert {:error, :transfer_destination_ephemeral} = complete(ctx, fence)
    assert saved(ctx) == {:ok, pending}
  end

  test "source owner loss releases its lease while preserving a prepared intent", ctx do
    id = :crypto.strong_rand_bytes(16)
    TestScope.isolate(id, world_path: ctx.base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, id), do: TestScope.kill(pid)
    end)

    parent = self()

    owner =
      Task.async(fn ->
        {:ok, writer, nil, fence} = PlayerStore.open(id)
        ref = make_ref()

        PlayerStore.prepare_transfer(
          writer,
          fence,
          ctx.before,
          ctx.after,
          ctx.key,
          ctx.records,
          ref
        )

        receive do
          {:player_transfer_saved, ^ref, {:ok, next_fence, pending}} ->
            send(parent, {:owned_pending, writer, next_fence, pending})
        end

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned_pending, writer, old_fence, pending}
    monitor = Process.monitor(writer)
    send(owner.pid, :finish)
    assert Task.await(owner, 60_000) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}
    {:ok, replacement, recovered, fence} = PlayerStore.open(id)
    assert recovered == pending and fence != old_fence
    assert {:error, :transfer_pending} = PlayerStore.close(replacement, fence, ctx.before)
  end

  test "a recovered maximum sequence cannot wrap or alter the saved source", ctx do
    assert :ok = PlayerStore.close(ctx.writer, ctx.fence, ctx.before)

    exhausted =
      Map.merge(ctx.before, %{transfer_sequence: 18_446_744_073_709_551_615, outbox: nil})

    {:ok, bytes} = PlayerState.encode(ctx.uuid, exhausted)
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.write!(path, bytes)
    {:ok, writer, recovered, fence} = PlayerStore.open(ctx.uuid)
    assert recovered.transfer_sequence == exhausted.transfer_sequence
    ref = make_ref()
    PlayerStore.prepare_transfer(writer, fence, ctx.before, ctx.after, ctx.key, ctx.records, ref)
    assert_receive {:player_transfer_saved, ^ref, {:error, :transfer_sequence_exhausted}}
    assert File.read!(path) == bytes
    assert :ok = PlayerStore.close(writer, fence, ctx.before)
    assert File.read!(path) == bytes
  end

  test "an unreadable destination preserves the source intent until repair", ctx do
    {fence, pending} = prepare(ctx)
    Valimc.TestDisk.corrupt(ctx.base, ctx.key)

    capture_log(fn ->
      assert {:error, {:retry, :transfer_destination_unavailable}} = complete(ctx, fence)
    end)

    assert saved(ctx) == {:ok, pending}
    assert Valimc.TestDisk.read(ctx.base, ctx.key, :items) == :corrupt
    assert Process.alive?(ctx.writer)
    Valimc.TestDisk.repair(ctx.base, ctx.key)
    # The failed load backs off before the region is admitted again (VMC-077e).
    Valimc.TestWait.until(fn ->
      Valimc.TestWorld.region(ctx.key) != {:error, {:retry, {:region_load, :backoff}}}
    end)

    assert {:ok, :applied} = deliver(ctx, pending)
    assert {:ok, _, cleared} = complete(ctx, fence)
    assert cleared.outbox == nil and cleared.inventory == ctx.after.inventory
  end
end
