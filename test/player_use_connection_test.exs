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

  alias Valimc.Protocol.{Data, ItemStack, PotionContents, PotionTypes, UseItemOn, Wire}
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
      effects: Keyword.get(opts, :effects, %{}),
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

  defp potion(name) do
    %{
      ItemStack.new("potion")
      | components: %{
          "minecraft:potion_contents" => %{PotionContents.empty() | potion: PotionTypes.id(name)}
        }
    }
  end

  defp effect_packet(client) do
    {body, client} = Client.await(client, :play, "update_mob_effect")
    {entity, rest} = Wire.take_varint(body)
    {id, rest} = Wire.take_varint(rest)
    {amp, rest} = Wire.take_varint(rest)
    {duration, <<flags>>} = Wire.take_varint(rest)
    {{entity, id, amp, duration, flags}, client}
  end

  defp speed_attribute(client, pid) do
    {body, client} = Client.await(client, :play, "update_attributes")
    client = Client.auto_reply(client, :play, "update_attributes", body)

    {:ok, derived} =
      Valimc.PlayerMovementSpeed.derive(
        state(pid).player.effects,
        Bitwise.band(state(pid).player.input.shared_flags, 8) != 0
      )

    {26, base, modifiers} = derived.attribute
    assert client.attributes[{state(pid).player.entity_id, 26}] == {base, modifiers}
    client
  end

  defp quiet_attributes_until_stats(client) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)
    assert name != "update_attributes"

    if name == "system_chat",
      do: client,
      else: quiet_attributes_until_stats(Client.auto_reply(client, :play, name, body))
  end

  defp block_then_drink(client, ctx) do
    {:ok, on} =
      UseItemOn.encode(%{
        hand: :main,
        position: {floor(ctx.pose.x), 63, floor(ctx.pose.z)},
        face: 1,
        cursor: {0.5, 1.0, 0.5},
        inside: false,
        border: false,
        sequence: 1
      })

    use = IO.iodata_to_binary([<<0, 2>>, <<0.0::float-32, 90.0::float-32>>])

    Client.send_raw(client, [
      Wire.frame(Data.id(:play, :serverbound, "use_item_on"), on, client.threshold),
      Wire.frame(Data.id(:play, :serverbound, "use_item"), use, client.threshold)
    ])
  end

  test "block-targeted drinking waits for asynchronous block admission instead of rejecting the following use",
       ctx do
    food = %PlayerFood{}
    drink = potion("fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    client = block_then_drink(client, ctx)
    {<<1>>, client} = Client.await(client, :play, "block_changed_ack")
    {<<2>>, _client} = Client.await(client, :play, "block_changed_ack")
    wait(fn -> state(pid).active_use != nil end)
    assert state(pid).active_use.remaining == 32
    ticks(pid, 32)
    assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
    assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
  end

  test "an unavailable block owner times out its admission without blocking the player clock or losing the fallback",
       ctx do
    food = %PlayerFood{}
    drink = potion("fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    {:ok, {region, _}} = Valimc.World.existing_owner(ctx.key)
    :sys.suspend(region)

    try do
      client = block_then_drink(client, ctx)
      wait(fn -> state(pid).table_job != nil end)
      assert byte_size(state(pid).buffer) > 0 and not state(pid).active
      tick(pid)
      assert state(pid).active_use == nil and state(pid).player.effects == %{}
      {<<1>>, client} = Client.await(client, :play, "block_changed_ack")
      {<<2>>, _client} = Client.await(client, :play, "block_changed_ack")
      wait(fn -> state(pid).active_use != nil end)
      assert state(pid).table_job == nil and state(pid).active_use.remaining == 32
      :sys.resume(region)
      ticks(pid, 32)
      assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
      assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
    after
      if Process.alive?(region), do: :sys.resume(region)
    end
  end

  test "both-hand potion completion grants only after native timing and saves effects with the bottle",
       ctx do
    food = %PlayerFood{}
    fire = potion("fire_resistance")
    long = potion("long_fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => fire, 45 => long}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    assert state(pid).active_use.remaining == 32
    ticks(pid, 31)
    assert state(pid).inventory.slots[36] == fire and state(pid).player.effects == %{}
    tick(pid)
    {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 11, 0, 3600, 14}, client} = effect_packet(client)
    assert state(pid).inventory.slots[36] == ItemStack.new("glass_bottle")
    assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
    assert state(pid).player.food == food
    wait(fn -> state(pid).use_save == nil end)

    client = use_hand(client, pid, :off, 2)
    assert state(pid).player.use_flags == 3
    ticks(pid, 32)
    {<<^entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 11, 0, 9600, 6}, client} = effect_packet(client)
    assert state(pid).inventory.slots[45] == ItemStack.new("glass_bottle")
    assert state(pid).player.effects == %{11 => [{9600, 0, false, true, true}]}
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == state(pid).player.effects
    assert saved.inventory.slots == state(pid).inventory.slots
    assert saved.outbox == nil and saved.transfer_sequence == 0
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_client, owner} = login(ctx, 20.0, food)
    assert state(owner).player.effects == saved.effects
    assert state(owner).inventory.slots == saved.inventory.slots
    assert state(owner).active_use == nil
  end

  test "cancelled potions and newly unsupported completion contents never grant or consume",
       ctx do
    food = %PlayerFood{}
    fire = potion("fire_resistance")
    unsupported = potion("night_vision")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => fire, 45 => unsupported}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 8)
    action(client, "release_use_item")
    wait(fn -> state(pid).active_use == nil end)
    assert state(pid).player.effects == %{} and state(pid).inventory.slots[36] == fire
    client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use == nil and state(pid).inventory.slots[45] == unsupported
    _client = use_hand(client, pid, :main, 3)
    ticks(pid, 31)

    :sys.replace_state(pid, fn s ->
      %{s | inventory: %{s.inventory | slots: %{36 => unsupported}}}
    end)

    tick(pid)
    assert state(pid).active_use == nil and state(pid).use_save == nil
    assert state(pid).player.effects == %{} and state(pid).inventory.slots[36] == unsupported
  end

  test "native custom delivery drops raw hidden chains but keeps sequential suppression and expiry",
       ctx do
    food = %PlayerFood{}

    contents = %{
      PotionContents.empty()
      | effects: [
          {11, [{2, 2, false, true, true}, {900, 255, false, true, true}]},
          {11, [{600, 0, true, false, true}]}
        ]
    }

    drink = %{ItemStack.new("potion") | components: %{"minecraft:potion_contents" => contents}}
    slots = Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(45, drink)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid, :off)
    ticks(pid, 32)
    {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 11, 2, 2, 14}, client} = effect_packet(client)
    {{^entity, 11, 2, 2, 4}, client} = effect_packet(client)

    assert state(pid).player.effects == %{
             11 => [{2, 2, false, false, true}, {600, 0, true, false, true}]
           }

    assert state(pid).inventory.slots == Map.put(slots, 45, ItemStack.new("glass_bottle"))
    ticks(pid, 2)
    {{^entity, 11, 0, 598, 5}, _client} = effect_packet(client)
    assert state(pid).player.effects == %{11 => [{598, 0, true, false, true}]}
    wait(fn -> state(pid).use_save == nil end)
  end

  test "creative drinks apply effects without consuming or producing bottles",
       ctx do
    food = %PlayerFood{}
    drink = potion("fire_resistance")
    seed(ctx, food, 20.0, mode: :creative, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid)
    ticks(pid, 32)
    assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
    assert state(pid).inventory.slots == %{36 => drink}
    wait(fn -> state(pid).use_save == nil end)
  end

  test "unsupported bottle overflow rejects potion effects and consumption together", ctx do
    food = %PlayerFood{}
    drink = potion("fire_resistance")

    stacked = %{
      drink
      | count: 2,
        components: Map.put(drink.components, "minecraft:max_stack_size", 64)
    }

    slots = Map.new(9..45, &{&1, ItemStack.new("stone", 64)}) |> Map.put(36, stacked)

    seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid)
    ticks(pid, 32)
    assert state(pid).player.effects == %{} and state(pid).inventory.slots == slots
    assert state(pid).active_use == nil and state(pid).use_save == nil
  end

  test "a stalled potion checkpoint cannot rewind the effect clock or consume twice", ctx do
    food = %PlayerFood{}
    drink = potion("fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    store = state(pid).player_store
    :sys.suspend(store)

    try do
      ticks(pid, 32)
      assert state(pid).use_save != nil
      assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
      _client = use_hand(client, pid, :main, 2)
      ticks(pid, 9)
      assert state(pid).active_use == nil
      assert state(pid).player.effects == %{11 => [{3591, 0, false, true, true}]}
      assert {:ok, observed} = Players.get(pid)
      assert observed.effects == %{11 => [{3600, 0, false, true, true}]}
      :sys.resume(store)
      wait(fn -> state(pid).use_save == nil end)
      assert state(pid).player.effects == %{11 => [{3591, 0, false, true, true}]}
      assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.effects == %{11 => [{3591, 0, false, true, true}]}
      assert saved.inventory.slots == %{36 => ItemStack.new("glass_bottle")}
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
  end

  test "effectless bottles and potion patches on food retain native listener and nutrition behavior",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    bread = %{ItemStack.new("bread") | components: potion("fire_resistance").components}

    seed(ctx, food, 20.0,
      inventory: %Inventory{slots: %{36 => ItemStack.new("potion"), 45 => bread}}
    )

    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 32)
    assert state(pid).player.effects == %{} and state(pid).player.food == food
    assert state(pid).inventory.slots[36] == ItemStack.new("glass_bottle")
    wait(fn -> state(pid).use_save == nil end)
    _client = use_hand(client, pid, :off, 2)
    ticks(pid, 32)
    assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
    assert state(pid).player.food == %PlayerFood{level: 10, saturation: 6.0}
    assert state(pid).player.effects == %{11 => [{3600, 0, false, true, true}]}
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.food == state(pid).player.food and saved.effects == state(pid).player.effects
    assert saved.inventory.slots == state(pid).inventory.slots
  end

  test "custom Resistance drinks checkpoint before mitigated damage; mixed unsupported potion stays intact",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    id = Valimc.Protocol.EffectTypes.id("resistance")
    contents = %{PotionContents.empty() | effects: [{id, [{200, 0, false, true, true}]}]}
    drink = %{ItemStack.new("potion") | components: %{"minecraft:potion_contents" => contents}}
    night_vision = Valimc.Protocol.EffectTypes.id("night_vision")

    mixed = %{
      contents
      | effects: contents.effects ++ [{night_vision, [{200, 0, false, true, true}]}]
    }

    turtle = %{drink | components: %{"minecraft:potion_contents" => mixed}}
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink, 45 => turtle}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 32)
    {{_, ^id, 0, 200, 14}, client} = effect_packet(client)
    assert state(pid).inventory.slots[36] == ItemStack.new("glass_bottle")
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 20.0 and saved.effects == %{id => [{200, 0, false, true, true}]}
    assert {:ok, :hurt} = Connection.fall_damage(pid, 10.0)
    assert state(pid).player.health.value == 12.0
    _client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use == nil and state(pid).inventory.slots[45] == turtle
    assert state(pid).player.effects == %{id => [{200, 0, false, true, true}]}
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 12.0 and saved.effects == %{id => [{200, 0, false, true, true}]}
    assert saved.inventory.slots == %{36 => ItemStack.new("glass_bottle"), 45 => turtle}
  end

  test "Speed drinking, sprint, promotion, expiry and milk publish owned movement attributes",
       ctx do
    food = %PlayerFood{}

    seed(ctx, food, 20.0,
      inventory: %Inventory{
        slots: %{36 => potion("swiftness"), 45 => ItemStack.new("milk_bucket")}
      }
    )

    {client, pid} = login(ctx, 20.0, food)
    assert client.attributes[{state(pid).player.entity_id, 26}] == {0.10000000149011612, []}
    client = use_hand(client, pid)
    ticks(pid, 32)
    {{_, 0, 0, 3600, 14}, client} = effect_packet(client)
    client = speed_attribute(client, pid)
    wait(fn -> state(pid).use_save == nil end)

    # Ordinary countdown does not dirty the active amplifier or resend attributes.
    tick(pid)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    client = quiet_attributes_until_stats(client)
    assert state(pid).movement_speed_view == {[0, nil], false}

    Client.send_packet(client, :play, "player_command", [
      Wire.varint(state(pid).player.entity_id),
      <<1, 0>>
    ])

    client = speed_attribute(client, pid)
    assert state(pid).movement_speed_view == {[0, nil], true}

    Client.send_packet(client, :play, "player_command", [
      Wire.varint(state(pid).player.entity_id),
      <<2, 0>>
    ])

    client = speed_attribute(client, pid)

    assert {:ok, true} = Connection.add_effect(pid, 0, [{1, 1, false, true, true}])
    client = speed_attribute(client, pid)
    tick(pid)
    client = speed_attribute(client, pid)
    assert state(pid).movement_speed_view == {[0, nil], false}
    client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use != nil
    ticks(pid, 32)
    client = speed_attribute(client, pid)
    assert state(pid).player.effects == %{}
    assert state(pid).inventory.slots[45] == ItemStack.new("bucket")
    assert {:ok, true} = Connection.add_effect(pid, 1, [{1, 3, false, true, true}])
    client = speed_attribute(client, pid)
    tick(pid)
    _client = speed_attribute(client, pid)
    assert state(pid).movement_speed_view == {[nil, nil], false}
  end

  test "stock Turtle Master consumes both effects atomically and reconnect initializes movement speed",
       ctx do
    food = %PlayerFood{}
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => potion("turtle_master")}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 32)
    {{_, 1, 3, 400, 14}, client} = effect_packet(client)
    {{_, 10, 2, 400, 14}, client} = effect_packet(client)
    _client = speed_attribute(client, pid)
    assert state(pid).inventory.slots[36] == ItemStack.new("glass_bottle")
    assert {:ok, :hurt} = Connection.fall_damage(pid, 10.0)
    assert state(pid).player.health.value == 16.0
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {client, restored} = login(ctx, 16.0, food)
    {:ok, derived} = Valimc.PlayerMovementSpeed.derive(state(restored).player.effects, false)
    {26, base, modifiers} = derived.attribute
    assert client.attributes[{state(restored).player.entity_id, 26}] == {base, modifiers}

    assert state(restored).player.effects == %{
             1 => [{400, 3, false, true, true}],
             10 => [{400, 2, false, true, true}]
           }

    assert state(restored).inventory.slots[36] == ItemStack.new("glass_bottle")
  end

  test "Water Breathing drinks use the same atomic effect/bottle lane", ctx do
    food = %PlayerFood{}
    drink = potion("water_breathing")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 32)
    {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 12, 0, 3600, 14}, _client} = effect_packet(client)
    assert state(pid).player.effects == %{12 => [{3600, 0, false, true, true}]}
    assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
    assert state(pid).player.food == food
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == state(pid).player.effects
    assert saved.inventory.slots == state(pid).inventory.slots
  end

  for {hand, slot} <- [{:main, 36}, {:off, 45}] do
    test "#{hand} milk clears hidden and unrelated statuses atomically even with full inventory",
         ctx do
      food = %PlayerFood{}
      drink = ItemStack.new("milk_bucket")
      slots = Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(unquote(slot), drink)
      seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
      {client, pid} = login(ctx, 20.0, food)

      ids =
        Enum.map(
          ~w(regeneration fire_resistance water_breathing poison),
          &Valimc.Protocol.EffectTypes.id/1
        )

      for id <- ids do
        {:ok, effect} = Valimc.StatusEffect.new(600, 0)
        assert {:ok, true} = Connection.add_effect(pid, id, effect)
      end

      {:ok, hidden} = Valimc.StatusEffect.new(200, 2)
      assert {:ok, true} = Connection.add_effect(pid, 11, hidden)
      client = use_hand(client, pid, unquote(hand))
      ticks(pid, 31)
      assert map_size(state(pid).player.effects) == 4 and state(pid).inventory.slots == slots
      tick(pid)
      {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")

      _client =
        Enum.reduce(Enum.sort(ids), client, fn expected, client ->
          {body, client} = Client.await(client, :play, "remove_mob_effect")
          {^entity, rest} = Wire.take_varint(body)
          assert {^expected, <<>>} = Wire.take_varint(rest)
          client
        end)

      assert state(pid).player.effects == %{} and state(pid).player.food == food
      assert state(pid).inventory.slots == Map.put(slots, unquote(slot), ItemStack.new("bucket"))
      health = state(pid).player.health.value
      ticks(pid, 50)
      assert state(pid).player.health.value == health
      wait(fn -> state(pid).use_save == nil end)
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)

      assert saved.effects == %{} and
               saved.inventory.slots[unquote(slot)] == ItemStack.new("bucket")

      assert saved.food == food and saved.health.value == health
    end
  end

  test "honey uses forty ticks, clears poison only, adds nutrition and inserts its bottle alongside remaining honey",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    drink = ItemStack.new("honey_bottle", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{45 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    poison = Valimc.Protocol.EffectTypes.id("poison")
    {:ok, venom} = Valimc.StatusEffect.new(100, 0)
    {:ok, fire} = Valimc.StatusEffect.new(-1, 0)
    assert {:ok, true} = Connection.add_effect(pid, poison, venom)
    assert {:ok, true} = Connection.add_effect(pid, 11, fire)
    client = use_hand(client, pid, :off)
    ticks(pid, 39)
    assert state(pid).player.effects[poison] != nil and state(pid).inventory.slots[45] == drink
    tick(pid)
    {body, _client} = Client.await(client, :play, "remove_mob_effect")
    {_entity, rest} = Wire.take_varint(body)
    assert {^poison, <<>>} = Wire.take_varint(rest)
    assert state(pid).player.effects == %{11 => [{-1, 0, false, true, true}]}
    assert state(pid).player.food == %PlayerFood{level: 11, saturation: 1.2000000476837158}

    assert state(pid).inventory.slots == %{
             36 => ItemStack.new("glass_bottle"),
             45 => ItemStack.new("honey_bottle")
           }

    health = state(pid).player.health.value
    ticks(pid, 30)
    assert state(pid).player.health.value == health
    wait(fn -> state(pid).use_save == nil end)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == %{11 => [{-1, 0, false, true, true}]}
    assert saved.inventory.slots[36] == ItemStack.new("glass_bottle")
    assert saved.inventory.slots[45] == ItemStack.new("honey_bottle")
  end

  test "canceled milk and unsupported honey overflow never clear effects or consume inventory/food",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}

    slots =
      Map.new(9..44, &{&1, ItemStack.new("stone", 64)})
      |> Map.put(36, ItemStack.new("honey_bottle", 2))
      |> Map.put(45, ItemStack.new("milk_bucket"))

    seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
    {client, pid} = login(ctx, 20.0, food)
    id = Valimc.Protocol.EffectTypes.id("poison")
    {:ok, effect} = Valimc.StatusEffect.new(-1, 0)
    assert {:ok, true} = Connection.add_effect(pid, id, effect)
    client = use_hand(client, pid, :off)
    ticks(pid, 10)
    _client = action(client, "release_use_item")
    wait(fn -> state(pid).active_use == nil end)
    client = use_hand(client, pid, :main, 2)
    ticks(pid, 40)
    assert state(pid).player.effects == %{id => [{-1, 0, false, true, true}]}
    assert state(pid).inventory.slots == slots and state(pid).player.food == food
    assert state(pid).active_use == nil and state(pid).use_save == nil
    Client.close(client)
  end

  test "creative milk clears status while retaining its bucket item and producing no remainder",
       ctx do
    food = %PlayerFood{}
    drink = ItemStack.new("milk_bucket")
    seed(ctx, food, 20.0, mode: :creative, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    {:ok, effect} = Valimc.StatusEffect.new(-1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 11, effect)
    _client = use_hand(client, pid)
    ticks(pid, 32)
    assert state(pid).player.effects == %{} and state(pid).inventory.slots == %{36 => drink}
    assert state(pid).player.food == food
  end

  for {name, duration, remainder} <- [
        {"milk_bucket", 32, "bucket"},
        {"honey_bottle", 40, "glass_bottle"}
      ] do
    test "#{name} remains consumable at full food with no matching effects", ctx do
      food = %PlayerFood{}
      seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => ItemStack.new(unquote(name))}})
      {client, pid} = login(ctx, 20.0, food)
      _client = use_hand(client, pid)
      ticks(pid, unquote(duration))
      assert state(pid).player.effects == %{} and state(pid).player.food.level == 20
      assert state(pid).inventory.slots == %{36 => ItemStack.new(unquote(remainder))}
      assert state(pid).active_use == nil
    end
  end

  test "a stalled milk checkpoint cannot restore removed effects or rewind a later owned grant",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}

    seed(ctx, food, 20.0,
      inventory: %Inventory{slots: %{36 => ItemStack.new("milk_bucket")}},
      effects: %{11 => [{-1, 0, false, true, true}]}
    )

    {client, pid} = login(ctx, 20.0, food)
    _client = use_hand(client, pid)
    store = state(pid).player_store
    :sys.suspend(store)

    try do
      ticks(pid, 32)
      assert state(pid).player.effects == %{} and state(pid).use_save != nil
      {:ok, later} = Valimc.StatusEffect.new(200, 0)
      assert {:ok, true} = Connection.add_effect(pid, 12, later)
      ticks(pid, 3)
      :sys.resume(store)
      wait(fn -> state(pid).use_save == nil end)
      assert state(pid).player.effects == %{12 => [{197, 0, false, true, true}]}
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.effects == %{12 => [{197, 0, false, true, true}]}
      assert saved.inventory.slots == %{36 => ItemStack.new("bucket")}
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
  end

  test "an introduced potion listener on milk stays refused instead of silently clearing effects",
       ctx do
    food = %PlayerFood{}
    milk = %{ItemStack.new("milk_bucket") | components: potion("fire_resistance").components}
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => milk}})
    {client, pid} = login(ctx, 20.0, food)
    {:ok, effect} = Valimc.StatusEffect.new(-1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 12, effect)
    _client = use_hand(client, pid)
    assert state(pid).active_use == nil and state(pid).inventory.slots[36] == milk
    assert state(pid).player.effects == %{12 => [{-1, 0, false, true, true}]}
  end

  for {name, delta} <- [{"regeneration", 1.0}, {"poison", -1.0}] do
    test "#{name} drinking checkpoints delivery before its first periodic health action", ctx do
      food = %PlayerFood{level: 5, saturation: 0.0}
      drink = potion(unquote(name))

      [{id, [{duration, _, _, _, _}]}] =
        PotionContents.effects(drink.components["minecraft:potion_contents"])

      seed(ctx, food, 8.0, inventory: %Inventory{slots: %{36 => drink}})
      {client, pid} = login(ctx, 8.0, food)
      client = use_hand(client, pid)
      ticks(pid, 32)
      assert state(pid).player.health.value == 8.0
      assert state(pid).player.effects[id] == [{duration, 0, false, true, true}]
      assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
      {{_, ^id, 0, ^duration, 14}, _client} = effect_packet(client)
      wait(fn -> state(pid).use_save == nil end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.effects == state(pid).player.effects and saved.health.value == 8.0
      assert saved.inventory.slots == state(pid).inventory.slots
      tick(pid)
      assert state(pid).player.health.value == 8.0 + unquote(delta)
      assert elem(hd(state(pid).player.effects[id]), 0) == duration - 1
      assert state(pid).player.food == food
    end
  end

  test "custom wither drinks retain atomic bottle/effect delivery and act on the next clock",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    id = Valimc.Protocol.EffectTypes.id("wither")
    contents = %{PotionContents.empty() | effects: [{id, [{80, 0, false, true, true}]}]}
    drink = %{ItemStack.new("potion") | components: %{"minecraft:potion_contents" => contents}}
    seed(ctx, food, 8.0, inventory: %Inventory{slots: %{45 => drink}})
    {client, pid} = login(ctx, 8.0, food)
    client = use_hand(client, pid, :off)
    ticks(pid, 32)
    {{_, ^id, 0, 80, 14}, _client} = effect_packet(client)
    assert state(pid).player.health.value == 8.0
    assert state(pid).inventory.slots == %{45 => ItemStack.new("glass_bottle")}
    wait(fn -> state(pid).use_save == nil end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == %{id => [{80, 0, false, true, true}]}
    assert saved.inventory.slots == state(pid).inventory.slots and saved.health.value == 8.0
    tick(pid)
    assert state(pid).player.health.value == 7.0 and state(pid).player.food == food
    assert state(pid).player.effects == %{id => [{79, 0, false, true, true}]}
  end

  test "death behind a stalled potion checkpoint retains one consumed bottle/drop and post-tick effects",
       ctx do
    food = %PlayerFood{level: 5, saturation: 0.0}
    id = Valimc.Protocol.EffectTypes.id("wither")
    contents = %{PotionContents.empty() | effects: [{id, [{80, 0, false, true, true}]}]}
    drink = %{ItemStack.new("potion") | components: %{"minecraft:potion_contents" => contents}}
    seed(ctx, food, 0.5, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 0.5, food)
    _client = use_hand(client, pid)
    store = state(pid).player_store
    :sys.suspend(store)

    try do
      ticks(pid, 32)
      assert state(pid).use_save != nil and state(pid).player.health.value == 0.5
      tick(pid)
      assert state(pid).life_stage == :sealing_death and state(pid).use_save != nil
      assert state(pid).player.effects == %{id => [{79, 0, false, true, true}]}
      assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
      :sys.resume(store)
      wait(fn -> state(pid).life_stage == :dead end)
      assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.health.value == 0.0 and saved.effects == %{id => [{79, 0, false, true, true}]}
      assert saved.inventory.slots == %{} and saved.transfer_sequence == 1 and saved.outbox == nil
      [view] = Valimc.World.item_snapshot(ctx.key) |> Map.values()

      {_entity, <<5, 8, _gravity, 8, 7, encoded::binary>>} =
        Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

      assert {:ok, bottle, <<255>>} = ItemStack.take(encoded)
      assert bottle == ItemStack.new("glass_bottle")
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
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
          Enum.with_index(["golden_apple", "suspicious_stew", "enchanted_golden_apple"], 3) do
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
