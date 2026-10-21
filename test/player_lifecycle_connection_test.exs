defmodule Valimc.PlayerLifecycleConnectionTest do
  use ExUnit.Case, async: false
  import Valimc.TestPlayer, only: [living: 1]
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, PlayerSnapshot, Players, PlayerStore, World}
  alias Valimc.Protocol.{ItemStack, Packets, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    names = ["Life#{nonce}A", "Life#{nonce}B"]
    base = Path.join(System.tmp_dir!(), "valimc-lifecycle-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {60_000 + rem(nonce, 3_333) * 3, 950}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    on_exit(fn ->
      for {pid, player} <- :ets.tab2list(Players),
          player.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)

      for name <- names,
          {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{names: names, base: base, key: key, pose: pose}
  end

  defp seed(ctx, name, inventory, mode \\ :survival) do
    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{freezing: %Freezing{}, health: %Health{}},
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        last_death: nil
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(
        Connection.offline_uuid(name),
        PlayerSnapshot.capture(player, inventory)
      )

    path = path(ctx, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp path(ctx, name), do: PlayerStore.path(ctx.base, Connection.offline_uuid(name))

  defp saved(ctx, name),
    do: PlayerSnapshot.decode(File.read!(path(ctx, name)), Connection.offline_uuid(name))

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp login(name) do
    {_, client} = Client.login(name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp respawn(client, pid) do
    Client.send_packet(client, :play, "client_command", <<0>>)
    {body, client} = Client.await(client, :play, "respawn")
    next = state(pid)

    assert body ==
             IO.iodata_to_binary(elem(Packets.respawn(next.player, next.player.last_death), 1))

    # An unmodified client waits on this notification even after receiving chunks.
    {<<13, 0::32>>, client} = Client.await(client, :play, "game_event")
    {<<20.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    client
  end

  test "death queues respawn until all durable batches finish",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{slots: Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)})})
    {client, pid} = login(name)
    {:ok, {region, _}} = World.item_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      p = state(pid).player
      assert {:ok, :dead} = Connection.fall_damage(pid, 100)
      wait(fn -> match?(%{stage: :delivery}, state(pid).recovery) end)
      Client.send_packet(client, :play, "client_command", <<0>>)

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<p.x + 7::float-64, 80.0::float-64, p.z::float-64, 1>>
      )

      Client.send_packet(client, :play, "container_click", <<>>)
      Client.send_packet(client, :play, "chat_command", Wire.string("spawn"))
      wait(fn -> state(pid).respawn_requested end)
      blocked = state(pid)
      assert blocked.player.living.health.value == 0 and blocked.life_stage == :dropping
      assert {blocked.player.x, blocked.player.y, blocked.player.z} == {p.x, p.y, p.z}
      assert {:ok, stored} = saved(ctx, name)
      assert stored.health.value == 0 and stored.outbox != nil
      assert stored.transfer_sequence == 1 and map_size(stored.inventory.slots) == 3
      assert stored.last_death == {floor(p.x), floor(p.y), floor(p.z)}
      assert World.item_snapshot(ctx.key) == %{}
    after
      Valimc.TestRegionGate.resume(region)
    end

    # The queued request is delivered automatically after the blocked destination.
    client = respawn(client, pid)
    assert state(pid).life_stage == :alive and living(pid).health.value == 20
    assert state(pid).inventory.slots == %{} and state(pid).inventory.carried == nil
    assert {:ok, stored} = saved(ctx, name)
    assert stored.health.value == 20 and stored.transfer_sequence == 2 and stored.outbox == nil
    assert map_size(World.item_snapshot(ctx.key)) == 8
    assert client.inventory.items == List.duplicate(nil, 46)
  end

  test "dead reconnect retains its screen/state; repeated death updates location without duplicating drops",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    {client, pid} = login(name)
    assert {:ok, :dead} = Connection.fall_damage(pid, 100)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    wait(fn -> state(pid).life_stage == :dead end)
    monitor = Process.monitor(pid)
    Client.close(client)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    wait(fn ->
      Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)) == []
    end)

    {_, client} = Client.login(name)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == name)).pid
    assert state(pid).life_stage == :dead and living(pid).health.value == 0
    assert state(pid).player.pose == :dying and state(pid).inventory.slots == %{}
    client = respawn(client, pid)
    assert state(pid).player.last_death == {floor(ctx.pose.x), 64, floor(ctx.pose.z)}
    assert {:ok, :dead} = Connection.fall_damage(pid, 100)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.last_death == {0, 64, 0}
    _client = respawn(client, pid)
    assert {:ok, stored} = saved(ctx, name)
    assert stored.last_death == {0, 64, 0} and stored.health.value == 20
    assert stored.transfer_sequence == 1 and stored.outbox == nil
    assert map_size(World.item_snapshot(ctx.key)) == 1
    Client.close(client)
  end

  test "disconnect during a pending death resumes all delivery before login publication", ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{slots: Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)})})
    {client, pid} = login(name)
    {:ok, {region, _}} = World.item_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    next =
      try do
        assert {:ok, :dead} = Connection.fall_damage(pid, 100)
        wait(fn -> match?(%{stage: :delivery}, state(pid).recovery) end)
        monitor = Process.monitor(pid)
        Client.close(client)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
        wait(fn -> not Enum.any?(:ets.tab2list(Players), fn {_, p} -> p.name == name end) end)
        next = Client.begin_login(name)

        recovering =
          wait(fn ->
            case Enum.find(:ets.tab2list(Players), fn {_, p} -> p.name == name end) do
              {new_pid, _} ->
                s = state(new_pid)
                if match?(%{stage: :delivery}, s.recovery), do: s

              _ ->
                nil
            end
          end)

        assert recovering.phase == :login and recovering.player.living.health.value == 0
        refute recovering.player.ready
        refute Enum.any?(Players.all(), &(&1.name == name))
        assert {:ok, source} = saved(ctx, name)
        assert source.health.value == 0 and source.transfer_sequence == 1 and source.outbox != nil
        assert map_size(source.inventory.slots) == 3
        next
      after
        Valimc.TestRegionGate.resume(region)
      end

    {_, next} = Client.login_session(next, name)
    {_, next} = Client.await(next, :play, "player_combat_kill")
    next = Client.load_world(next)
    new_pid = Enum.find(Players.all(), &(&1.name == name)).pid
    assert state(new_pid).life_stage == :dead
    assert map_size(World.item_snapshot(ctx.key)) == 8
    _next = respawn(next, new_pid)
    assert {:ok, source} = saved(ctx, name)
    assert source.health.value == 20 and source.transfer_sequence == 2 and source.outbox == nil
    Client.close(next)
  end

  test "an accepted respawn survives a disconnected client while its save is stalled", ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{})
    {client, pid} = login(name)
    assert {:ok, :dead} = Connection.fall_damage(pid, 100)
    wait(fn -> state(pid).life_stage == :dead end)
    writer = state(pid).player_store
    :sys.suspend(writer)
    monitor = Process.monitor(pid)

    try do
      Client.send_packet(client, :play, "client_command", <<0>>)
      wait(fn -> state(pid).life_stage == :respawning end)
      assert {:ok, source} = saved(ctx, name)
      assert source.health.value == 0
      Client.close(client)
    after
      :sys.resume(writer)
    end

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    wait(fn ->
      Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)) == []
    end)

    assert {:ok, source} = saved(ctx, name)

    assert source.health.value == 20 and
             source.last_death == {floor(ctx.pose.x), 64, floor(ctx.pose.z)}

    assert source.inventory.slots == %{} and source.outbox == nil and
             source.transfer_sequence == 0

    {_client, new_pid} = login(name)
    assert living(new_pid).health.value == 20 and state(new_pid).life_stage == :alive
  end

  test "death behind an in-flight ordinary drop retains the old receipt and all remaining items",
       ctx do
    [name | _] = ctx.names

    seed(ctx, name, %Inventory{
      slots: %{36 => ItemStack.new("stone", 7), 37 => ItemStack.new("egg", 2)}
    })

    {client, pid} = login(name)
    {:ok, {region, _}} = World.item_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      Client.send_packet(client, :play, "player_action", [
        Wire.varint(Valimc.Protocol.ItemTypes.action_id("drop_item")),
        Wire.position({0, 0, 0}),
        <<0, 0>>
      ])

      wait(fn -> match?(%{mode: :play, stage: :delivery}, state(pid).recovery) end)
      assert {:ok, :dead} = Connection.fall_damage(pid, 100)
      Client.send_packet(client, :play, "client_command", <<0>>)
      wait(fn -> state(pid).respawn_requested end)
      assert state(pid).life_stage == :sealing_death
      assert {:ok, source} = saved(ctx, name)
      assert source.health.value == 20 and source.transfer_sequence == 1 and source.outbox != nil
      assert source.inventory.slots[36].count == 6
    after
      Valimc.TestRegionGate.resume(region)
    end

    _client = respawn(client, pid)
    assert {:ok, source} = saved(ctx, name)
    assert source.health.value == 20 and source.transfer_sequence == 2 and source.outbox == nil
    assert source.inventory.slots == %{}

    {:ok, %{records: records}} =
      Valimc.World.ItemRecords.decode(
        Valimc.TestDisk.read(ctx.base, ctx.key, :items),
        ctx.key
      )

    assert length(records) == 3
    assert Enum.reduce(records, 0, fn record, n -> n + record.stack.count end) == 9
  end

  test "a failed respawn wire write cannot roll back the already committed living snapshot",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{})
    {client, pid} = login(name)
    assert {:ok, :dead} = Connection.fall_damage(pid, 100)
    wait(fn -> state(pid).life_stage == :dead end)
    writer = state(pid).player_store
    :sys.suspend(writer)
    Client.send_packet(client, :play, "client_command", <<0>>)
    wait(fn -> state(pid).life_stage == :respawning end)
    ref = state(pid).life_save.ref
    socket = state(pid).socket
    :sys.suspend(pid)
    monitor = Process.monitor(pid)

    try do
      :sys.resume(writer)

      wait(fn ->
        {:messages, messages} = Process.info(pid, :messages)
        {:player_saved, ref, :ok} in messages
      end)

      assert {:ok, source} = saved(ctx, name)
      assert source.health.value == 20
      :ok = :gen_tcp.close(socket)
    after
      :sys.resume(pid)
    end

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    wait(fn ->
      Registry.lookup(Valimc.PlayerStoreRegistry, Connection.offline_uuid(name)) == []
    end)

    assert {:ok, source} = saved(ctx, name)
    assert source.health.value == 20 and source.inventory.slots == %{} and source.outbox == nil
  end

  test "creative immunity, living/duplicate respawn requests and expired damage cannot resurrect or mutate",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{}, :creative)
    {client, pid} = login(name)
    health = living(pid).health
    assert {:ok, :immune} = Connection.fall_damage(pid, 100)
    assert {:error, :invalid_health} = Connection.fall_damage(pid, :bad)

    assert {:error, :expired_damage} =
             GenServer.call(pid, {:fall_damage, 100, System.monotonic_time(:millisecond) - 1})

    Client.send_packet(client, :play, "client_command", <<0>>)
    Client.send_packet(client, :play, "client_command", <<0>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    assert state(pid).life_stage == :alive and living(pid).health == health
    Client.send_packet(client, :play, "client_command", <<0, 0>>)
    {_, _} = Client.await(client, :play, "disconnect")
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end
end
