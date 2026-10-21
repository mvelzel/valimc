defmodule Valimc.WorldBorderConnectionTest do
  use ExUnit.Case, async: false
  # Drives sockets and changes the server's one overworld border (VMC-027b/c).
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, PlayerHealth, PlayerSnapshot, PlayerStore, Players}
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.{Border, Clock}

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

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp wait(fun, left \\ 400) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

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

  test "blocks outside the border cannot be broken (vanilla mayInteract)" do
    name = "Reach#{System.unique_integer([:positive])}"
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    {x, z} = {floor(client.pose.x), floor(client.pose.z)}
    below = {x, floor(client.pose.y) - 1, z}

    assert {:ok, _} = Clock.border_command({:center, x + 1000.0, z * 1.0})
    assert {:ok, _} = Clock.border_command({:set, 10.0, 0})
    Client.send_packet(client, :play, "player_action", [<<0>>, Wire.position(below), <<1, 7>>])
    {<<7>>, client} = Client.await(client, :play, "block_changed_ack")
    refute Valimc.World.get_block(below) == 0

    reset_border()
    Client.send_packet(client, :play, "player_action", [<<0>>, Wire.position(below), <<1, 8>>])
    {_, _client} = Client.await(client, :play, "block_update")
    assert Valimc.World.get_block(below) == 0
  end

  describe "outside the border" do
    setup do
      nonce = System.unique_integer([:positive])
      name = "Outside#{nonce}"
      uuid = Connection.offline_uuid(name)
      base = Path.join(System.tmp_dir!(), "valimc-border-#{nonce}")
      old = Valimc.config(:world_path)
      Application.put_env(:valimc, :world_path, base)
      key = {107_000 + rem(nonce, 10_000), 986}
      {rx, rz} = key
      pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}

      on_exit(fn ->
        for p <- Players.all(),
            p.name == name,
            do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

        for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
            do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

        for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
            do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

        Application.put_env(:valimc, :world_path, old)
        File.rm_rf!(base)
      end)

      player =
        Map.merge(pose, %{
          game_mode: Valimc.GameMode.new(:survival),
          abilities: Valimc.PlayerAbilities.for_mode(:survival),
          motion: %Valimc.PlayerMotion{},
          environment: %Valimc.PlayerEnvironment{},
          health: %PlayerHealth{value: 20.0},
          last_death: nil,
          air_supply: 300
        })

      path = PlayerStore.path(base, uuid)
      {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(player, %Inventory{}))
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
      pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
      client = Client.load_world(client)
      Client.send_packet(client, :play, "player_loaded", <<>>)

      {body, _client} = Client.await(client, :play, "damage_event", 2000)
      {_, rest} = Wire.take_varint(body)
      {type, _} = Wire.take_varint(rest)
      assert type == Data.registry_id("minecraft:damage_type", "minecraft:outside_border")
      health = wait(fn -> (h = state(pid).player.health.value) < 20.0 and h end)
      assert health in [18.0, 16.0, 14.0]
    end

    test "inside the border, or within its safe zone, there is no damage", ctx do
      assert {:ok, _} = Clock.border_command({:center, ctx.pose.x + 7.0, ctx.pose.z})
      assert {:ok, _} = Clock.border_command({:set, 10.0, 0})
      {_, client} = Client.login(ctx.name)
      on_exit(fn -> Client.close(client) end)
      pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
      client = Client.load_world(client)
      Client.send_packet(client, :play, "player_loaded", <<>>)
      # Two blocks outside, three within the safe zone.
      wait(fn -> state(pid).simulation_clock.tick > 30 end, 2000)
      assert state(pid).player.health.value == 20.0
    end
  end
end
