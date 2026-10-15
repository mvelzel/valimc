defmodule Valimc.PlayerFoodConnectionTest do
  use ExUnit.Case, async: false

  alias Valimc.{
    Connection,
    Inventory,
    PlayerFood,
    PlayerHealth,
    Players,
    PlayerSnapshot,
    PlayerStore
  }

  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

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

  setup do
    nonce = System.unique_integer([:positive])
    name = "Food#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-food-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{name: name, uuid: uuid, base: base, path: PlayerStore.path(base, uuid)}
  end

  defp login(ctx, expected_health, expected_food) do
    {_, client} = Client.configure_session(Client.begin_login(ctx.name), ctx.name)
    Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, expected_health, expected_food)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not :sys.get_state(pid).teleport_pending and
        Valimc.PlayerInput.loaded?(:sys.get_state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp assert_health(<<health::float-32, rest::binary>>, expected, food) do
    assert health == expected
    {level, <<saturation::float-32>>} = Wire.take_varint(rest)
    assert level == food.level and saturation == food.saturation
  end

  test "saved food reaches login/damage, reconnect and fresh-body respawn packets", ctx do
    food = %PlayerFood{level: 7, saturation: 0.5, exhaustion: 3.5, timer: 79}
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}

    player = %{
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      health: %PlayerHealth{value: 5.0},
      last_death: nil,
      air_supply: 17,
      food: food
    }

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
    {client, pid} = login(ctx, 5.0, food)
    assert {:ok, :hurt} = Connection.fall_damage(pid, 1.0)
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, 4.0, food)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == food and saved.health.value == 4.0
    assert saved.inventory.slots == inventory.slots and saved.transfer_sequence == 0
    {client, pid} = login(ctx, 4.0, food)
    assert {:ok, :dead} = Connection.fall_damage(pid, 4.0)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {body, _client} = Client.await(client, :play, "set_health")
    assert_health(body, 20.0, %PlayerFood{})
    assert :sys.get_state(pid).player.food == %PlayerFood{}
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == %PlayerFood{} and saved.air_supply == 300
    assert saved.inventory.slots == %{} and saved.transfer_sequence == 1 and saved.outbox == nil
  end
end
