defmodule Valimc.PlayerLandingConnectionTest do
  use ExUnit.Case, async: false
  import Valimc.TestPlayer, only: [living: 1]
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp

  alias Valimc.{Connection, Inventory, PlayerMotion, Players}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Land#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-landing-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {62_000 + rem(nonce, 3_333) * 3, 980}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 72.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      base: base,
      key: key,
      pose: pose,
      path: Valimc.Player.Storage.path(base, uuid)
    }
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{
          health: %Health{value: Keyword.get(opts, :health, 20.0)},
          freezing: %Freezing{},
          effects: Keyword.get(opts, :effects, %{})
        },
        y: Keyword.get(opts, :y, ctx.pose.y),
        motion: %PlayerMotion{fall_distance: Keyword.get(opts, :distance, 0.0)},
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        last_death: nil
      })

    inventory = Keyword.get(opts, :inventory, %Inventory{})
    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp move(client, pid, target, flags) do
    p = state(pid).player

    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<p.x::float-64, target::float-64, p.z::float-64, flags>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])
  end

  defp fall(client, pid, bottom) do
    p = state(pid).player
    target = max(bottom, p.y - 2.0)
    move(client, pid, target, if(target == bottom, do: 1, else: 0))

    wait(fn -> state(pid).player.y == target end)

    if target != bottom, do: fall(client, pid, bottom)
    :ok
  end

  test "accepted eight-block fall applies 5 damage once and retains it on reconnect",
       ctx do
    seed(ctx,
      y: 72.0,
      inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    )

    {client, pid} = login(ctx)
    fall(client, pid, 64.0)
    assert living(pid).health.value == 15.0
    assert state(pid).player.motion.fall_distance == 0.0

    {body, client} = Client.await(client, :play, "damage_event")
    {entity, body} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(body)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:fall")
    {<<health::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    assert health == 15.0

    Client.send_packet(client, :play, "move_player_status_only", <<1>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, client} = Client.await_stats(client)
    assert living(pid).health.value == 15.0
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 15.0
    {second, owner} = login(ctx)
    assert living(owner).health.value == saved.health.value
    assert Enum.at(second.inventory.items, 36) == ItemStack.new("stone", 7)
  end

  test "a ground-only report is sampled once instead of silently erasing saved fall distance",
       ctx do
    seed(ctx, y: 64.0, distance: 4.0)
    {client, pid} = login(ctx)
    Client.send_packet(client, :play, "move_player_status_only", <<1>>)
    wait(fn -> living(pid).health.value == 19.0 end)
    Client.send_packet(client, :play, "move_player_status_only", <<1>>)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _} = Client.await_stats(client)
    assert state(pid).player.motion.fall_distance == 0.0
    assert living(pid).health.value == 19.0
  end

  test "scratch collision cannot cause damage; rejected geometry cannot apply a landing",
       ctx do
    seed(ctx, y: 65.0, distance: 8.0)
    {client, pid} = login(ctx)
    assert :ok = Connection.set_velocity(pid, {0.0, -2.0, 0.0})
    wait(fn -> state(pid).player.motion.physical_ground end)
    assert living(pid).health.value == 20.0 and state(pid).player.y == 65.0
    move(client, pid, 63.0, 1)
    {body, client} = Client.await(client, :play, "player_position")
    _client = Client.auto_reply(client, :play, "player_position", body)
    wait(fn -> not state(pid).teleport_pending end)

    assert living(pid).health.value == 20.0 and
             state(pid).player.motion.fall_distance == 8.0
  end
end
