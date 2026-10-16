defmodule Valimc.PlayerHealthConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, Inventory, PlayerHealth, Players, PlayerSnapshot, PlayerStore}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Health#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-health-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for player <- Players.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{name: name, uuid: uuid, base: base}
  end

  defp health_login(name) do
    {_, client} = Client.configure_session(Client.begin_login(name), name)
    Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {<<health::float-32, rest::binary>>, client} = Client.await(client, :play, "set_health")
    assert {20, <<5.0::float-32>>} = Wire.take_varint(rest)
    {pid, _} = Enum.find(:ets.tab2list(Players), fn {_, player} -> player.name == name end)
    _ = :sys.get_state(pid)
    {health, client, pid}
  end

  defp departed(ctx, attempts \\ 200) do
    if Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) != [] or
         Enum.any?(Players.all(), &(&1.name == ctx.name)) do
      assert attempts > 0
      Process.sleep(5)
      departed(ctx, attempts - 1)
    end
  end

  test "login health comes from the same saved inventory state and survives another session",
       ctx do
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
      fire_ticks: 300,
      health: %PlayerHealth{value: 7.25, hurt_ticks: 7, cooldown: 17, last_hurt: 5.0}
    }

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    for _ <- 1..2 do
      {health, client, pid} = health_login(ctx.name)
      assert health == 7.25
      state = :sys.get_state(pid)
      assert state.player.health.value == 7.25
      assert state.player.fire_ticks in 1..300
      assert state.player.health.cooldown == 0 and state.player.health.last_hurt == 0
      assert state.player.health.hurt_ticks <= 7
      client = Client.load_world(client)
      assert Bitwise.band(client.entity_flags[state.player.entity_id], 1) == 1
      assert Enum.at(client.inventory.items, 36) == ItemStack.new("stone", 7)
      monitor = Process.monitor(pid)
      Client.close(client)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
      departed(ctx)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(path), ctx.uuid)
      assert saved.health.value == 7.25 and saved.health.hurt_ticks <= 7
      assert saved.fire_ticks in 1..300
      assert saved.inventory.slots == inventory.slots
      assert saved.outbox == nil and saved.transfer_sequence == 0
    end
  end

  test "legacy health defaults and timers progress despite pending teleport, with stale/early ticks inert",
       ctx do
    legacy = %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: %Inventory{}}
    {:ok, <<"VMCPOSE", 2, _::binary>> = bytes} = PlayerSnapshot.encode(ctx.uuid, legacy)
    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {health, client, pid} = health_login(ctx.name)
    assert health == 20.0
    assert :sys.get_state(pid).teleport_pending
    on_exit(fn -> Client.close(client) end)

    :sys.replace_state(pid, fn state ->
      health = %{state.player.health | value: 7.25, hurt_ticks: 10, cooldown: 20, last_hurt: 5.0}

      %{
        state
        | player: %{state.player | health: health},
          simulation_clock: %{
            state.simulation_clock
            | token: {state.simulation_clock.epoch, make_ref()},
              deadline: System.monotonic_time(:millisecond) - 1
          }
      }
    end)

    state = :sys.get_state(pid)
    token = state.simulation_clock.token
    send(pid, {:player_tick, token})
    next = :sys.get_state(pid)
    assert next.player.health == %{state.player.health | hurt_ticks: 9, cooldown: 19}
    assert next.simulation_clock.tick == state.simulation_clock.tick + 1
    send(pid, {:player_tick, token})
    assert :sys.get_state(pid).player.health == next.player.health

    :sys.replace_state(pid, fn state ->
      %{
        state
        | simulation_clock: %{
            state.simulation_clock
            | deadline: System.monotonic_time(:millisecond) + 10_000
          }
      }
    end)

    token = :sys.get_state(pid).simulation_clock.token
    send(pid, {:player_tick, token})
    early = :sys.get_state(pid)
    assert early.player.health == next.player.health
    assert early.simulation_clock.tick == next.simulation_clock.tick
    send(pid, {:player_tick, token})
    assert :sys.get_state(pid).player.health == next.player.health
  end
end
