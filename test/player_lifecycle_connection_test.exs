defmodule Valimc.PlayerLifecycleConnectionTest do
  use ExUnit.Case, async: false
  import Valimc.TestPlayer, only: [living: 1]
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, Players}
  alias Valimc.Player.State, as: PlayerState
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

      for {pid, _} <- Valimc.TestWorld.registered(key),
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
      PlayerState.encode(
        Connection.offline_uuid(name),
        PlayerState.capture(player, inventory)
      )

    path = path(ctx, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp path(ctx, name), do: Valimc.Player.Storage.path(ctx.base, Connection.offline_uuid(name))

  # An online player's file once it holds the live state.
  defp saved(ctx, name) do
    with %{pid: pid} <- Enum.find(Players.all(), &(&1.name == name)),
         do: Valimc.TestPlayer.checkpointed(pid)

    PlayerState.decode(File.read!(path(ctx, name)), Connection.offline_uuid(name))
  end

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
      Registry.lookup(Valimc.PlayerRegistry, Connection.offline_uuid(name)) == []
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
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    Client.close(client)
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
