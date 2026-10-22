defmodule Valimc.PlayerLifecycleConnectionTest do
  use ExUnit.Case, async: false
  import Valimc.TestPlayer, only: [living: 1]
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.Menus.Inventory
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, Wire}
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
      for {pid, player} <- :ets.tab2list(PlayerList),
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
        game_mode: Valimc.Player.GameMode.new(mode),
        abilities: Valimc.Player.Abilities.for_mode(mode),
        motion: %Valimc.Player.Motion{},
        last_death: nil
      })

    {:ok, bytes} =
      PlayerState.encode(
        Valimc.Data.UUID.offline(name),
        PlayerState.capture(player, inventory)
      )

    path = path(ctx, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp path(ctx, name), do: Valimc.Player.Storage.path(ctx.base, Valimc.Data.UUID.offline(name))

  # An online player's file once it holds the live state.
  defp saved(ctx, name) do
    with %{pid: pid} <- Enum.find(PlayerList.all(), &(&1.name == name)),
         do: Valimc.TestPlayer.checkpointed(pid)

    PlayerState.decode(File.read!(path(ctx, name)), Valimc.Data.UUID.offline(name))
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp login(name) do
    {_, client} = Client.login(name)
    client = Client.load_world(client)
    pid = Enum.find(PlayerList.all(), &(&1.name == name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.Player.Input.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp respawn(client, pid) do
    Client.send_packet(client, :play, "client_command", <<0>>)
    {body, client} = Client.await(client, :play, "respawn")
    next = state(pid)

    assert body ==
             IO.iodata_to_binary(
               elem(Valimc.Player.Packets.respawn(next.player, next.player.last_death), 1)
             )

    # Vanilla's order: the teleport right after the respawn, then the level.
    {position, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", position)
    # An unmodified client waits on this notification even after receiving chunks.
    {<<13, 0::32>>, client} = Client.await(client, :play, "game_event")
    {<<20.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.Player.Input.loaded?(state(pid).player.input)
    end)

    client
  end

  test "dead reconnect retains its screen/state; repeated death updates location without duplicating drops",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    {client, pid} = login(name)
    assert {:ok, :dead} = Valimc.TestConn.fall_damage(pid, 100)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    wait(fn -> state(pid).life_stage == :dead end)
    monitor = Process.monitor(pid)
    Client.close(client)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    wait(fn ->
      Registry.lookup(Valimc.PlayerRegistry, Valimc.Data.UUID.offline(name)) == []
    end)

    {_, client} = Client.login(name)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    client = Client.load_world(client)
    pid = Enum.find(PlayerList.all(), &(&1.name == name)).pid
    assert state(pid).life_stage == :dead and living(pid).health.value == 0
    assert state(pid).player.pose == :dying and state(pid).inventory.slots == %{}
    client = respawn(client, pid)
    assert state(pid).player.last_death == {floor(ctx.pose.x), 64, floor(ctx.pose.z)}
    assert {:ok, :dead} = Valimc.TestConn.fall_damage(pid, 100)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.last_death == {0, 64, 0}
    _client = respawn(client, pid)
    assert {:ok, stored} = saved(ctx, name)
    assert stored.last_death == {0, 64, 0} and stored.health.value == 20
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    Client.close(client)
  end

  test "a death drops orbs worth seven points a level and the respawned player starts without experience",
       ctx do
    [name | _] = ctx.names
    # Orbs move: they fall and follow the nearest player (VMC-077i).
    Valimc.TestScope.isolate(ctx.key, item_simulation: true)
    seed(ctx, name, %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    {client, pid} = login(name)
    experience = %Valimc.Player.Experience{level: 5, progress: 0.25, total: 57}
    Valimc.TestConn.replace(pid, &put_in(&1.player.progression.experience, experience))
    assert {:ok, :dead} = Valimc.TestConn.fall_damage(pid, 100)
    wait(fn -> state(pid).life_stage == :dead end)

    orbs = for {_, %{kind: :orb} = view} <- Valimc.TestWorld.item_snapshot(ctx.key), do: view
    assert Enum.sum(Enum.map(orbs, &(&1.value * &1.count))) == 35
    # Vanilla's greedy denominations (`getExperienceValue`): 17 + 17 + 1.
    assert Enum.sort(Enum.map(orbs, &{&1.value, &1.count})) == [{1, 1}, {17, 2}]
    client = respawn(client, pid)
    assert state(pid).player.progression.experience == %Valimc.Player.Experience{}
    {:ok, saved} = saved(ctx, name)
    assert saved.progression.experience == %Valimc.Player.Experience{}

    # Three blocks from the death spot the orbs fly to the player, who
    # collects every unit of every one.
    _client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 3.0})
    wait(fn -> state(pid).player.progression.experience.total == 35 end)

    wait(fn ->
      Valimc.TestWorld.item_snapshot(ctx.key) |> Enum.all?(fn {_, v} -> v.kind != :orb end)
    end)
  end

  test "creative immunity and living/duplicate respawn requests cannot resurrect or mutate",
       ctx do
    [name | _] = ctx.names
    seed(ctx, name, %Inventory{}, :creative)
    {client, pid} = login(name)
    health = living(pid).health
    assert {:ok, :immune} = Valimc.TestConn.fall_damage(pid, 100)
    assert {:error, :invalid_health} = Valimc.TestConn.fall_damage(pid, :bad)

    Client.send_packet(client, :play, "client_command", <<0>>)
    Client.send_packet(client, :play, "client_command", <<0>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    assert state(pid).life_stage == :alive and living(pid).health == health
    Client.send_packet(client, :play, "client_command", <<0, 0>>)
    {_, _} = Client.await(client, :play, "disconnect")
    assert Process.alive?(Process.whereis(Valimc.Net.Listener))
  end
end
