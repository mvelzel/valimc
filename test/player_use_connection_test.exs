defmodule Valimc.PlayerUseConnectionTest do
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
    name = "Use#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-use-#{nonce}")
    key = {137_000 + rem(nonce, 10_000), 987}
    {rx, rz} = key
    pose = %{x: rx * 128 + 40.5, y: 64.0, z: rz * 128 + 40.5, yaw: 0.0, pitch: 0.0}
    old = Valimc.config(:world_path)
    {difficulty, regeneration} = Valimc.World.Clock.survival()
    :ok = Valimc.World.Clock.configure({:difficulty, 1, true})
    :ok = Valimc.World.Clock.configure({:natural_regeneration, false})
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
      not :sys.get_state(pid).teleport_pending and
        Valimc.PlayerInput.loaded?(:sys.get_state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp state(pid), do: :sys.get_state(pid)

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

  defp seed(ctx, food, health, opts) do
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

  defp assert_health(<<health::float-32, rest::binary>>, expected, food) do
    assert health == expected
    {level, <<saturation::float-32>>} = Wire.take_varint(rest)
    assert level == food.level and saturation == food.saturation
  end

  defp use_hand(client, pid, hand \\ :main, sequence \\ 1) do
    Client.send_packet(
      client,
      :play,
      "use_item",
      IO.iodata_to_binary([
        Wire.varint(if(hand == :main, do: 0, else: 1)),
        Wire.varint(sequence),
        <<540::float-32, 0::float-32>>
      ])
    )

    {<<^sequence>>, client} = Client.await(client, :play, "block_changed_ack")
    _ = state(pid)
    client
  end

  defp action(client, name) do
    Client.send_packet(
      client,
      :play,
      "player_action",
      IO.iodata_to_binary([
        Wire.varint(Valimc.Protocol.ItemTypes.action_id(name)),
        Wire.position({0, 64, 0}),
        <<0, 0>>
      ])
    )
  end

  test "native duration finishes each hand once, orders completion before inventory, and reconnects atomically",
       ctx do
    food = %PlayerFood{level: 3, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread, 45 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    assert state(pid).active_use.remaining == 32 and state(pid).player.use_flags == 1
    assert state(pid).player.yaw == -180.0
    stale = tick(pid)
    client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use.hand == :main and state(pid).active_use.remaining == 31
    send(pid, {:player_tick, stale})
    assert state(pid).active_use.remaining == 31
    ticks(pid, 30)
    assert state(pid).active_use.remaining == 1 and state(pid).player.food == food
    tick(pid)
    {<<id::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    assert id == state(pid).player.entity_id
    {_, client} = Client.await(client, :play, "container_set_content")
    assert state(pid).inventory.slots[36].count == 1
    assert state(pid).inventory.slots[45] == bread
    assert state(pid).player.food == %PlayerFood{level: 8, saturation: 6.0}
    assert state(pid).active_use == nil and state(pid).player.use_flags == 0
    wait(fn -> state(pid).use_save == nil end)
    client = use_hand(client, pid, :off, 3)
    assert state(pid).player.use_flags == 3
    ticks(pid, 32)
    {<<^id::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    assert state(pid).inventory.slots[45].count == 1 and state(pid).player.use_flags == 2
    assert state(pid).player.food == %PlayerFood{level: 13, saturation: 12.0}
    ticks(pid, 3)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.inventory.slots[36].count == 1 and saved.inventory.slots[45].count == 1
    assert saved.food == %PlayerFood{level: 13, saturation: 12.0}
    assert saved.transfer_sequence == 0 and saved.outbox == nil
    {_client, owner} = login(ctx, 20.0, saved.food)
    assert state(owner).active_use == nil and state(owner).player.use_flags == 0
  end

  test "release, different item, changed main slot and swap cancel while offhand selection does not",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread, 37 => bread, 45 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 8)
    action(client, "release_use_item")
    wait(fn -> state(pid).active_use == nil end)
    client = use_hand(client, pid, :main, 2)
    Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
    wait(fn -> state(pid).inventory.selected == 1 end)
    assert state(pid).active_use == nil
    client = use_hand(client, pid, :off, 3)
    Client.send_packet(client, :play, "set_carried_item", <<0::signed-16>>)
    wait(fn -> state(pid).inventory.selected == 0 end)
    assert state(pid).active_use.hand == :off
    action(client, "swap_item_with_offhand")
    wait(fn -> state(pid).active_use == nil end)
    client = use_hand(client, pid, :main, 4)

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %{s.inventory | slots: Map.put(s.inventory.slots, 36, ItemStack.new("dirt"))}
      }
    end)

    tick(pid)
    assert state(pid).active_use == nil
    ticks(pid, 32)
    assert state(pid).player.food == food
    assert state(pid).inventory.slots[45] == bread
    Client.close(client)
  end

  test "current count and components drive completion, not the initial stack snapshot", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid)
    ticks(pid, 31)

    latest = %{
      bread
      | count: 1,
        components: %{"minecraft:food" => %{nutrition: 2, saturation: 1.0, can_always_eat: false}}
    }

    :sys.replace_state(pid, fn s -> %{s | inventory: %{s.inventory | slots: %{36 => latest}}} end)
    tick(pid)
    assert state(pid).inventory.slots == %{}
    assert state(pid).player.food == %PlayerFood{level: 7, saturation: 1.0}
  end

  test "full food rejects ordinary meals, always-eat permits them and unsupported listeners do nothing",
       ctx do
    bread = ItemStack.new("bread", 2)
    seed(ctx, %PlayerFood{}, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, %PlayerFood{})
    client = use_hand(client, pid)
    assert state(pid).active_use == nil
    props = Valimc.FoodItems.properties(bread).food
    patched = %{bread | components: %{"minecraft:food" => %{props | can_always_eat: true}}}

    :sys.replace_state(pid, fn s -> %{s | inventory: %{s.inventory | slots: %{36 => patched}}} end)

    client = use_hand(client, pid, :main, 2)
    ticks(pid, 32)
    assert state(pid).inventory.slots[36].count == 1
    assert state(pid).player.food == %PlayerFood{saturation: 11.0}
    wait(fn -> state(pid).save_ref == nil end)

    for {name, seq} <-
          Enum.with_index(["honey_bottle", "potion", "suspicious_stew", "milk_bucket"], 3) do
      :sys.replace_state(pid, fn s ->
        %{s | inventory: %{s.inventory | slots: %{36 => ItemStack.new(name)}}}
      end)

      _ = use_hand(client, pid, :main, seq)
      assert state(pid).active_use == nil
      assert state(pid).inventory.slots[36] == ItemStack.new(name)
    end
  end

  test "creative consumes nutrition without removing the item or creating its remainder", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    stew = ItemStack.new("mushroom_stew")
    seed(ctx, food, 20.0, mode: :creative, inventory: %Inventory{slots: %{45 => stew}})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid, :off)
    ticks(pid, 32)
    assert state(pid).inventory.slots == %{45 => stew}
    assert state(pid).player.food.level == 11
  end

  test "last soup becomes a bowl in the same hand even with every storage slot full", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}

    slots =
      Map.new(9..44, &{&1, ItemStack.new("stone", 64)})
      |> Map.put(45, ItemStack.new("mushroom_stew"))

    seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid, :off)
    ticks(pid, 32)
    assert state(pid).inventory.slots == Map.put(slots, 45, ItemStack.new("bowl"))
    assert state(pid).player.food.level == 11
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.inventory.slots == state(pid).inventory.slots
    assert saved.inventory.selected == state(pid).inventory.selected
    assert saved.food == state(pid).player.food
  end

  test "stalled consumption save keeps later food ticks and blocks inventory transfer until acknowledgement",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 3)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    store = state(pid).player_store
    :sys.suspend(store)

    try do
      ticks(pid, 32)
      assert state(pid).use_save != nil and state(pid).inventory.slots[36].count == 2
      client = use_hand(client, pid, :main, 2)
      assert state(pid).active_use == nil
      action(client, "drop_item")

      :sys.replace_state(pid, fn s ->
        player = %{s.player | food: %{s.player.food | exhaustion: 5.0}}
        Players.update(pid, player)
        %{s | player: player}
      end)

      tick(pid)
      assert state(pid).player.food == %PlayerFood{level: 10, saturation: 5.0, exhaustion: 1.0}
      assert state(pid).inventory.slots[36].count == 2 and state(pid).recovery == nil
      :sys.resume(store)
      wait(fn -> state(pid).use_save == nil end)
      assert state(pid).player.food == %PlayerFood{level: 10, saturation: 5.0, exhaustion: 1.0}
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.food == %PlayerFood{level: 10, saturation: 5.0, exhaustion: 1.0}
      assert saved.inventory.slots[36].count == 2 and saved.transfer_sequence == 0
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
  end

  test "disconnect and fatal damage retire unfinished use without consuming", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 10)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {client, pid} = login(ctx, 20.0, food)
    assert state(pid).inventory.slots[36] == bread and state(pid).active_use == nil
    _client = use_hand(client, pid)
    assert {:ok, :dead} = Connection.fall_damage(pid, 100.0)
    assert state(pid).active_use == nil and state(pid).player.use_flags == 0
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.food == food
    assert state(pid).inventory.slots == %{}
  end

  test "a prior checkpoint defers completion without resetting or duplicating the use", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid)
    store = state(pid).player_store
    :sys.suspend(store)

    try do
      send(pid, :save_player)
      wait(fn -> state(pid).save_ref != nil end)
      ticks(pid, 35)
      assert state(pid).active_use.remaining == 0
      assert state(pid).inventory.slots[36] == bread and state(pid).player.food == food
      :sys.resume(store)
      wait(fn -> state(pid).save_ref == nil end)
      tick(pid)
      assert state(pid).inventory.slots[36].count == 1 and state(pid).player.food.level == 10
      ticks(pid, 3)
      assert state(pid).inventory.slots[36].count == 1
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
  end

  test "unsupported patched remainder overflow rejects food and inventory together", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    soup = %{ItemStack.new("mushroom_stew", 2) | components: %{"minecraft:max_stack_size" => 64}}
    slots = Map.new(9..45, &{&1, ItemStack.new("stone", 64)}) |> Map.put(45, soup)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid, :off)
    ticks(pid, 32)
    assert state(pid).active_use == nil and state(pid).use_save == nil
    assert state(pid).inventory.slots == slots and state(pid).player.food == food
  end

  test "unloaded requests and spectator use cannot begin a meal", ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread")
    seed(ctx, food, 20.0, mode: :spectator, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    assert state(pid).active_use == nil

    :sys.replace_state(pid, fn s ->
      player = %{
        s.player
        | input: %Valimc.PlayerInput{},
          game_mode: Valimc.GameMode.new(:survival)
      }

      %{s | player: player}
    end)

    Client.send_packet(client, :play, "use_item", <<0, 2, 0::float-32, 0::float-32>>)
    # TCP ordering barrier after the intentionally unacknowledged unloaded request.
    Client.send_packet(client, :play, "set_carried_item", <<0::signed-16>>)
    {_, _client} = Client.await(client, :play, "set_held_slot")
    assert state(pid).active_use == nil and state(pid).inventory.slots[36] == bread
  end
end
