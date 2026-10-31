defmodule Valimc.PlayerUseConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Attributes, Effects, Freezing, Health}
  @moduletag :tcp

  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Food, PlayerList}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.{Data, ItemStack, PotionContents, UseItemOn, Wire}
  alias Valimc.Data.PotionTypes
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1, park: 1, state: 1, tick: 1, ticks: 2]

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  setup do: Valimc.TestPlayer.scope("Use", {137_000, 987}, survival: {1, false})

  defp login(ctx, expected_health, expected_food) do
    {_, client} = Client.configure_session(Client.begin_login(ctx.name), ctx.name)
    Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {body, client} = Client.await(client, :play, "set_health")
    assert_health(body, expected_health, expected_food)

    {pid, _} =
      wait(fn -> Enum.find(:ets.tab2list(PlayerList), fn {_, p} -> p.name == ctx.name end) end)

    park(pid)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not Valimc.TestConn.state(pid).teleport_pending and
        Valimc.Player.Input.loaded?(Valimc.TestConn.state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp seed(ctx, food, health, opts) do
    mode = Keyword.get(opts, :mode, :survival)
    inventory = Keyword.get(opts, :inventory, %Inventory{})

    player = %{
      living: %Valimc.Living{
        freezing: %Freezing{},
        health: %Health{value: health},
        air_supply: 300,
        effects: Keyword.get(opts, :effects, %{}),
        absorption: Keyword.get(opts, :absorption, 0.0)
      },
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(mode),
      abilities: Valimc.Player.Abilities.for_mode(mode),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: food
    }

    Valimc.TestPlayer.save(ctx, player, inventory)
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

  defp custom_potion(effects) do
    %{
      ItemStack.new("potion")
      | components: %{"minecraft:potion_contents" => %{PotionContents.empty() | effects: effects}}
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
      Attributes.movement_speed(
        living(pid).effects,
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
    food = %Food{}
    drink = potion("fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 20.0, food)
    client = block_then_drink(client, ctx)
    # The block use's correction runs as a job (VMC-077a), so the drink's
    # acknowledgement may come first; the client takes either order.
    {first, client} = Client.await(client, :play, "block_changed_ack")
    {second, _client} = Client.await(client, :play, "block_changed_ack")
    assert Enum.sort([first, second]) == [<<1>>, <<2>>]
    wait(fn -> state(pid).active_use != nil end)
    assert state(pid).active_use.remaining == 32
    ticks(pid, 32)
    assert living(pid).effects == %{11 => [{3600, 0, false, true, true}]}
    assert state(pid).inventory.slots == %{36 => ItemStack.new("glass_bottle")}
  end

  test "both-hand potion completion grants only after native timing and saves effects with the bottle",
       ctx do
    food = %Food{}
    fire = potion("fire_resistance")
    long = potion("long_fire_resistance")
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => fire, 45 => long}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    assert state(pid).active_use.remaining == 32
    ticks(pid, 31)
    assert state(pid).inventory.slots[36] == fire and living(pid).effects == %{}
    tick(pid)
    {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 11, 0, 3600, 14}, client} = effect_packet(client)
    assert state(pid).inventory.slots[36] == ItemStack.new("glass_bottle")
    assert living(pid).effects == %{11 => [{3600, 0, false, true, true}]}
    assert state(pid).player.food == food

    client = use_hand(client, pid, :off, 2)
    assert state(pid).player.use_flags == 3
    ticks(pid, 32)
    {<<^entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    {{^entity, 11, 0, 9600, 6}, client} = effect_packet(client)
    assert state(pid).inventory.slots[45] == ItemStack.new("glass_bottle")
    assert living(pid).effects == %{11 => [{9600, 0, false, true, true}]}
    Valimc.TestPlayer.checkpointed(pid)
    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == living(pid).effects
    assert saved.inventory.slots == state(pid).inventory.slots
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {_client, owner} = login(ctx, 20.0, food)
    assert living(owner).effects == saved.effects
    assert state(owner).inventory.slots == saved.inventory.slots
    assert state(owner).active_use == nil
  end

  test "cancelled potions and newly unsupported completion contents never grant or consume",
       ctx do
    food = %Food{}
    fire = potion("fire_resistance")
    # Instant Health 30 overflows to a negative heal, which is refused.
    unsupported = custom_potion([{5, [{1, 29, false, true, true}]}])
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => fire, 45 => unsupported}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 8)
    action(client, "release_use_item")
    wait(fn -> state(pid).active_use == nil end)
    assert living(pid).effects == %{} and state(pid).inventory.slots[36] == fire
    client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use == nil and state(pid).inventory.slots[45] == unsupported
    _client = use_hand(client, pid, :main, 3)
    ticks(pid, 31)

    Valimc.TestConn.replace(pid, fn s ->
      %{s | inventory: %{s.inventory | slots: %{36 => unsupported}}}
    end)

    tick(pid)
    assert state(pid).active_use == nil

    assert living(pid).effects == %{} and
             state(pid).inventory.slots[36] == unsupported
  end

  test "unsupported bottle overflow rejects potion effects and consumption together", ctx do
    food = %Food{}
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
    assert living(pid).effects == %{} and state(pid).inventory.slots == slots
    assert state(pid).active_use == nil
  end

  test "fatal harming dies with its bottle and one death drop, which a reconnect keeps",
       ctx do
    food = %Food{level: 10, saturation: 0.0}
    drink = custom_potion([{6, [{1, 0, false, true, true}]}, {5, [{1, 1, false, true, true}]}])
    seed(ctx, food, 5.0, inventory: %Inventory{slots: %{36 => drink}})
    {client, pid} = login(ctx, 5.0, food)
    client = use_hand(client, pid)
    ticks(pid, 32)
    assert living(pid).health.value == 0.0 and state(pid).life_stage == :dead
    assert state(pid).inventory.slots == %{}
    {body, _client} = Client.await(client, :play, "player_combat_kill")
    {_entity, message} = Wire.take_varint(body)

    assert {:ok,
            {:compound,
             %{
               "translate" => {:string, "death.attack.indirectMagic"},
               "with" => {:list, {:string, names}}
             }}, <<>>} = Valimc.Data.NBT.take(message)

    assert names == [ctx.name, ctx.name]
    Valimc.TestPlayer.checkpointed(pid)
    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.inventory.slots == %{} and saved.effects == %{}
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {_client, restored} = login(ctx, 0.0, food)

    assert living(restored).health.value == 0.0
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    [view] = Valimc.TestWorld.item_snapshot(ctx.key) |> Map.values()

    {_entity, <<5, 8, _gravity, 8, 7, stack_bytes::binary>>} =
      Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

    bottle = ItemStack.new("glass_bottle")
    assert {:ok, ^bottle, <<255>>} = ItemStack.take(stack_bytes)
  end

  test "Speed drinking, sprint, promotion, expiry and milk publish owned movement attributes",
       ctx do
    food = %Food{}

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

    assert {:ok, true} = Valimc.TestConn.add_effect(pid, 0, [{1, 1, false, true, true}])
    client = speed_attribute(client, pid)
    tick(pid)
    client = speed_attribute(client, pid)
    assert state(pid).movement_speed_view == {[0, nil], false}
    client = use_hand(client, pid, :off, 2)
    assert state(pid).active_use != nil
    ticks(pid, 32)
    client = speed_attribute(client, pid)
    assert living(pid).effects == %{}
    assert state(pid).inventory.slots[45] == ItemStack.new("bucket")
    assert {:ok, true} = Valimc.TestConn.add_effect(pid, 1, [{1, 3, false, true, true}])
    client = speed_attribute(client, pid)
    tick(pid)
    _client = speed_attribute(client, pid)
    assert state(pid).movement_speed_view == {[nil, nil], false}
  end

  for {hand, slot} <- [{:off, 45}] do
    test "#{hand} milk clears hidden and unrelated statuses atomically even with full inventory",
         ctx do
      food = %Food{}
      drink = ItemStack.new("milk_bucket")
      slots = Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(unquote(slot), drink)
      seed(ctx, food, 20.0, inventory: %Inventory{slots: slots})
      {client, pid} = login(ctx, 20.0, food)

      ids =
        Enum.map(
          ~w(regeneration fire_resistance water_breathing poison),
          &Valimc.Data.EffectTypes.id/1
        )

      for id <- ids do
        {:ok, effect} = Effects.new(600, 0)
        assert {:ok, true} = Valimc.TestConn.add_effect(pid, id, effect)
      end

      {:ok, hidden} = Effects.new(200, 2)
      assert {:ok, true} = Valimc.TestConn.add_effect(pid, 11, hidden)
      client = use_hand(client, pid, unquote(hand))
      ticks(pid, 31)

      assert map_size(living(pid).effects) == 4 and
               state(pid).inventory.slots == slots

      tick(pid)
      {<<entity::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")

      _client =
        Enum.reduce(Enum.sort(ids), client, fn expected, client ->
          {body, client} = Client.await(client, :play, "remove_mob_effect")
          {^entity, rest} = Wire.take_varint(body)
          assert {^expected, <<>>} = Wire.take_varint(rest)
          client
        end)

      assert living(pid).effects == %{} and state(pid).player.food == food
      assert state(pid).inventory.slots == Map.put(slots, unquote(slot), ItemStack.new("bucket"))
      health = living(pid).health.value
      ticks(pid, 50)
      assert living(pid).health.value == health
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
      assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)

      assert saved.effects == %{} and
               saved.inventory.slots[unquote(slot)] == ItemStack.new("bucket")

      assert saved.food == food and saved.health.value == health
    end
  end

  test "native duration finishes each hand once, orders completion before inventory, and reconnects atomically",
       ctx do
    food = %Food{level: 3, saturation: 0.0}
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
    assert state(pid).player.food == %Food{level: 8, saturation: 6.0}
    assert state(pid).active_use == nil and state(pid).player.use_flags == 0
    client = use_hand(client, pid, :off, 3)
    assert state(pid).player.use_flags == 3
    ticks(pid, 32)
    {<<^id::signed-32, 9>>, client} = Client.await(client, :play, "entity_event")
    assert state(pid).inventory.slots[45].count == 1 and state(pid).player.use_flags == 2
    assert state(pid).player.food == %Food{level: 13, saturation: 12.0}
    ticks(pid, 3)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.inventory.slots[36].count == 1 and saved.inventory.slots[45].count == 1
    assert saved.food == %Food{level: 13, saturation: 12.0}
    {_client, owner} = login(ctx, 20.0, saved.food)
    assert state(owner).active_use == nil and state(owner).player.use_flags == 0
  end

  test "release, different item, changed main slot and swap cancel while offhand selection does not",
       ctx do
    food = %Food{level: 5, saturation: 0.0}
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

    Valimc.TestConn.replace(pid, fn s ->
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

  test "disconnect and fatal damage retire unfinished use without consuming", ctx do
    food = %Food{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread", 2)
    seed(ctx, food, 20.0, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    ticks(pid, 10)
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerRegistry, ctx.uuid) == [] end)
    {client, pid} = login(ctx, 20.0, food)
    assert state(pid).inventory.slots[36] == bread and state(pid).active_use == nil
    _client = use_hand(client, pid)
    assert {:ok, :dead} = Valimc.TestConn.fall_damage(pid, 100.0)
    assert state(pid).active_use == nil and state(pid).player.use_flags == 0
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.food == food
    assert state(pid).inventory.slots == %{}
  end

  test "unloaded requests and spectator use cannot begin a meal", ctx do
    food = %Food{level: 5, saturation: 0.0}
    bread = ItemStack.new("bread")
    seed(ctx, food, 20.0, mode: :spectator, inventory: %Inventory{slots: %{36 => bread}})
    {client, pid} = login(ctx, 20.0, food)
    client = use_hand(client, pid)
    assert state(pid).active_use == nil

    Valimc.TestConn.replace(pid, fn s ->
      player = %{
        s.player
        | input: %Valimc.Player.Input{},
          game_mode: Valimc.Player.GameMode.new(:survival)
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
