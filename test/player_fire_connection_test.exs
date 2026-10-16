defmodule Valimc.PlayerFireConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, Inventory, PlayerHealth, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Fire#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-fire-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {170_000 + rem(nonce, 10_000), 983}
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

    %{name: name, uuid: uuid, key: key, pose: pose, path: PlayerStore.path(base, uuid)}
  end

  defp state(pid), do: :sys.get_state(pid)

  defp wait(fun, left \\ 500) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end

  defp material(ctx, name) do
    id = %{"air" => 0, "water" => 89, "lava" => 105, "fire" => 4931, "soul_fire" => 5443}[name]
    for y <- [64, 65], do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, id)
  end

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{frozen_ticks: 140},
        health: %PlayerHealth{value: Keyword.get(opts, :health, 20.0)},
        last_death: nil,
        air_supply: 300,
        fire_ticks: Keyword.get(opts, :fire, 0),
        effects: Keyword.get(opts, :effects, %{}),
        food: %Valimc.PlayerFood{level: 5, saturation: 0.0}
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(
        ctx.uuid,
        PlayerSnapshot.capture(player, Keyword.get(opts, :inventory, %Inventory{}))
      )

    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
    material(ctx, Keyword.get(opts, :material, "lava"))
  end

  defp park(pid) do
    :sys.replace_state(pid, fn s ->
      %{
        s
        | simulation_clock: %{
            s.simulation_clock
            | token: {s.simulation_clock.epoch, make_ref()},
              deadline: System.monotonic_time(:millisecond) + 60_000
          }
      }
    end)
  end

  defp login(ctx, expected_effect \\ nil) do
    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    park(pid)

    client =
      if expected_effect do
        {fields, client} = effect_packet(client)
        {entity, id, ticks, level, flags} = fields
        assert entity == state(pid).player.entity_id
        assert {id, ticks, level, flags} == expected_effect
        client
      else
        client
      end

    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp effect_packet(client) do
    {body, client} = Client.await(client, :play, "update_mob_effect")
    {entity, rest} = Wire.take_varint(body)
    {id, rest} = Wire.take_varint(rest)
    {level, rest} = Wire.take_varint(rest)
    {ticks, <<flags>>} = Wire.take_varint(rest)
    ticks = if ticks >= 2_147_483_648, do: ticks - 4_294_967_296, else: ticks
    {{entity, id, ticks, level, flags}, client}
  end

  defp tick(pid, geometry \\ true) do
    before =
      :sys.replace_state(pid, fn s ->
        %{
          s
          | simulation_clock: %{
              s.simulation_clock
              | deadline: System.monotonic_time(:millisecond)
            }
        }
      end)

    send(pid, {:player_tick, before.simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)

    if geometry,
      do:
        wait(fn ->
          state(pid).pose_job == nil and state(pid).motion_job == nil and
            not state(pid).simulation_due
        end)

    before.simulation_clock.token
  end

  test "owned effect grants retain suppressed refresh, admission and packet lifecycle", ctx do
    seed(ctx, fire: -20, material: "air")
    {client, pid} = login(ctx)
    {:ok, weak} = Valimc.StatusEffect.new(601, 0)
    {:ok, strong} = Valimc.StatusEffect.new(2, 2)
    {:ok, infinite} = Valimc.StatusEffect.new(-1, 0)
    entity = state(pid).player.entity_id
    assert {:ok, true} = Connection.add_effect(pid, 11, weak)
    assert {{^entity, 11, 601, 0, 14}, client} = effect_packet(client)
    assert {:ok, true} = Connection.add_effect(pid, 11, strong)
    assert {{^entity, 11, 2, 2, 6}, client} = effect_packet(client)
    assert {:ok, false} = Connection.add_effect(pid, 11, infinite)

    assert state(pid).player.effects[11] == [
             {2, 2, false, true, true},
             {-1, 0, false, true, true}
           ]

    tick(pid)
    tick(pid)
    assert {{^entity, 11, -1, 0, 6}, client} = effect_packet(client)
    assert {:ok, true} = Connection.remove_effect(pid, 11)
    {body, _client} = Client.await(client, :play, "remove_mob_effect")
    assert {^entity, <<11>>} = Wire.take_varint(body)
    assert {:ok, false} = Connection.remove_effect(pid, 11)
    assert state(pid).player.effects == %{}
    assert {:error, :invalid_player_effects} = Connection.add_effect(pid, 11, [])
    assert {:error, :invalid_or_expired_effect} = Connection.add_effect(pid, 15, weak)

    assert {:error, :invalid_or_expired_effect} =
             GenServer.call(pid, {:effect, 11, weak, System.monotonic_time(:millisecond) - 1})

    assert state(pid).player.effects == %{}
  end

  test "Fire Resistance blocks fire contact and armor wear before cooldown but cactus still hurts",
       ctx do
    helmet = ItemStack.new("iron_helmet")
    effects = %{11 => [{-1, 0, false, true, true}]}
    seed(ctx, effects: effects, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx, {11, -1, 0, 6})
    tick(pid)
    assert state(pid).player.fire_ticks == 300
    assert state(pid).player.health.value == 20.0 and state(pid).player.health.cooldown == 0
    assert state(pid).inventory.slots[5] == helmet

    for id <- [4931, 5443, 24235, 24267] do
      for y <- [64, 65], do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, id)
      tick(pid)
      assert state(pid).player.health.value == 20.0 and state(pid).player.health.cooldown == 0
      assert state(pid).inventory.slots[5] == helmet
    end

    material(ctx, "air")
    :ok = World.set_block({floor(ctx.pose.x), 63, floor(ctx.pose.z)}, 16826)

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | motion: %{s.player.motion | physical_ground: true}}}
    end)

    tick(pid)
    assert state(pid).player.health.value == 20.0 and state(pid).player.health.cooldown == 0
    assert state(pid).inventory.slots[5] == helmet
    :ok = World.set_block({floor(ctx.pose.x), 64, floor(ctx.pose.z)}, 8599)
    tick(pid)
    assert state(pid).player.health.value < 20.0
    assert state(pid).inventory.slots[5].components["minecraft:damage"] == 1
    {body, _client} = Client.await(client, :play, "damage_event")
    {_entity, rest} = Wire.take_varint(body)
    {type, _} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:cactus")
  end

  test "tick-start resistance cancels pending burning before expiry; fresh contacts use the expired map",
       ctx do
    effects = %{11 => [{-1, 0, false, true, true}]}
    seed(ctx, fire: 20, material: "air", effects: effects)
    {client, pid} = login(ctx, {11, -1, 0, 6})
    assert {:ok, true} = Connection.remove_effect(pid, 11)
    assert {:ok, one_tick} = Valimc.StatusEffect.new(1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 11, one_tick)
    {_fields, client} = effect_packet(client)

    :sys.replace_state(pid, fn s ->
      %{s | fire_damage_due: true, player: %{s.player | fire_ticks: 20}}
    end)

    tick(pid)
    assert state(pid).player.effects == %{} and not state(pid).fire_damage_due
    assert state(pid).player.health.value == 20.0 and state(pid).player.health.cooldown == 0
    {body, client} = Client.await(client, :play, "remove_mob_effect")
    {_entity, <<11>>} = Wire.take_varint(body)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | fire_ticks: 20}} end)
    tick(pid)
    assert state(pid).player.health.value == 19.0

    assert {:ok, true} = Connection.add_effect(pid, 11, one_tick)
    {_fields, _client} = effect_packet(client)

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | health: %PlayerHealth{}, fire_ticks: -20}}
    end)

    material(ctx, "fire")
    tick(pid)
    assert state(pid).player.effects == %{} and state(pid).player.health.value < 20.0
  end

  test "suppressed durations survive real reconnect and ordinary death-respawn clears the owned effect",
       ctx do
    effects = %{11 => [{-1, 0, false, true, true}]}

    seed(ctx,
      effects: effects,
      material: "air",
      health: 0.5,
      inventory: %Inventory{slots: %{5 => ItemStack.new("iron_helmet")}}
    )

    {client, pid} = login(ctx, {11, -1, 0, 6})
    {:ok, strong} = Valimc.StatusEffect.new(3, 1)
    assert {:ok, true} = Connection.add_effect(pid, 11, strong)
    {_fields, client} = effect_packet(client)
    tick(pid)
    Client.close(client)
    wait(fn -> not Process.alive?(pid) end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.effects == %{11 => [{2, 1, false, true, true}, {-1, 0, false, true, true}]}
    assert saved.transfer_sequence == 0 and saved.outbox == nil
    {client, pid} = login(ctx, {11, 2, 1, 6})
    assert state(pid).player.effects == saved.effects
    tick(pid)
    tick(pid)
    {_fields, client} = effect_packet(client)
    assert state(pid).player.effects == effects
    :ok = World.set_block({floor(ctx.pose.x), 64, floor(ctx.pose.z)}, 8599)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    {:ok, dead} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert dead.effects == effects and dead.transfer_sequence == 1 and dead.outbox == nil
    assert {:error, :not_playing} = Connection.add_effect(pid, 11, strong)
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, _client} = Client.await(client, :play, "respawn")
    assert state(pid).player.effects == %{} and state(pid).player.health.value == 20.0
    {:ok, alive} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert alive.effects == %{} and alive.transfer_sequence == 1 and alive.outbox == nil
  end

  test "contact hazards require an admitted tick and retain distinct source packets, wear and no ignition",
       ctx do
    seed(ctx, fire: -20, material: "air")
    {client, pid} = login(ctx)
    block = {floor(ctx.pose.x), 64, floor(ctx.pose.z)}

    sources = [{24234, :campfire}, {8599, :cactus}, {24299, :sweet_berry_bush}]

    Enum.reduce(sources, client, fn {id, source}, client ->
      :ok = World.set_block(block, id)

      :sys.replace_state(pid, fn s ->
        %{
          s
          | inventory: %Inventory{slots: %{5 => ItemStack.new("iron_helmet")}},
            player: %{s.player | health: %PlayerHealth{}, fire_ticks: -20}
        }
      end)

      target = state(pid).player.x + 0.01

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<target::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
      )

      Client.send_packet(client, :play, "client_tick_end", <<>>)

      wait(fn ->
        state(pid).player.x == target and state(pid).motion_job == nil and
          state(pid).pose_job == nil
      end)

      assert state(pid).player.health.value == 20.0
      assert state(pid).inventory.slots[5].components == %{}
      tick(pid)
      assert state(pid).player.health.value < 20.0
      assert state(pid).player.fire_ticks == -20
      assert state(pid).inventory.slots[5].components["minecraft:damage"] == 1
      {body, client} = Client.await(client, :play, "damage_event")
      {_entity, rest} = Wire.take_varint(body)
      {type, _rest} = Wire.take_varint(rest)
      assert type == Data.registry_id("minecraft:damage_type", "minecraft:#{source}")
      client
    end)
  end

  test "grounded magma respects careful input and fresh feet immunity before cooldown or armor wear",
       ctx do
    seed(ctx, fire: -20, material: "air")
    :ok = World.set_block({floor(ctx.pose.x), 63, floor(ctx.pose.z)}, 16826)
    {client, pid} = login(ctx)
    helmet = ItemStack.new("iron_helmet")

    frost = %{
      ItemStack.new("iron_boots")
      | components: %{"minecraft:enchantments" => %{"minecraft:frost_walker" => 0}}
    }

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %Inventory{slots: %{5 => helmet, 8 => frost}},
          player: %{s.player | motion: %{s.player.motion | physical_ground: true}}
      }
    end)

    tick(pid)
    assert state(pid).player.health.value == 20.0 and state(pid).player.health.cooldown == 0
    assert state(pid).inventory.slots[5] == helmet
    assert state(pid).inventory.slots[8] == frost

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %Inventory{slots: %{5 => helmet}},
          player: %{s.player | input: %{s.player.input | shared_flags: 2}}
      }
    end)

    tick(pid)
    assert state(pid).player.health.value == 20.0

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | input: %{s.player.input | shared_flags: 0}}}
    end)

    tick(pid)
    assert state(pid).player.health.value < 20.0
    assert state(pid).inventory.slots[5].components["minecraft:damage"] == 1
    {body, _client} = Client.await(client, :play, "damage_event")
    {_entity, rest} = Wire.take_varint(body)
    {type, _} = Wire.take_varint(rest)
    assert type == Data.registry_id("minecraft:damage_type", "minecraft:hot_floor")
  end

  test "fatal immediate cactus stops an earlier retained fire ignition and persists one worn death drop",
       ctx do
    helmet = ItemStack.new("iron_helmet")

    seed(ctx,
      fire: -1,
      health: 0.5,
      material: "air",
      inventory: %Inventory{slots: %{5 => helmet}}
    )

    {x, z} = {floor(ctx.pose.x), floor(ctx.pose.z)}
    :ok = World.set_block({x + 1, 64, z}, 4931)
    :ok = World.set_block({x + 2, 64, z}, 8599)
    {client, pid} = login(ctx)
    target = ctx.pose.x + 1.25

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<target::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
    )

    wait(fn ->
      state(pid).player.x == target and state(pid).motion_job == nil and
        state(pid).pose_job == nil
    end)

    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.fire_ticks == -1
    {body, _client} = Client.await(client, :play, "player_combat_kill")
    {_entity, message} = Wire.take_varint(body)

    assert {:ok, {:compound, %{"translate" => {:string, "death.attack.cactus"}}}, <<>>} =
             Valimc.Protocol.NBT.take(message)

    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.fire_ticks == -1
    assert saved.inventory.slots == %{} and saved.outbox == nil and saved.transfer_sequence == 1
    [view] = World.item_snapshot(ctx.key) |> Map.values()

    {_entity, <<5, 8, _gravity, 8, 7, stack_bytes::binary>>} =
      Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

    {:ok, dropped, <<255>>} = ItemStack.take(stack_bytes)
    assert dropped.item_id == helmet.item_id and dropped.components["minecraft:damage"] == 1
  end

  test "fresh lava ignites, clears freezing, wears once per accepted cooldown and uses native damage packets",
       ctx do
    helmet = ItemStack.new("iron_helmet")
    seed(ctx, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx)
    tick(pid)
    s = state(pid)
    assert s.player.fire_ticks == 300 and s.player.environment.frozen_ticks == 0
    assert s.inventory.slots[5].components["minecraft:damage"] == 1
    assert s.player.health.value == 16.06399917602539
    assert s.player.food.exhaustion == 0.10000000149011612
    assert s.player.health.cooldown == 20 and not s.fire_damage_due
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)

    assert entity == s.player.entity_id and
             source == Data.registry_id("minecraft:damage_type", "minecraft:lava")

    for _ <- 1..9, do: tick(pid)
    assert state(pid).inventory.slots[5].components["minecraft:damage"] == 1
    tick(pid)
    assert state(pid).inventory.slots[5].components["minecraft:damage"] == 2
    assert state(pid).player.health.value < s.player.health.value
    Client.close(client)
  end

  test "ongoing burning uses the admitted old counter phase and water extinguishes without future damage",
       ctx do
    seed(ctx, fire: 20, material: "air")
    {_client, pid} = login(ctx)
    old = tick(pid)
    assert state(pid).player.fire_ticks == 19
    assert state(pid).player.health.value == 19.0 and not state(pid).fire_damage_due
    send(pid, {:player_tick, old})
    assert state(pid).player.fire_ticks == 19
    for _ <- 1..5, do: tick(pid)
    assert state(pid).player.fire_ticks == 14 and state(pid).player.health.value == 19.0
    material(ctx, "water")
    tick(pid)
    assert state(pid).player.fire_ticks == -20 and not state(pid).fire_damage_due
    for _ <- 1..20, do: tick(pid)
    assert state(pid).player.health.value == 19.0
  end

  test "broken armor loses attributes before reduction while Netherite resists fire wear", ctx do
    helmet = %{ItemStack.new("iron_helmet") | components: %{"minecraft:damage" => 164}}
    boots = ItemStack.new("netherite_boots")
    seed(ctx, inventory: %Inventory{slots: %{5 => helmet, 8 => boots}})
    {client, pid} = login(ctx)
    tick(pid)
    s = state(pid)
    assert s.inventory.slots == %{8 => boots}
    # Only the surviving Netherite boots contribute armor3/toughness3.
    assert s.armor_view.armor == 3 and s.armor_view.toughness == 3.0
    assert s.player.health.value > 16.0 and s.player.health.value < 17.0
    {body, _client} = Client.await(client, :play, "entity_event")
    assert body == <<s.player.entity_id::signed-32, 49>>
  end

  test "equipped fire protection shortens ignition; creative and spectator never lose health or armor",
       ctx do
    fire = %{
      ItemStack.new("iron_helmet")
      | components: %{"minecraft:enchantments" => %{"minecraft:fire_protection" => 4}}
    }

    seed(ctx, inventory: %Inventory{slots: %{5 => fire}})
    {client, pid} = login(ctx)
    tick(pid)
    assert state(pid).player.fire_ticks == 120
    assert state(pid).player.health.value > 17.0

    for mode <- [:creative, :spectator] do
      :sys.replace_state(pid, fn s ->
        %{
          s
          | player: %{
              s.player
              | game_mode: Valimc.GameMode.new(mode),
                abilities: Valimc.PlayerAbilities.for_mode(mode),
                health: %PlayerHealth{},
                fire_ticks: 300
            }
        }
      end)

      before = state(pid).inventory
      tick(pid)
      assert state(pid).player.health.value == 20.0 and state(pid).inventory == before
      assert state(pid).player.fire_ticks <= 1
    end

    Client.close(client)
  end

  test "inventory recovery defers wear and rechecks current contact rather than replaying stale lava",
       ctx do
    helmet = ItemStack.new("iron_helmet")
    seed(ctx, inventory: %Inventory{slots: %{5 => helmet}})
    {_client, pid} = login(ctx)
    :sys.replace_state(pid, &%{&1 | use_save: make_ref()})
    tick(pid)
    assert state(pid).player.health.value == 20.0 and state(pid).inventory.slots[5] == helmet
    material(ctx, "air")
    :sys.replace_state(pid, &%{&1 | use_save: nil, player: %{&1.player | fire_ticks: 19}})
    tick(pid)
    assert state(pid).player.health.value == 20.0 and state(pid).inventory.slots[5] == helmet
    material(ctx, "lava")
    tick(pid)
    assert state(pid).player.health.value < 20.0
    assert state(pid).inventory.slots[5].components["minecraft:damage"] == 1
  end

  test "fatal lava seals one death and respawn clears burning and pending damage", ctx do
    seed(ctx, health: 3.0, inventory: %Inventory{slots: %{36 => ItemStack.new("diamond", 2)}})
    {client, pid} = login(ctx)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.fire_ticks == 0
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.fire_ticks == 0 and saved.outbox == nil
    assert saved.transfer_sequence == 1 and saved.inventory.slots == %{}
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, _client} = Client.await(client, :play, "respawn")
    assert state(pid).player.fire_ticks == 0 and not state(pid).fire_damage_due
    assert state(pid).player.health.value == 20.0
  end

  test "a stalled body query coalesces burning requests while the owned counter keeps advancing",
       ctx do
    seed(ctx, fire: 100, material: "air")
    {_client, pid} = login(ctx)
    wait(fn -> state(pid).pose_job == nil and state(pid).motion_job == nil end)
    {:ok, {owner, _epoch}} = World.existing_owner(ctx.key)
    :sys.suspend(owner)

    try do
      for _ <- 1..21, do: tick(pid, false)
      pending = state(pid)
      assert pending.player.fire_ticks == 79 and pending.fire_damage_due
      assert pending.player.health.value == 20.0
      assert pending.pose_job != nil or pending.motion_job != nil
    after
      :sys.resume(owner)
    end

    wait(fn ->
      state(pid).pose_job == nil and state(pid).motion_job == nil and
        not state(pid).simulation_due
    end)

    assert state(pid).player.health.value == 19.0 and not state(pid).fire_damage_due
  end

  test "unloaded lava cannot ignite or damage, and expired burning clears the visible flag",
       ctx do
    seed(ctx, fire: 1, material: "air")
    {_client, pid} = login(ctx)
    tick(pid)
    assert state(pid).player.fire_ticks == -20 and state(pid).player.health.value == 20.0
    assert Bitwise.band(Valimc.Protocol.Packets.shared_flags(state(pid).player), 1) == 0
    material(ctx, "lava")

    :sys.replace_state(pid, fn s ->
      %{s | player: %{s.player | input: %Valimc.PlayerInput{load_ticks: 60}}}
    end)

    tick(pid, false)
    assert state(pid).player.fire_ticks == -20 and state(pid).player.health.value == 20.0
  end

  test "stationary fire advances its negative cooldown on admitted contacts until it ignites",
       ctx do
    seed(ctx, fire: -20, material: "fire")
    {_client, pid} = login(ctx)
    assert state(pid).player.fire_ticks == -20
    tick(pid)
    assert state(pid).player.fire_ticks == -19 and state(pid).fire_contacts_active
    assert state(pid).player.health.value == 19.0
    assert state(pid).player.environment.frozen_ticks == 0

    for _ <- 1..18, do: tick(pid)
    assert state(pid).player.fire_ticks == -1 and state(pid).fire_contacts_active
    tick(pid)
    assert state(pid).player.fire_ticks == 160
    assert state(pid).player.health.value == 18.0
    tick(pid)
    assert state(pid).player.fire_ticks in [160, 161]
    material(ctx, "air")
    tick(pid)
    assert state(pid).player.fire_ticks > 0 and not state(pid).fire_contacts_active
  end

  test "movement packets cannot advance ignition or damage without an admitted owner tick", ctx do
    seed(ctx, fire: -20, material: "fire")
    {client, pid} = login(ctx)

    for i <- 1..8 do
      target = ctx.pose.x + i * 0.01

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<target::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
      )

      Client.send_packet(client, :play, "client_tick_end", <<>>)

      wait(fn ->
        state(pid).player.x == target and state(pid).motion_job == nil and
          state(pid).pose_job == nil
      end)

      assert state(pid).player.fire_ticks == -20 and state(pid).player.health.value == 20.0
    end

    tick(pid)
    assert state(pid).player.fire_ticks == -19 and state(pid).player.health.value == 19.0
  end

  test "a real accepted crossing retains fire contact at a dry endpoint", ctx do
    seed(ctx, fire: -1, material: "air")
    {x, z} = {floor(ctx.pose.x), floor(ctx.pose.z)}
    :ok = World.set_block({x + 1, 64, z}, 4931)
    {client, pid} = login(ctx)
    target = ctx.pose.x + 2.0

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<target::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
    )

    wait(fn ->
      state(pid).player.x == target and state(pid).motion_job == nil and
        state(pid).pose_job == nil
    end)

    assert state(pid).player.fire_ticks == -1 and state(pid).player.health.value == 20.0
    tick(pid)
    assert state(pid).player.fire_ticks == 160 and state(pid).player.health.value == 19.0
    tick(pid)
    assert state(pid).player.fire_ticks == 159 and not state(pid).fire_contacts_active
  end

  test "fatal first fire callback stops later contacts and persists exactly one worn death stack",
       ctx do
    helmet = ItemStack.new("iron_helmet")

    seed(ctx,
      fire: -1,
      health: 0.5,
      material: "fire",
      inventory: %Inventory{slots: %{5 => helmet}}
    )

    :ok = World.set_block({floor(ctx.pose.x), 65, floor(ctx.pose.z)}, 5443)
    {client, pid} = login(ctx)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    assert not state(pid).fire_contacts_active and not state(pid).fire_damage_due
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.fire_ticks == 0 and saved.outbox == nil
    assert saved.transfer_sequence == 1 and saved.inventory.slots == %{}
    [view] = World.item_snapshot(ctx.key) |> Map.values()

    {_entity, <<5, 8, _gravity, 8, 7, stack_bytes::binary>>} =
      Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

    {:ok, dropped, <<255>>} = ItemStack.take(stack_bytes)
    assert dropped.item_id == helmet.item_id
    assert dropped.components["minecraft:damage"] == 1
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, _client} = Client.await(client, :play, "respawn")
    assert state(pid).player.health.value == 20.0 and state(pid).player.fire_ticks == 0
    assert not state(pid).fire_contacts_active
  end

  defp rain do
    alias Valimc.World.Clock
    :ok = Clock.configure({:advance_weather, false})
    :ok = Clock.configure({:weather, :rain, 600})
    wait(fn -> Clock.weather().wet end)

    on_exit(fn ->
      :ok = Clock.configure({:weather, :clear, 0})
      wait(fn -> not Clock.weather().wet end)
      :ok = Clock.configure({:advance_weather, true})
    end)
  end

  test "rain extinguishes after natural ignition when a transparent roof is removed", ctx do
    rain()
    seed(ctx, fire: -1, material: "fire")
    roof = {floor(ctx.pose.x), 66, floor(ctx.pose.z)}
    :ok = World.set_block(roof, Data.block("glass"))
    {_client, pid} = login(ctx)
    tick(pid)
    assert state(pid).player.fire_ticks == 160
    assert state(pid).player.health.value == 19.0
    :ok = World.remove_block(roof)
    wait(fn -> state(pid).pose_job == nil end)
    assert state(pid).player.fire_ticks == 160
    tick(pid)
    assert state(pid).player.fire_ticks == -20
    assert state(pid).fire_contacts_active
  end

  test "outdoor rain clears ongoing fire but snow at high altitude does not", ctx do
    rain()
    seed(ctx, fire: 181, material: "air")
    {client, pid} = login(ctx)
    assert state(pid).player.fire_ticks == 181
    tick(pid)
    assert state(pid).player.fire_ticks == -20

    high = %{ctx.pose | y: 1024.0}
    assert :ok = Connection.teleport(pid, high)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_, _client} = Client.await(client, :play, "system_chat")
    # Trusted owner setup supplies only a burning counter after an authorized relocation.
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | fire_ticks: 181}} end)
    wait(fn -> not state(pid).teleport_pending and state(pid).pose_job == nil end)
    tick(pid)
    assert state(pid).player.fire_ticks == 180
  end

  test "fatal ongoing damage still precedes outdoor rain extinction", ctx do
    rain()
    seed(ctx, fire: 180, health: 0.5, material: "air")
    {_client, pid} = login(ctx)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).player.health.value == 0.0
    assert state(pid).player.fire_ticks == 0
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.fire_ticks == 0
  end
end
