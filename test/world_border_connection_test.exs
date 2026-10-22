defmodule Valimc.WorldBorderConnectionTest do
  use ExUnit.Case, async: false
  import Valimc.TestPlayer, only: [living: 1]
  alias Valimc.Living.{Freezing, Health}
  # Drives sockets and changes the server's one overworld border and the app-wide
  # respawn radius (VMC-027b/c/e).
  @moduletag :tcp
  alias Valimc.Net.Connection
  alias Valimc.Menus.Inventory
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.{Border, Clock, Spawn}

  setup do
    reset_border()
    on_exit(&reset_border/0)
    :ok
  end

  defp reset_border do
    for operation <- [
          {:set, Border.max_size(), 0},
          {:center, 0.0, 0.0},
          {:damage_amount, 0.2},
          {:damage_buffer, 5.0},
          {:warning_time, 300},
          {:warning_distance, 5}
        ],
        do: Clock.border_command(operation)
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp command(client, input, key) do
    Client.send_packet(client, :play, "chat_command", Wire.string(input))
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, key) != :nomatch, "#{input}: #{inspect(body)}"
    client
  end

  test "joining players get the border, then vanilla's packet for each change" do
    assert {:ok, _} = Clock.border_command({:center, 8.5, -4.25})
    name = "Border#{System.unique_integer([:positive])}"
    client = Client.begin_login(name)
    {_uuid, client} = Client.configure_session(client, name)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {body, client} = Client.await(client, :play, "initialize_border")
    on_exit(fn -> Client.close(client) end)

    size = Border.max_size()

    assert body ==
             IO.iodata_to_binary([
               <<8.5::float-64, -4.25::float-64, size::float-64, size::float-64>>,
               Wire.varlong(0),
               Wire.varint(29_999_984),
               Wire.varint(5),
               Wire.varint(300)
             ])

    client = Client.load_world(client)
    client = command(client, "worldborder set 100", "commands.worldborder.set.immediate")
    {body, client} = Client.await(client, :play, "set_border_size")
    assert body == <<100.0::float-64>>

    client = command(client, "worldborder set 20 10s", "commands.worldborder.set.shrink")
    {body, client} = Client.await(client, :play, "set_border_lerp_size")
    # Observed up to a publish tick later: the current size and remaining ticks.
    <<size::float-64, 20.0::float-64, rest::binary>> = body
    {:ok, ticks, <<>>} = Wire.read_varint(rest)
    assert ticks in 190..200 and abs(size - (100.0 - (200 - ticks) * 0.4)) < 1.0e-9

    client = command(client, "worldborder center 1 2", "commands.worldborder.center.success")
    {body, client} = Client.await(client, :play, "set_border_center")
    assert body == <<1.5::float-64, 2.5::float-64>>

    client = command(client, "worldborder warning time 2s", "commands.worldborder.warning.time")
    {body, client} = Client.await(client, :play, "set_border_warning_delay")
    assert body == Wire.varint(40)

    client = command(client, "worldborder warning distance 9", "warning.distance.success")
    {body, client} = Client.await(client, :play, "set_border_warning_distance")
    assert body == Wire.varint(9)

    client = command(client, "worldborder damage amount 1", "damage.amount.success")
    client = command(client, "worldborder damage amount 1", "damage.amount.failed")
    _client = command(client, "worldborder get", "commands.worldborder.get")
    assert Border.lerp_target(Clock.border()) == 20.0
    assert Clock.border().damage_per_block == 1.0
  end

  describe "outside the border" do
    setup do
      nonce = System.unique_integer([:positive])
      name = "Outside#{nonce}"
      uuid = Connection.offline_uuid(name)
      base = Path.join(System.tmp_dir!(), "valimc-border-#{nonce}")
      old = Valimc.config(:world_path)
      Application.put_env(:valimc, :world_path, base)
      key = {107_000 + rem(nonce, 3_333) * 3, 986}
      {rx, rz} = key
      pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

      on_exit(fn ->
        for p <- PlayerList.all(),
            p.name == name,
            do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

        for {pid, _} <- Valimc.TestWorld.registered(key),
            do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

        Application.put_env(:valimc, :world_path, old)
        Valimc.TestScope.stop_neighbourhood(key, spawn: true)
        Valimc.TestScope.stop_players(base)
        File.rm_rf!(base)
      end)

      player =
        Map.merge(pose, %{
          living: %Valimc.Living{
            freezing: %Freezing{},
            health: %Health{value: 20.0},
            air_supply: 300
          },
          game_mode: Valimc.Player.GameMode.new(:survival),
          abilities: Valimc.Player.Abilities.for_mode(:survival),
          motion: %Valimc.Player.Motion{},
          last_death: nil
        })

      path = Valimc.Player.Storage.path(base, uuid)
      {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(player, %Inventory{}))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      %{name: name, pose: pose}
    end

    test "a survival player takes outside-border damage per block beyond the safe zone", ctx do
      # The nearest edge is 15 blocks east: 10 beyond the safe zone at 0.2 per block.
      assert {:ok, _} = Clock.border_command({:center, ctx.pose.x + 20.0, ctx.pose.z})
      assert {:ok, _} = Clock.border_command({:set, 10.0, 0})
      {_, client} = Client.login(ctx.name)
      on_exit(fn -> Client.close(client) end)
      pid = wait(fn -> Enum.find(PlayerList.all(), &(&1.name == ctx.name)) end).pid
      client = Client.load_world(client)
      Client.send_packet(client, :play, "player_loaded", <<>>)

      {body, _client} = Client.await(client, :play, "damage_event", 2000)
      {_, rest} = Wire.take_varint(body)
      {type, _} = Wire.take_varint(rest)
      assert type == Data.registry_id("minecraft:damage_type", "minecraft:outside_border")
      health = wait(fn -> (h = living(pid).health.value) < 20.0 and h end)
      assert health in [18.0, 16.0, 14.0]
    end
  end

  describe "spawning" do
    setup do
      Application.put_env(:valimc, :respawn_radius, 10)
      on_exit(fn -> Application.put_env(:valimc, :respawn_radius, 0) end)
    end

    defp join do
      name = "Spawn#{System.unique_integer([:positive])}"
      {_, client} = Client.login(name)
      on_exit(fn -> Client.close(client) end)
      client.pose
    end

    test "new players appear on a safe column within the respawn radius of the world spawn" do
      {sx, sy, sz} = Spawn.position()

      for pose <- [join(), join()] do
        assert abs(pose.x - (sx + 0.5)) <= 10 and abs(pose.z - (sz + 0.5)) <= 10
        assert pose.x - floor(pose.x) == 0.5 and pose.z - floor(pose.z) == 0.5
        # The preview's flat world: grass at 63, so everyone stands at 64.
        assert pose.y == sy * 1.0
      end
    end

    test "a world spawn outside the border moves to the border's centre" do
      assert {:ok, _} = Clock.border_command({:center, 1000.5, -2000.5})
      assert {:ok, _} = Clock.border_command({:set, 4.0, 0})
      pose = join()
      # Within the radius the border leaves: at most 1 block from the centre column.
      assert abs(pose.x - 1000.5) <= 1 and abs(pose.z - -2000.5) <= 1
    end
  end
end
