defmodule Valimc.DisconnectedInventoryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.World.{ItemRecords, Items, Region, Store}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-disconnected-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {70_000 + rem(nonce, 10_000), 400}
    name = "Gone" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    stone = %{
      ItemStack.new("stone", 10)
      | components: %{
          "minecraft:custom_data" => {:compound, %{"disconnect" => {:string, "exact"}}},
          "minecraft:enchantment_glint_override" => true
        },
        removed: MapSet.new(["minecraft:rarity"])
    }

    inventory = %Inventory{
      selected: 2,
      carried: stone,
      drag: %{mode: 0, slots: MapSet.new([9])},
      slots: %{
        1 => ItemStack.new("egg", 3),
        2 => ItemStack.new("dirt", 4),
        3 => %{ItemStack.new("iron_sword") | components: %{"minecraft:damage" => 17}},
        4 => ItemStack.new("diamond"),
        38 => %{stone | count: 63},
        45 => ItemStack.new("egg", 3)
      }
    }

    snapshot = PlayerSnapshot.capture(pose, inventory)
    path = PlayerStore.path(base, uuid)

    on_exit(fn ->
      for {pid, p} <- :ets.tab2list(Players),
          p.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      name: name,
      uuid: uuid,
      pose: pose,
      inventory: inventory,
      snapshot: snapshot,
      path: path
    }
  end

  defp wait(predicate, attempts \\ 1000) do
    case predicate.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert attempts > 0
        Process.sleep(2)
        wait(predicate, attempts - 1)
    end
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp seed(ctx, snapshot) do
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, snapshot)
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp region(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    pid
  end

  defp records(pid), do: Items.records(:sys.get_state(pid).items)

  defp verify(ctx, snapshot, records) do
    assert snapshot.inventory.slots == Map.take(ctx.inventory.slots, [38, 45])
    assert snapshot.inventory.carried == nil and snapshot.inventory.selected == 2
    assert snapshot.outbox == nil

    assert Enum.map(records, & &1.stack) |> MapSet.new() ==
             MapSet.new([ctx.inventory.carried | Enum.map(1..4, &ctx.inventory.slots[&1])])

    assert length(records) == 5

    assert Enum.all?(
             records,
             &(&1.x == ctx.pose.x and &1.z == ctx.pose.z and
                 &1.y == ctx.pose.y + 1.3199999928474426)
           )
  end

  defp departed(ctx) do
    wait(fn -> not Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.uuid == ctx.uuid end) end)
  end

  defp idle(ctx), do: wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)

  test "socket exit commits all five whole stacks offline and normal/restarted login cannot repeat them",
       ctx do
    seed(ctx, %{
      ctx.snapshot
      | inventory: %{ctx.inventory | carried: nil, slots: Map.take(ctx.inventory.slots, [38, 45])}
    })

    {uuid, client} = Client.login(ctx.name)
    assert uuid == ctx.uuid
    client = Client.load_world(client)
    p = Enum.find(Players.all(), &(&1.uuid == uuid))
    :sys.replace_state(p.pid, &%{&1 | inventory: %{ctx.inventory | infinite_materials: true}})
    ref = Process.monitor(p.pid)
    Client.close(client)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
    departed(ctx)
    idle(ctx)
    owner = region(ctx)
    first = records(owner)
    verify(ctx, saved(ctx), first)
    assert saved(ctx).transfer_sequence == 1
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, owner)
    assert records(region(ctx)) == first
    {^uuid, second} = Client.login(ctx.name)
    second = Client.load_world(second)
    assert second.inventory.carried == nil
    assert second.inventory.items == Inventory.contents(saved(ctx).inventory)
    Client.close(second)
    departed(ctx)
    idle(ctx)
    assert records(region(ctx)) == first and saved(ctx).transfer_sequence == 1
  end

  test "reconnect adopts a closing writer, fences old messages and replays its exact journal",
       ctx do
    owner = region(ctx)
    disk = :sys.get_state(owner).store
    :sys.suspend(disk)
    parent = self()

    old_owner =
      spawn(fn ->
        {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
        :ok = PlayerStore.close_session(writer, fence, ctx.snapshot)
        send(parent, {:closed, writer, fence})
      end)

    try do
      assert_receive {:closed, writer, old_fence}, 1000

      closing =
        wait(fn ->
          state = :sys.get_state(writer)
          if state.closing.job && :sys.get_state(owner).item_pending, do: state
        end)

      assert not Process.alive?(old_owner) and Process.alive?(writer)
      pending = saved(ctx)
      assert length(pending.outbox.records) == 5 and records(owner) == []
      {:ok, ^writer, adopted, fence} = PlayerStore.open(ctx.uuid)
      assert fence != old_fence and adopted.outbox == pending.outbox
      refute adopted.inventory.infinite_materials
      assert adopted.inventory.state_id == 0 and adopted.inventory.drag == nil
      ref = make_ref()
      PlayerStore.checkpoint(writer, old_fence, ctx.snapshot, ref)
      assert_receive {:player_saved, ^ref, {:error, :stale_player_snapshot}}

      send(
        writer,
        {:transfer_delivered, closing.closing.job.pid, closing.closing.job.token, {:ok, :applied}}
      )

      send(writer, {:close_deadline, closing.closing.id})
      send(writer, {:retry_close, closing.closing.id, closing.closing.retry_token})
      send(writer, {:deliver_close, closing.closing.id})
      send(writer, {:DOWN, closing.monitor, :process, old_owner, :normal})
      assert :sys.get_state(writer).snapshot.outbox == pending.outbox
      assert :sys.get_state(writer).closing == nil
      :sys.resume(disk)
      wait(fn -> :sys.get_state(owner).item_pending == nil end)
      {:ok, _, request, _} = PlayerSnapshot.transfer_request(ctx.uuid, adopted)
      {:ok, handle} = World.item_owner(ctx.key)
      assert {:ok, :already_applied} = Region.apply_item_transfer(handle, request)
      ref = make_ref()
      PlayerStore.complete_transfer(writer, fence, ref)
      assert_receive {:player_transfer_saved, ^ref, {:ok, fence, completed}}, 1000
      verify(ctx, completed, records(owner))

      assert MapSet.new(Enum.map(records(owner), & &1.uuid)) ==
               MapSet.new(Enum.map(pending.outbox.records, & &1.uuid))

      assert :ok = PlayerStore.close(writer, fence, completed)
    after
      if Process.alive?(disk), do: :sys.resume(disk)
    end
  end

  test "orphan cleanup is journaled before login configuration; other players remain responsive",
       ctx do
    seed(ctx, ctx.snapshot)
    owner = region(ctx)
    disk = :sys.get_state(owner).store
    :sys.suspend(disk)
    client = Client.begin_login(ctx.name)

    try do
      pending =
        wait(fn ->
          p = Enum.find(:ets.tab2list(Players), fn {_, p} -> p.uuid == ctx.uuid end)

          if p do
            s = :sys.get_state(elem(p, 0))

            if s.recovery && s.recovery.stage == :delivery &&
                 :sys.get_state(owner).item_pending,
               do: s
          end
        end)

      assert pending.phase == :login and pending.step == :recover
      assert World.item_snapshot(ctx.key) == %{}
      assert length(saved(ctx).outbox.records) == 5
      assert {:error, :session_closing} = PlayerStore.open(ctx.uuid)
      # There are no play packets before compression/login completion.
      assert {:error, :timeout} = :gen_tcp.recv(client.socket, 0, 20)

      {_, healthy} =
        Client.login("Other" <> Integer.to_string(System.unique_integer([:positive])))

      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await(healthy, :play, "system_chat")
      Client.close(healthy)
      :sys.resume(disk)
      {uuid, client} = Client.login_session(client, ctx.name)
      assert uuid == ctx.uuid
      client = Client.load_world(client)
      verify(ctx, saved(ctx), records(owner))
      assert client.inventory.carried == nil
      Client.close(client)
      departed(ctx)
      idle(ctx)
    after
      if Process.alive?(disk), do: :sys.resume(disk)
      Client.close(client)
    end
  end

  test "disabled or exhausted cleanup retains raw latest contents without publishing effects",
       ctx do
    for reason <- [:disabled, :exhausted] do
      {:ok, writer, _, fence} = PlayerStore.open(ctx.uuid)
      if reason == :disabled, do: :sys.replace_state(writer, &%{&1 | path: nil})

      if reason == :exhausted do
        snapshot =
          Map.merge(ctx.snapshot, %{transfer_sequence: 18_446_744_073_709_551_615, outbox: nil})

        :sys.replace_state(writer, &%{&1 | snapshot: snapshot})
      end

      expected =
        if reason == :disabled, do: :transfer_storage_disabled, else: :transfer_sequence_exhausted

      assert {:error, ^expected} = PlayerStore.close_session(writer, fence, ctx.snapshot)
      idle(ctx)
      assert records(region(ctx)) == []

      if reason == :exhausted do
        assert saved(ctx).inventory.carried == ctx.inventory.carried
        assert saved(ctx).inventory.slots == ctx.inventory.slots
        assert saved(ctx).transfer_sequence == 18_446_744_073_709_551_615
      end
    end
  end

  test "failed raw save preserves its previous bytes and creates no destination records", ctx do
    seed(ctx, ctx.snapshot)
    before = File.read!(ctx.path)
    {:ok, writer, _, fence} = PlayerStore.open(ctx.uuid)
    File.write!(Path.join(ctx.base, "blocked"), "not a directory")
    :sys.replace_state(writer, &%{&1 | path: Path.join(ctx.base, "blocked/player.pose")})

    assert capture_log(fn ->
             assert {:error, :enotdir} = PlayerStore.close_session(writer, fence, ctx.snapshot)
           end) =~ "Player state save failed"

    idle(ctx)
    assert File.read!(ctx.path) == before and records(region(ctx)) == []
  end

  test "an unobserved creative prepare commits first; a stale close cannot restore older owned contents",
       ctx do
    owner = region(ctx)
    disk = :sys.get_state(owner).store
    :sys.suspend(disk)
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)

    created = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: ctx.pose.x,
      y: 64.5,
      z: ctx.pose.z,
      stack: ItemStack.new("egg", 2)
    }

    snapshot = %{ctx.snapshot | inventory: %{ctx.inventory | infinite_materials: true}}
    ref = make_ref()
    PlayerStore.prepare_creative_drop(writer, fence, snapshot, ctx.key, created, ref)
    assert_receive {:player_transfer_saved, ^ref, {:ok, _new_fence, prepared}}, 1000

    stale = %{
      ctx.snapshot
      | pose: %{ctx.pose | x: ctx.pose.x + 1},
        inventory: %{ctx.inventory | carried: %{ctx.inventory.carried | count: 11}}
    }

    try do
      assert :ok = PlayerStore.close_session(writer, fence, stale)
      assert saved(ctx).outbox == prepared.outbox
      assert saved(ctx).inventory.carried.count == 10
      assert saved(ctx).pose.x == stale.pose.x
      :sys.resume(disk)
      idle(ctx)
      final = records(owner)
      assert length(final) == 6 and Enum.count(final, &(&1 == created)) == 1
      cleanup = Enum.reject(final, &(&1.uuid == created.uuid))
      verify(%{ctx | pose: stale.pose}, saved(ctx), cleanup)
      assert saved(ctx).transfer_sequence == 2
    after
      if Process.alive?(disk), do: :sys.resume(disk)
    end
  end

  test "destination capacity holds the whole disconnected batch until space is available", ctx do
    fixture =
      for _ <- 1..253,
          do: %{
            uuid: :crypto.strong_rand_bytes(16),
            x: ctx.pose.x,
            y: 64.5,
            z: ctx.pose.z,
            stack: ItemStack.new("stone")
          }

    {:ok, bytes} = ItemRecords.encode(ctx.key, fixture)
    path = Store.item_path(ctx.base, ctx.key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    owner = region(ctx)
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)
    assert :ok = PlayerStore.close_session(writer, fence, ctx.snapshot)
    wait(fn -> :sys.get_state(writer).closing.attempts > 0 end)
    pending = saved(ctx)
    assert length(pending.outbox.records) == 5 and length(records(owner)) == 253
    {:ok, handle} = World.item_owner(ctx.key)

    for item <- Enum.take(fixture, 2) do
      {:ok, token} = Region.find_item(handle, item.uuid)
      assert :ok = Region.remove_item(token)
    end

    idle(ctx)
    final = records(owner)
    assert length(final) == 256
    ids = MapSet.new(Enum.map(pending.outbox.records, & &1.uuid))
    verify(ctx, saved(ctx), Enum.filter(final, &MapSet.member?(ids, &1.uuid)))
    assert saved(ctx).transfer_sequence == 1
  end

  test "closing deadline leaves a pinned source journal recoverable after writer/region replacement",
       ctx do
    owner = region(ctx)
    disk = :sys.get_state(owner).store
    :sys.suspend(disk)
    {:ok, writer, nil, fence} = PlayerStore.open(ctx.uuid)

    try do
      assert :ok = PlayerStore.close_session(writer, fence, ctx.snapshot)

      closing =
        wait(fn ->
          s = :sys.get_state(writer)
          if s.closing.job && :sys.get_state(owner).item_pending, do: s.closing
        end)

      intent = saved(ctx)
      bytes = File.read!(ctx.path)

      capture_log(fn ->
        send(writer, {:close_deadline, closing.id})
        idle(ctx)
      end)

      assert File.read!(ctx.path) == bytes
      :sys.resume(disk)
      wait(fn -> :sys.get_state(owner).item_pending == nil end)
      :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, owner)
      {_, client} = Client.login(ctx.name)
      client = Client.load_world(client)
      verify(ctx, saved(ctx), records(region(ctx)))

      assert MapSet.new(Enum.map(records(region(ctx)), & &1.uuid)) ==
               MapSet.new(Enum.map(intent.outbox.records, & &1.uuid))

      Client.close(client)
      departed(ctx)
      idle(ctx)
    after
      if Process.alive?(disk), do: :sys.resume(disk)
    end
  end
end
