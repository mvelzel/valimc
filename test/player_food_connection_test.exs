defmodule Valimc.PlayerFoodConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

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
    key = {107_000 + rem(nonce, 10_000), 987}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    old = Valimc.config(:world_path)
    {difficulty, regeneration} = Valimc.World.Clock.survival()
    :ok = Valimc.World.Clock.configure({:difficulty, 1, true})
    :ok = Valimc.World.Clock.configure({:natural_regeneration, true})
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for p <- Players.all(),
          p.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, p.pid)

      for {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, uuid),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      :ok = Valimc.World.Clock.configure({:difficulty, difficulty, true})
      :ok = Valimc.World.Clock.configure({:natural_regeneration, regeneration})
      File.rm_rf!(base)
    end)

    %{
      name: name,
      uuid: uuid,
      base: base,
      path: PlayerStore.path(base, uuid),
      key: key,
      pose: pose
    }
  end

  defp login(ctx, expected_health, expected_food) do
    {_, client} = Client.configure_session(Client.begin_login(ctx.name), ctx.name)
    Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, expected_health, expected_food)

    {pid, _} =
      wait(fn -> Enum.find(:ets.tab2list(Players), fn {_, p} -> p.name == ctx.name end) end)

    park(pid)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not Valimc.TestConn.state(pid).teleport_pending and
        Valimc.PlayerInput.loaded?(Valimc.TestConn.state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp state(pid), do: Valimc.TestConn.state(pid)

  defp park(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | simulation_clock: %{
            state.simulation_clock
            | token: {state.simulation_clock.epoch, make_ref()},
              deadline: System.monotonic_time(:millisecond) + 60_000
          }
      }
    end)
  end

  defp tick(pid) do
    before =
      :sys.replace_state(pid, fn state ->
        %{
          state
          | simulation_clock: %{
              state.simulation_clock
              | deadline: System.monotonic_time(:millisecond)
            }
        }
      end)

    send(pid, {:player_tick, before.simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)
    before.simulation_clock.token
  end

  defp ticks(pid, count), do: Enum.each(1..count, fn _ -> tick(pid) end)

  defp seed(ctx, food, health, opts \\ []) do
    mode = Keyword.get(opts, :mode, :survival)
    inventory = Keyword.get(opts, :inventory, %Inventory{})

    player = %{
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(mode),
      abilities: Valimc.PlayerAbilities.for_mode(mode),
      motion: %Valimc.PlayerMotion{},
      environment: %Valimc.PlayerEnvironment{},
      health: %PlayerHealth{value: health},
      last_death: nil,
      air_supply: 300,
      food: food
    }

    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
  end

  test "saturated recovery is admitted once, replicates hearts and saves its exact timer", ctx do
    food = %PlayerFood{}
    seed(ctx, food, 10.0)
    {client, pid} = login(ctx, 10.0, food)
    stale = tick(pid)
    fields = [:food, :health]
    before = Map.take(state(pid).player, fields)
    before_tick = state(pid).simulation_clock.tick
    for _ <- 1..20, do: send(pid, {:player_tick, stale})
    assert Map.take(state(pid).player, fields) == before
    assert state(pid).simulation_clock.tick == before_tick
    send(pid, {:player_tick, state(pid).simulation_clock.token})
    assert Map.take(state(pid).player, fields) == before
    assert state(pid).simulation_clock.tick == before_tick
    ticks(pid, 8)
    assert state(pid).player.health.value == 10.0
    tick(pid)
    expected = 10.833333015441895
    assert state(pid).player.health.value == expected
    assert state(pid).player.food == %PlayerFood{exhaustion: 5.0}
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, expected, food)
    tick(pid)
    saved_food = %PlayerFood{saturation: 4.0, exhaustion: 1.0, timer: 1}
    assert state(pid).player.food == saved_food
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == saved_food and saved.health.value == expected
    {_client, owner} = login(ctx, expected, saved_food)
    assert state(owner).player.food == saved_food and state(owner).food_tick_origin == 0
  end

  test "ordinary recovery, rule changes and stalled world owner use the published settings",
       ctx do
    food = %PlayerFood{level: 18, saturation: 0.0, timer: 79}
    seed(ctx, food, 10.0)
    {_client, pid} = login(ctx, 10.0, food)
    :sys.suspend(Valimc.World.Clock)

    try do
      tick(pid)
      assert state(pid).player.health.value == 11.0
      assert state(pid).player.food == %PlayerFood{level: 18, saturation: 0.0, exhaustion: 6.0}
    after
      :sys.resume(Valimc.World.Clock)
    end

    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
    tick(pid)
    assert state(pid).player.food == %PlayerFood{level: 17, saturation: 0.0, exhaustion: 2.0}
    assert state(pid).player.health.value == 11.0
  end

  test "exhaustion spends saturation then food, one bounded step per tick", ctx do
    food = %PlayerFood{level: 18, saturation: 0.5, exhaustion: 40.0}
    seed(ctx, food, 20.0)
    {client, pid} = login(ctx, 20.0, food)
    tick(pid)
    first = %PlayerFood{level: 18, saturation: 0.0, exhaustion: 36.0}
    assert state(pid).player.food == first
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, 20.0, first)
    tick(pid)
    second = %PlayerFood{level: 17, saturation: 0.0, exhaustion: 32.0}
    assert state(pid).player.food == second
    {body, _client} = Client.await(client, :play, "set_health")
    assert_health(body, 20.0, second)
  end

  test "peaceful body recovery restores food every ten ticks and health/saturation every twenty",
       ctx do
    :ok = Valimc.World.Clock.configure({:difficulty, 0, true})
    food = %PlayerFood{level: 0, saturation: 19.5}
    seed(ctx, food, 10.0)
    {_client, pid} = login(ctx, 10.0, food)
    ticks(pid, 9)
    assert state(pid).player.food.level == 0
    tick(pid)
    assert state(pid).player.food.level == 1 and state(pid).player.health.value == 10.0
    ticks(pid, 10)
    assert state(pid).player.food == %PlayerFood{level: 2, saturation: 20.5}
    assert state(pid).player.health.value == 11.0
    assert rem(state(pid).simulation_clock.tick - state(pid).food_tick_origin, 20) == 0
    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
    ticks(pid, 20)
    assert state(pid).player.health.value == 11.0
    assert state(pid).player.food == %PlayerFood{level: 2, saturation: 20.5}
  end

  test "starvation keeps difficulty floors, bypasses gear and respects the normal hurt window",
       ctx do
    food = %PlayerFood{level: 0, saturation: 0.0, timer: 79}

    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{"minecraft:enchantments" => %{"minecraft:protection" => 255}}
    }

    seed(ctx, food, 11.0, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx, 11.0, food)
    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
    tick(pid)
    assert state(pid).player.health.value == 10.0 and state(pid).inventory.slots[5] == helmet
    {body, client} = Client.await(client, :play, "damage_event")
    {_, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert source == Valimc.Protocol.Data.registry_id("minecraft:damage_type", "minecraft:starve")
    ticks(pid, 80)
    assert state(pid).player.health.value == 10.0
    :ok = Valimc.World.Clock.configure({:difficulty, 2, true})
    ticks(pid, 80)
    assert state(pid).player.health.value == 9.0
    # A stronger simultaneous source owns the ordinary damage immunity window.
    assert {:ok, :hurt} = Connection.fall_damage(pid, 2.0)
    protected_health = state(pid).player.health.value
    assert protected_health < 9.0

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | food: %{s.player.food | timer: 79}}}
    end)

    tick(pid)

    assert state(pid).player.health.value == protected_health and
             state(pid).player.food.timer == 0

    Client.close(client)
  end

  test "hard starvation uses durable death transfers and resets food on actual respawn command",
       ctx do
    :ok = Valimc.World.Clock.configure({:difficulty, 3, true})
    food = %PlayerFood{level: 0, saturation: 0.0, timer: 79}
    inventory = %Inventory{slots: Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)})}
    seed(ctx, food, 1.0, inventory: inventory)
    {client, pid} = login(ctx, 1.0, food)
    tick(pid)
    {body, client} = Client.await(client, :play, "player_combat_kill")
    assert :binary.match(body, "death.attack.starve") != :nomatch
    ticks(pid, 10)
    assert state(pid).player.food == %PlayerFood{level: 0, saturation: 0.0}
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {body, _client} = Client.await(client, :play, "set_health")
    assert_health(body, 20.0, %PlayerFood{})
    assert state(pid).player.food == %PlayerFood{}
    assert state(pid).food_tick_origin == state(pid).simulation_clock.tick
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == %PlayerFood{} and saved.health.value == 20.0
    assert saved.transfer_sequence == 2 and saved.outbox == nil and saved.inventory.slots == %{}
  end

  test "creative starvation requests remain immune without consuming the hurt window", ctx do
    food = %PlayerFood{level: 0, saturation: 0.0, timer: 79}
    :ok = Valimc.World.Clock.configure({:difficulty, 3, true})
    seed(ctx, food, 1.0, mode: :creative)
    {_client, pid} = login(ctx, 1.0, food)
    tick(pid)
    assert state(pid).player.health.value == 1.0 and state(pid).player.health.cooldown == 0
    assert state(pid).player.food.timer == 0 and state(pid).life_stage == :alive
  end

  test "healthy idle food retains the body boundary across a world setting change", ctx do
    food = %PlayerFood{saturation: 0.0}
    seed(ctx, food, 20.0)
    {_client, pid} = login(ctx, 20.0, food)
    ticks(pid, 19)
    assert state(pid).player.food == food and state(pid).food_tick_origin == 0
    :ok = Valimc.World.Clock.configure({:difficulty, 0, true})
    tick(pid)
    assert state(pid).player.food == %PlayerFood{saturation: 1.0}
    ticks(pid, 19)
    assert state(pid).player.food == %PlayerFood{saturation: 1.0}
    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
    tick(pid)
    assert state(pid).player.food == %PlayerFood{saturation: 1.0}
  end

  defp assert_health(<<health::float-32, rest::binary>>, expected, food) do
    assert health == expected
    {level, <<saturation::float-32>>} = Wire.take_varint(rest)
    assert level == food.level and saturation == food.saturation
  end

  test "saved food reaches login/damage, reconnect and fresh-body respawn packets", ctx do
    food = %PlayerFood{level: 7, saturation: 0.5, exhaustion: 3.5}
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}

    player = %{
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
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
    assert Valimc.TestConn.state(pid).player.food == %PlayerFood{}
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == %PlayerFood{} and saved.air_supply == 300
    assert saved.inventory.slots == %{} and saved.transfer_sequence == 1 and saved.outbox == nil
  end
end
