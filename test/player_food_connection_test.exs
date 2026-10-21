defmodule Valimc.PlayerFoodConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp

  alias Valimc.{Connection, Inventory, PlayerFood, Players, PlayerSnapshot}

  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1, park: 1, state: 1, tick: 1, ticks: 2]

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  setup do: Valimc.TestPlayer.scope("Food", {107_000, 987}, survival: {1, true})

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

  defp seed(ctx, food, health, opts \\ []) do
    mode = Keyword.get(opts, :mode, :survival)
    inventory = Keyword.get(opts, :inventory, %Inventory{})

    player = %{
      living: %Valimc.Living{
        freezing: %Freezing{},
        health: %Health{value: health},
        air_supply: 300
      },
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(mode),
      abilities: Valimc.PlayerAbilities.for_mode(mode),
      motion: %Valimc.PlayerMotion{},
      last_death: nil,
      food: food
    }

    Valimc.TestPlayer.save(ctx, player, inventory)
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
    assert living(pid).health.value == 10.0
    tick(pid)
    expected = 10.833333015441895
    assert living(pid).health.value == expected
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
      assert living(pid).health.value == 11.0
      assert state(pid).player.food == %PlayerFood{level: 18, saturation: 0.0, exhaustion: 6.0}
    after
      :sys.resume(Valimc.World.Clock)
    end

    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
    tick(pid)
    assert state(pid).player.food == %PlayerFood{level: 17, saturation: 0.0, exhaustion: 2.0}
    assert living(pid).health.value == 11.0
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

  defp assert_health(<<health::float-32, rest::binary>>, expected, food) do
    assert health == expected
    {level, <<saturation::float-32>>} = Wire.take_varint(rest)
    assert level == food.level and saturation == food.saturation
  end

  test "saved food reaches login/damage, reconnect and fresh-body respawn packets", ctx do
    food = %PlayerFood{level: 7, saturation: 0.5, exhaustion: 3.5}
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}

    player = %{
      living: %Valimc.Living{freezing: %Freezing{}, health: %Health{value: 5.0}, air_supply: 17},
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.GameMode.new(:survival),
      abilities: Valimc.PlayerAbilities.for_mode(:survival),
      motion: %Valimc.PlayerMotion{},
      last_death: nil,
      food: food
    }

    Valimc.TestPlayer.save(ctx, player, inventory)
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
