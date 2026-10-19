defmodule Valimc.PlayerAirConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{
    Connection,
    Inventory,
    PlayerAir,
    PlayerHealth,
    PlayerSnapshot,
    PlayerStore,
    Players,
    World
  }

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    name = "Air#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-air-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {94_000 + rem(nonce, 10_000), 984}
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
        air_supply: Keyword.get(opts, :air, 1)
      })

    inventory = Keyword.get(opts, :inventory, %Inventory{})
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
    for y <- [64, 65], do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 89)
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

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    pid = wait(fn -> Enum.find(Players.all(), &(&1.name == ctx.name)) end).pid
    park(pid)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    wait(fn ->
      not state(pid).teleport_pending and Valimc.PlayerInput.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp tick(pid, await_geometry \\ true) do
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

    token = before.simulation_clock.token
    send(pid, {:player_tick, token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick + 1
    park(pid)

    if await_geometry,
      do: wait(fn -> state(pid).pose_job == nil and state(pid).motion_job == nil end)

    token
  end

  defp ticks(pid, count), do: Enum.each(1..count, fn _ -> tick(pid) end)

  defp await_air(client, entity, value) do
    if get_in(client, [:entity_air, entity]) == value do
      client
    else
      {id, body, client} = Client.read(client)

      await_air(
        Client.auto_reply(client, :play, Data.name(:play, :clientbound, id), body),
        entity,
        value
      )
    end
  end

  test "fresh eye contact drains air through grace, source packets, repeated damage and reconnect",
       ctx do
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    seed(ctx, inventory: inventory)
    {client, pid} = login(ctx)
    # Retain the seeded boundary independently of login wall-clock timing.
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: 1}} end)
    stale = tick(pid)
    assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 20.0
    client = await_air(client, state(pid).player.entity_id, 0)
    ticks(pid, 19)
    assert state(pid).player.air_supply == -19 and state(pid).player.health.value == 20.0
    tick(pid)
    assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 18.0
    {body, client} = Client.await(client, :play, "entity_event")
    assert body == <<state(pid).player.entity_id::signed-32, 67>>
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:drown")
    {<<18.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    send(pid, {:player_tick, stale})
    assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 18.0
    ticks(pid, 20)
    assert state(pid).player.health.value == 16.0 and state(pid).inventory == inventory
    ticks(pid, 7)
    assert state(pid).player.air_supply == -7
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.air_supply == -7 and saved.health.value == 16.0
    assert saved.transfer_sequence == 0 and saved.outbox == nil
    {_client, owner} = login(ctx)
    assert state(owner).player.air_supply in -8..-7

    assert state(owner).player.health.value == 16.0 and
             state(owner).inventory.slots == inventory.slots
  end

  test "body-only water, surfacing and bubble columns replenish; no frame means no air consequence",
       ctx do
    seed(ctx, air: 20)
    {client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: 20}} end)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      for _ <- 1..40, do: tick(pid, false)
      assert state(pid).player.air_supply == 20
      assert state(pid).player.health.value == 20.0
    after
      Valimc.TestRegionGate.resume(region)
    end

    tick(pid)
    assert state(pid).player.air_supply == 19
    :ok = World.set_block({floor(ctx.pose.x), 65, floor(ctx.pose.z)}, 0)
    tick(pid)
    assert state(pid).player.air_supply == 23

    for id <- PlayerAir.bubble_states() do
      :ok = World.set_block({floor(ctx.pose.x), 65, floor(ctx.pose.z)}, id)
      before = state(pid).player.air_supply
      tick(pid)
      assert state(pid).player.air_supply == before + 4
    end

    _client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 3})
    ticks(pid, 70)
    assert state(pid).player.air_supply == 300 and state(pid).player.health.value == 20.0
  end

  for mode <- [:creative, :spectator] do
    test "#{mode} refills depleted underwater air without drowning", ctx do
      seed(ctx, air: -19, mode: unquote(mode))
      {_client, pid} = login(ctx)
      :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
      ticks(pid, 40)
      assert state(pid).player.air_supply == 141
      assert state(pid).player.health.value == 20.0 and state(pid).life_stage == :alive
    end
  end

  test "tick-start Water Breathing refills through the expiry tick; Fire Resistance cannot protect air",
       ctx do
    seed(ctx, air: 40)
    {client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: 40}} end)
    {:ok, effect} = Valimc.StatusEffect.new(2, 255)
    assert {:ok, true} = Connection.add_effect(pid, 12, effect)
    tick(pid)
    assert state(pid).player.air_supply == 44 and state(pid).air_policy == :refill
    tick(pid)
    assert state(pid).player.air_supply == 48 and state(pid).player.effects == %{}
    client = await_air(client, state(pid).player.entity_id, 48)
    tick(pid)
    assert state(pid).player.air_supply == 47 and state(pid).air_policy == :none
    {:ok, fire} = Valimc.StatusEffect.new(-1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 11, fire)
    tick(pid)
    assert state(pid).player.air_supply == 46 and state(pid).player.health.value == 20.0
    _client = await_air(client, state(pid).player.entity_id, 46)
  end

  test "one-tick breathing expires into ordinary drowning and persists across fresh reconnect",
       ctx do
    seed(ctx, air: -19)
    {client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
    {:ok, one} = Valimc.StatusEffect.new(1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 12, one)
    tick(pid)
    assert state(pid).player.air_supply == -15 and state(pid).player.effects == %{}
    ticks(pid, 5)
    assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 18.0
    {:ok, saved_effect} = Valimc.StatusEffect.new(200, 0)
    assert {:ok, true} = Connection.add_effect(pid, 12, saved_effect)
    ticks(pid, 3)
    assert state(pid).player.air_supply == 12
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    assert {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.air_supply == 12 and saved.effects == %{12 => [{197, 0, false, true, true}]}
    {_client, owner} = login(ctx)
    assert state(owner).player.effects[12] != nil
    assert state(owner).player.air_supply in 12..16
    assert state(owner).player.health.value == 18.0
  end

  test "delayed geometry uses the latest admitted breathing policy without replaying expired protection",
       ctx do
    seed(ctx, air: -19)
    {_client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
    {:ok, one} = Valimc.StatusEffect.new(1, 0)
    assert {:ok, true} = Connection.add_effect(pid, 12, one)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      for _ <- 1..5, do: tick(pid, false)
      assert state(pid).player.air_supply == -19
      assert state(pid).player.effects == %{} and state(pid).air_policy == :none
      Valimc.TestRegionGate.resume(region)

      wait(fn ->
        not state(pid).simulation_due and state(pid).pose_job == nil and
          state(pid).motion_job == nil
      end)

      assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 18.0
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "drowning mitigation uses the admitted Resistance level through its expiry tick", ctx do
    seed(ctx, air: -19)
    {_client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
    id = Valimc.Protocol.EffectTypes.id("resistance")
    {:ok, effect} = Valimc.StatusEffect.new(1, 0)
    assert {:ok, true} = Connection.add_effect(pid, id, effect)
    tick(pid)
    assert state(pid).player.effects == %{} and state(pid).player.air_supply == 0
    assert state(pid).player.health.value == 18.399999618530273
  end

  test "a grant after air admission cannot reduce its older drowning request", ctx do
    seed(ctx, air: -19)
    {_client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      tick(pid, false)
      assert state(pid).environment_effects == %{}
      {:ok, effect} = Valimc.StatusEffect.new(-1, 4)

      assert {:ok, true} =
               Connection.add_effect(pid, Valimc.Protocol.EffectTypes.id("resistance"), effect)

      Valimc.TestRegionGate.resume(region)

      wait(fn ->
        not state(pid).simulation_due and state(pid).pose_job == nil and
          state(pid).motion_job == nil
      end)

      assert state(pid).player.health.value == 18.0 and state(pid).player.air_supply == 0

      :sys.replace_state(pid, fn s ->
        %{s | player: %{s.player | air_supply: -19, health: %{s.player.health | cooldown: 0}}}
      end)

      tick(pid)
      assert state(pid).player.health.value == 18.0 and state(pid).player.air_supply == 0
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "a later breathing grant cannot retroactively protect an already admitted air step", ctx do
    seed(ctx, air: -19)
    {_client, pid} = login(ctx)
    :sys.replace_state(pid, fn s -> %{s | player: %{s.player | air_supply: -19}} end)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      tick(pid, false)
      assert state(pid).air_policy == :none and state(pid).player.air_supply == -19
      {:ok, infinite} = Valimc.StatusEffect.new(-1, 0)
      assert {:ok, true} = Connection.add_effect(pid, 12, infinite)
      Valimc.TestRegionGate.resume(region)

      wait(fn ->
        not state(pid).simulation_due and state(pid).pose_job == nil and
          state(pid).motion_job == nil
      end)

      assert state(pid).player.air_supply == 0 and state(pid).player.health.value == 18.0
      tick(pid)
      assert state(pid).air_policy == :refill and state(pid).player.air_supply == 4
      assert state(pid).player.effects[12] == [{-1, 0, false, true, true}]
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "current direct head respiration preserves air on its seeded draw; carried enchantments do not",
       ctx do
    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{"minecraft:enchantments" => %{"minecraft:respiration" => 255}}
    }

    seed(ctx, air: 10, inventory: %Inventory{slots: %{5 => helmet}})
    {_client, pid} = login(ctx)

    :sys.replace_state(pid, fn s ->
      :rand.seed(:exsss, {7, 8, 9})
      %{s | player: %{s.player | air_supply: 10}}
    end)

    tick(pid)
    assert state(pid).player.air_supply == 10

    :sys.replace_state(pid, fn s ->
      %{s | inventory: %Inventory{slots: %{36 => helmet}}}
    end)

    tick(pid)
    assert state(pid).player.air_supply == 9
  end

  test "retired underwater geometry cannot spend air after a dry relocation", ctx do
    seed(ctx, air: -19)
    {client, pid} = login(ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      tick(pid, false)
      job = wait(fn -> state(pid).pose_job end)
      _client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 3})
      send(pid, {job.task.ref, {:ok, %{submerged: true}}})
      assert state(pid).player.health.value == 20.0
      Valimc.TestRegionGate.resume(region)
      tick(pid)
      assert state(pid).player.air_supply == -15
      assert state(pid).player.health.value == 20.0
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "worn Protection mitigates drowning before the fatal boundary without armor wear", ctx do
    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:protection" => 4}
        }
    }

    seed(ctx, air: -19, health: 2.0, inventory: %Inventory{slots: %{5 => helmet}})
    {_client, pid} = login(ctx)
    tick(pid)
    assert state(pid).player.health.value == 0.31999993324279785
    assert state(pid).life_stage == :alive and state(pid).inventory.slots[5] == helmet
    assert state(pid).player.health.last_hurt == 2.0
  end

  test "fatal drowning commits air and inventory once, then respawn restores full air", ctx do
    seed(ctx,
      air: -19,
      health: 2.0,
      inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    )

    {client, pid} = login(ctx)
    tick(pid)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    wait(fn -> state(pid).life_stage == :dead end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.air_supply == 0
    assert saved.inventory.slots == %{} and saved.transfer_sequence == 1 and saved.outbox == nil
    assert map_size(World.item_snapshot(ctx.key)) == 1
    ticks(pid, 2)
    assert state(pid).player.air_supply == 0
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {<<20.0::float-32, _::binary>>, _client} = Client.await(client, :play, "set_health")
    assert state(pid).life_stage == :alive and state(pid).player.air_supply == 300
    assert state(pid).inventory.slots == %{}
  end
end
