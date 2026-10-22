defmodule Valimc.PlayerHealthConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp
  alias Valimc.Menus.Inventory
  alias Valimc.Player.PlayerList
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Health#{nonce}"
    uuid = Valimc.Data.UUID.offline(name)
    base = Path.join(System.tmp_dir!(), "valimc-health-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for player <- PlayerList.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_players(base)
      # Its sections would otherwise save into the removed folder as they unload.
      Valimc.TestScope.stop_neighbourhood({0, 0})
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
    {pid, _} = Enum.find(:ets.tab2list(PlayerList), fn {_, player} -> player.name == name end)
    _ = Valimc.TestConn.state(pid)
    {health, client, pid}
  end

  defp departed(ctx, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] and
        not Enum.any?(PlayerList.all(), &(&1.name == ctx.name))
    end)
  end

  test "login health comes from the same saved inventory state and survives another session",
       ctx do
    player = %{
      living: %Valimc.Living{
        freezing: %Freezing{},
        fire_ticks: 300,
        health: %Health{value: 7.25, hurt_ticks: 7, cooldown: 17, last_hurt: 5.0}
      },
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil
    }

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    for _ <- 1..2 do
      {health, client, pid} = health_login(ctx.name)
      assert health == 7.25
      state = Valimc.TestConn.state(pid)
      assert state.player.living.health.value == 7.25
      assert state.player.living.fire_ticks in 1..300

      assert state.player.living.health.cooldown == 0 and
               state.player.living.health.last_hurt == 0

      assert state.player.living.health.hurt_ticks <= 7
      client = Client.load_world(client)
      assert Bitwise.band(client.entity_flags[state.player.entity_id], 1) == 1
      assert Enum.at(client.inventory.items, 36) == ItemStack.new("stone", 7)
      monitor = Process.monitor(pid)
      Client.close(client)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      departed(ctx)
      assert {:ok, saved} = PlayerState.decode(File.read!(path), ctx.uuid)
      assert saved.health.value == 7.25 and saved.health.hurt_ticks <= 7
      assert saved.fire_ticks in 1..300
      assert saved.inventory.slots == inventory.slots
    end
  end

  test "legacy health defaults and timers progress despite pending teleport, with stale/early ticks inert",
       ctx do
    legacy = %{pose: %{x: 0.5, y: 64.0, z: 0.5, yaw: 0.0, pitch: 0.0}, inventory: %Inventory{}}
    {:ok, bytes} = PlayerState.encode(ctx.uuid, legacy)
    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {health, client, pid} = health_login(ctx.name)
    assert health == 20.0
    assert Valimc.TestConn.state(pid).teleport_pending
    on_exit(fn -> Client.close(client) end)

    Valimc.TestConn.replace(pid, fn state ->
      health = %{
        state.player.living.health
        | value: 7.25,
          hurt_ticks: 10,
          cooldown: 20,
          last_hurt: 5.0
      }

      %{
        state
        | player: %{state.player | living: %{state.player.living | health: health}},
          simulation_clock: %{
            state.simulation_clock
            | token: {state.simulation_clock.epoch, make_ref()},
              deadline: System.monotonic_time(:millisecond) - 1
          }
      }
    end)

    state = Valimc.TestConn.state(pid)
    token = state.simulation_clock.token
    send(pid, {:player_tick, token})
    next = Valimc.TestConn.state(pid)

    assert next.player.living.health == %{
             state.player.living.health
             | hurt_ticks: 9,
               cooldown: 19
           }

    assert next.simulation_clock.tick == state.simulation_clock.tick + 1
    send(pid, {:player_tick, token})
    assert Valimc.TestPlayer.living(pid).health == next.player.living.health

    Valimc.TestConn.replace(pid, fn state ->
      %{
        state
        | simulation_clock: %{
            state.simulation_clock
            | deadline: System.monotonic_time(:millisecond) + 10_000
          }
      }
    end)

    token = Valimc.TestConn.state(pid).simulation_clock.token
    send(pid, {:player_tick, token})
    early = Valimc.TestConn.state(pid)
    assert early.player.living.health == next.player.living.health
    assert early.simulation_clock.tick == next.simulation_clock.tick
    send(pid, {:player_tick, token})
    assert Valimc.TestPlayer.living(pid).health == next.player.living.health
  end
end
