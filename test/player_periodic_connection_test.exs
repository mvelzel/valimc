defmodule Valimc.PlayerPeriodicConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, Inventory, PlayerHealth, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Effect#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-periodic-#{nonce}")
    old = Valimc.config(:world_path)
    {difficulty, regeneration} = World.Clock.survival()
    :ok = World.Clock.configure({:difficulty, 1, true})
    :ok = World.Clock.configure({:natural_regeneration, false})
    Application.put_env(:valimc, :world_path, base)
    key = {200_000 + rem(nonce, 10_000), 981}
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

      :ok = World.Clock.configure({:difficulty, difficulty, true})
      :ok = World.Clock.configure({:natural_regeneration, regeneration})
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

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
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
    for y <- [64, 65], do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 0)
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

    if geometry and state(pid).life_stage == :alive,
      do:
        wait(fn ->
          state(pid).pose_job == nil and state(pid).motion_job == nil
        end)

    before.simulation_clock.token
  end

  defp effect(pid, name, duration, amplifier \\ 0) do
    id = Valimc.Protocol.EffectTypes.id(name)
    {:ok, incoming} = Valimc.StatusEffect.new(duration, amplifier)
    assert {:ok, true} = Connection.add_effect(pid, id, incoming)
    id
  end

  test "regeneration reads countdown before decrement, ignores stale ticks and restores health/effects together",
       ctx do
    seed(ctx, health: 10.0)
    {client, pid} = login(ctx)
    id = effect(pid, "regeneration", 200)
    stale = tick(pid)
    assert state(pid).player.health.value == 11.0
    assert state(pid).player.food.exhaustion == 0.0
    send(pid, {:player_tick, stale})
    assert state(pid).player.health.value == 11.0
    for _ <- 1..49, do: tick(pid)
    assert state(pid).player.health.value == 11.0
    tick(pid)
    assert state(pid).player.health.value == 12.0
    assert state(pid).player.effects[id] == [{149, 0, false, true, true}]
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 12.0 and saved.effects[id] == [{149, 0, false, true, true}]
    {_client, owner} = login(ctx, {id, 149, 0, 6})
    assert state(owner).player.health.value == 12.0
    assert elem(hd(state(owner).player.effects[id]), 0) in 148..149
  end

  test "poison uses magic, ordinary cooldown and native health threshold without armor wear or exhaustion",
       ctx do
    helmet = ItemStack.new("diamond_helmet")
    seed(ctx, health: 3.0, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx)
    id = effect(pid, "poison", 75)
    tick(pid)
    assert state(pid).player.health.value == 2.0
    {body, _client} = Client.await(client, :play, "damage_event")
    {_entity, rest} = Wire.take_varint(body)
    {source, _} = Wire.take_varint(rest)
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:magic")
    for _ <- 1..74, do: tick(pid)
    assert state(pid).player.health.value == 1.0 and state(pid).player.effects == %{}
    assert state(pid).player.food.exhaustion == 0.0
    assert state(pid).inventory.slots == %{5 => helmet}
    assert state(pid).life_stage == :alive
    assert Map.get(state(pid).player.effects, id) == nil
  end

  test "wither can kill and seals post-tick effects with one unchanged durable death drop", ctx do
    helmet = ItemStack.new("iron_helmet")
    seed(ctx, health: 0.5, inventory: %Inventory{slots: %{5 => helmet}})
    {client, pid} = login(ctx)
    id = effect(pid, "wither", 40)
    tick(pid, false)
    wait(fn -> state(pid).life_stage == :dead end)
    {body, _client} = Client.await(client, :play, "player_combat_kill")
    {_entity, message} = Wire.take_varint(body)

    assert {:ok, {:compound, %{"translate" => {:string, "death.attack.wither"}}}, <<>>} =
             Valimc.Protocol.NBT.take(message)

    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.effects[id] == [{39, 0, false, true, true}]
    assert saved.inventory.slots == %{} and saved.outbox == nil and saved.transfer_sequence == 1
    [view] = World.item_snapshot(ctx.key) |> Map.values()

    {_entity, <<5, 8, _gravity, 8, 7, stack_bytes::binary>>} =
      Wire.take_varint(IO.iodata_to_binary(elem(view.metadata, 1)))

    assert {:ok, ^helmet, <<255>>} = ItemStack.take(stack_bytes)
  end

  test "every-tick wither still respects the ordinary ten-tick hurt window", ctx do
    seed(ctx, health: 10.0)
    {_client, pid} = login(ctx)
    effect(pid, "wither", 11, 31)
    tick(pid)
    assert state(pid).player.health.value == 9.0
    for _ <- 1..9, do: tick(pid)
    assert state(pid).player.health.value == 9.0
    tick(pid)
    assert state(pid).player.health.value == 8.0 and state(pid).player.effects == %{}
  end

  test "strong periodic heads act before promotion; infinite weak head uses owner age", ctx do
    seed(ctx, health: 10.0)
    {_client, pid} = login(ctx)
    id = effect(pid, "regeneration", -1)
    effect(pid, "regeneration", 1, 31)
    :sys.replace_state(pid, fn s -> %{s | simulation_clock: %{s.simulation_clock | tick: 0}} end)
    tick(pid)
    assert state(pid).player.health.value == 11.0
    assert state(pid).player.effects[id] == [{-1, 0, false, true, true}]
    for _ <- 1..48, do: tick(pid)
    assert state(pid).player.health.value == 11.0
    tick(pid)
    assert state(pid).player.health.value == 12.0

    :sys.replace_state(pid, fn s ->
      %{s | simulation_clock: %{s.simulation_clock | tick: 4_294_967_345}}
    end)

    tick(pid)
    assert state(pid).player.health.value == 13.0
  end

  for mode <- [:creative, :spectator] do
    test "#{mode} rejects periodic damage but permits healing and duration expiry", ctx do
      seed(ctx, health: 10.0, mode: unquote(mode))
      {_client, pid} = login(ctx)
      effect(pid, "poison", 1, 31)
      effect(pid, "wither", 1, 31)
      effect(pid, "regeneration", 1, 31)
      tick(pid)
      assert state(pid).player.health.value == 11.0
      assert state(pid).player.health.cooldown == 0 and state(pid).player.effects == %{}
    end
  end

  test "worn protection reduces periodic magic while a carried protection stack cannot", ctx do
    gear = %{
      ItemStack.new("iron_helmet")
      | components: %{"minecraft:enchantments" => %{"minecraft:protection" => 4}}
    }

    seed(ctx, inventory: %Inventory{slots: %{5 => gear}})
    {_client, pid} = login(ctx)
    effect(pid, "poison", 25)
    tick(pid)
    assert state(pid).player.health.value == 19.15999984741211
    assert state(pid).inventory.slots[5] == gear

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %Inventory{slots: %{36 => gear}},
          player: %{s.player | health: %PlayerHealth{}}
      }
    end)

    effect(pid, "wither", 40)
    tick(pid)
    assert state(pid).player.health.value == 19.0 and state(pid).inventory.slots[36] == gear
  end

  test "periodic damage sees Resistance promotion and expiry in the chosen effect-ID order",
       ctx do
    seed(ctx, [])
    {_client, pid} = login(ctx)
    resistance = effect(pid, "resistance", -1)
    effect(pid, "resistance", 1, 4)
    effect(pid, "poison", 25)
    tick(pid)
    assert state(pid).player.health.value == 19.200000762939453
    assert state(pid).player.effects[resistance] == [{-1, 0, false, true, true}]
    assert {:ok, true} = Connection.remove_effect(pid, resistance)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | health: %PlayerHealth{}}} end)
    effect(pid, "resistance", 1, 4)
    effect(pid, "wither", 40)
    tick(pid)
    assert state(pid).player.health.value == 19.0
    assert Map.get(state(pid).player.effects, resistance) == nil
  end

  test "stalled geometry cannot stop or replay owned periodic healing", ctx do
    seed(ctx, health: 10.0)
    {_client, pid} = login(ctx)
    effect(pid, "regeneration", 50)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      for _ <- 1..50, do: tick(pid, false)
      assert state(pid).player.health.value == 11.0 and state(pid).player.effects == %{}
      Valimc.TestRegionGate.resume(region)

      wait(fn ->
        state(pid).pose_job == nil and state(pid).motion_job == nil and
          not state(pid).simulation_due
      end)

      assert state(pid).player.health.value == 11.0
    after
      Valimc.TestRegionGate.resume(region)
    end
  end
end
