defmodule Valimc.LoginRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, PlayerTransfers}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.World.Region
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-login-recovery-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {400 + rem(nonce, 3_333) * 3, 400}

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, key: key}
  end

  defp seed(ctx, motion \\ nil) do
    name = "Recover" <> Integer.to_string(System.unique_integer([:positive]))
    uuid = Valimc.Connection.offline_uuid(name)
    pose = %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}
    before = PlayerState.capture(pose, %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    kept = PlayerState.capture(pose, %Inventory{slots: %{36 => ItemStack.new("stone", 4)}})
    {rx, rz} = ctx.key

    records = [
      %{
        uuid: :crypto.strong_rand_bytes(16),
        x: rx * 128 + 0.5,
        y: 64.5,
        z: rz * 128 + 0.5,
        stack: ItemStack.new("stone", 3)
      }
    ]

    records = if motion, do: Enum.map(records, &Map.put(&1, :motion, motion)), else: records

    {:ok, pending} = PlayerTransfers.prepare(uuid, 0, before, kept, ctx.key, records)
    {:ok, bytes} = PlayerState.encode(uuid, pending)
    path = PlayerStore.path(ctx.base, uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    %{name: name, uuid: uuid, pending: pending, path: path, bytes: bytes}
  end

  defp await_state(name, predicate, attempts \\ 400) do
    found = Enum.find(:ets.tab2list(Valimc.Players), fn {_, p} -> p.name == name end)
    state = if found, do: Valimc.TestConn.state(elem(found, 0))

    if state && predicate.(state) do
      {elem(found, 0), state}
    else
      assert attempts > 0
      Process.sleep(2)
      await_state(name, predicate, attempts - 1)
    end
  end

  defp departed(fixture, attempts \\ 200) do
    if Registry.lookup(Valimc.PlayerStoreRegistry, fixture.uuid) != [] or
         Enum.any?(:ets.tab2list(Valimc.Players), fn {_, p} -> p.name == fixture.name end) do
      assert attempts > 0
      Process.sleep(2)
      departed(fixture, attempts - 1)
    end
  end

  defp finish(client, fixture) do
    {uuid, client} = Client.login_session(client, fixture.name)
    assert uuid == fixture.uuid
    client = Client.load_world(client)
    assert Enum.at(client.inventory.items, 36) == ItemStack.new("stone", 4)
    assert {:ok, saved} = PlayerState.decode(File.read!(fixture.path), uuid)
    assert saved.outbox == nil and saved.transfer_sequence == 1
    player = Enum.find(Valimc.Players.all(), &(&1.name == fixture.name))
    state = Valimc.TestConn.state(player.pid)
    assert state.recovery == nil and state.inventory.infinite_materials
    Client.close(client)
    departed(fixture)
  end

  test "v3 pending launch recovers through login and fresh retry never recreates a removed item",
       ctx do
    motion = %Valimc.ItemMotionState{velocity: {0.3, 0.1, -0.2}, pickup_delay: 40}
    fixture = seed(ctx, motion)
    finish(Client.begin_login(fixture.name), fixture)
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)

    assert [record] =
             Valimc.World.Entities.records(Valimc.TestRegion.section(owner).entities.store)

    assert record.motion == motion
    assert {:ok, handle} = Region.find_item(owner, record.uuid)
    assert :ok = Region.remove_item(handle)

    # Replay the physically committed source intent after its destination was consumed.
    File.write!(fixture.path, fixture.bytes)
    finish(Client.begin_login(fixture.name), fixture)
    assert Valimc.TestWorld.item_snapshot(ctx.key) == %{}
    assert Valimc.TestRegion.section(owner).entities.receipts[fixture.uuid].sequence == 1
  end

  test "stalled delivery leaves login unpublished and sockets/other identities responsive", ctx do
    fixture = seed(ctx)
    {:ok, region_owner} = Valimc.TestWorld.item_owner(ctx.key)
    writer = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(writer)
    client = Client.begin_login(fixture.name)

    try do
      {pid, state} =
        await_state(
          fixture.name,
          &(&1.recovery != nil and
              Valimc.TestRegion.writing?(Valimc.TestRegion.section(region_owner)))
        )

      assert state.phase == :login and state.step == :recover
      assert not Enum.any?(Valimc.Players.all(), &(&1.name == fixture.name))
      assert File.read!(fixture.path) == fixture.bytes
      # The region shows the delivered items at once (D2); the login waits for its proof.
      assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
      job = state.recovery.job
      send(pid, {:transfer_delivered, self(), job.token, {:ok, :applied}})
      send(pid, {:retry_recovery, state.recovery.id, make_ref()})
      send(pid, {:recovery_deadline, make_ref()})
      send(pid, {:player_transfer_saved, make_ref(), {:error, :bad}})
      assert Valimc.TestConn.state(pid).recovery.job.pid == job.pid
      assert {:error, :session_closing} = PlayerStore.open(fixture.uuid)
      name = "Healthy" <> Integer.to_string(System.unique_integer([:positive]))
      {healthy_uuid, healthy} = Client.login(name)
      Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
      {_, _} = Client.await_stats(healthy)
      Client.close(healthy)
      departed(%{name: name, uuid: healthy_uuid})
      :sys.resume(writer)
      finish(client, fixture)
      assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Client.close(client)
      departed(fixture)
    end
  end

  test "worker loss after submission retries the identical uncertain delivery", ctx do
    fixture = seed(ctx)
    {:ok, region_owner} = Valimc.TestWorld.item_owner(ctx.key)
    writer = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(writer)
    client = Client.begin_login(fixture.name)

    try do
      {pid, state} =
        await_state(
          fixture.name,
          &(&1.recovery != nil and
              Valimc.TestRegion.writing?(Valimc.TestRegion.section(region_owner)))
        )

      job = state.recovery.job
      Process.exit(job.pid, :kill)
      {^pid, _} = await_state(fixture.name, &(&1.recovery.attempts > 0))
      :sys.resume(writer)
      finish(client, fixture)
      assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Client.close(client)
      departed(fixture)
    end
  end

  test "pool saturation backs off without queued jobs and succeeds after admission frees", ctx do
    fixture = seed(ctx)

    workers =
      for _ <- 1..(System.schedulers_online() * 4) do
        {:ok, worker} =
          Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
            receive do
              :done -> :ok
            end
          end)

        worker
      end

    client = Client.begin_login(fixture.name)

    try do
      {_, state} =
        await_state(fixture.name, &(&1.recovery != nil and &1.recovery.stage == :retry))

      assert state.recovery.job == nil and is_reference(state.recovery.retry_timer)
      assert Task.Supervisor.children(Valimc.TransferWorkers) |> length() == length(workers)
      assert File.read!(fixture.path) == fixture.bytes
      for worker <- workers, do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, worker)
      finish(client, fixture)
    after
      for worker <- workers,
          Process.alive?(worker),
          do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, worker)

      Client.close(client)
      departed(fixture)
    end
  end

  test "deadline cancels jobs and preserves pending source even if region later commits", ctx do
    fixture = seed(ctx)
    {:ok, region_owner} = Valimc.TestWorld.item_owner(ctx.key)
    writer = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(writer)
    client = Client.begin_login(fixture.name)

    try do
      {pid, state} =
        await_state(
          fixture.name,
          &(&1.recovery != nil and
              Valimc.TestRegion.writing?(Valimc.TestRegion.section(region_owner)))
        )

      job = state.recovery.job
      send(pid, {:recovery_deadline, state.recovery.id})
      {id, body, _} = Client.read(client)
      assert id == Data.id(:login, :clientbound, "login_disconnect")
      assert :binary.match(body, "Inventory recovery is still pending") != :nomatch
      departed(fixture)
      refute Process.alive?(job.pid)
      assert File.read!(fixture.path) == fixture.bytes
      :sys.resume(writer)
      finish(Client.begin_login(fixture.name), fixture)
      assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    after
      if Process.alive?(writer), do: :sys.resume(writer)
      Client.close(client)
      departed(fixture)
    end
  end

  test "corrupt and ephemeral destinations fail closed without losing source inventory", ctx do
    for kind <- [:corrupt] do
      fixture = seed(ctx)

      if kind == :corrupt do
        Valimc.TestDisk.corrupt(ctx.base, ctx.key)
      else
        Valimc.TestDisk.write(ctx.base, ctx.key, :items, nil)
        Application.put_env(:valimc, :world_path, nil)
        {:ok, _} = Valimc.TestWorld.item_owner(ctx.key)
        Application.put_env(:valimc, :world_path, ctx.base)
      end

      client = Client.begin_login(fixture.name)

      capture_log(fn ->
        {id, body, _} = Client.read(client)
        assert id == Data.id(:login, :clientbound, "login_disconnect")
        assert :binary.match(body, "Inventory recovery could not complete") != :nomatch
      end)

      Client.close(client)
      departed(fixture)
      assert File.read!(fixture.path) == fixture.bytes
      assert Valimc.TestWorld.item_snapshot(ctx.key) == %{}
    end
  end
end
