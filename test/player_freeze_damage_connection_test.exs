defmodule Valimc.PlayerFreezeDamageConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{
    Connection,
    Inventory,
    PlayerEnvironment,
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
    name = "Cold#{nonce}"
    uuid = Connection.offline_uuid(name)
    base = Path.join(System.tmp_dir!(), "valimc-freeze-damage-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {82_000 + rem(nonce, 10_000), 982}
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

  defp state(pid), do: Valimc.TestConn.state(pid)

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

  defp seed(ctx, opts \\ []) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        environment: %PlayerEnvironment{frozen_ticks: 140},
        health: %PlayerHealth{value: Keyword.get(opts, :health, 20.0)},
        last_death: nil
      })

    inventory = Keyword.get(opts, :inventory, %Inventory{})
    {:ok, bytes} = PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, inventory))
    File.mkdir_p!(Path.dirname(ctx.path))
    File.write!(ctx.path, bytes)
    for y <- [64, 65], do: :ok = World.set_block({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 30519)
  end

  # Retire wall timers while driving the real owner handler with single-use tokens.
  defp park(pid) do
    :sys.replace_state(pid, fn s ->
      clock = %{
        s.simulation_clock
        | token: {s.simulation_clock.epoch, make_ref()},
          deadline: System.monotonic_time(:millisecond) + 60_000
      }

      %{s | simulation_clock: clock}
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

  defp zero_phase(pid) do
    :sys.replace_state(pid, fn s ->
      %{
        s
        | player: %{
            s.player
            | environment: %{s.player.environment | damage_phase: 0, damage_due: false}
          }
      }
    end)
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

  test "full freezing damages every 40 admitted ticks, emits native packets and survives reconnect",
       ctx do
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    seed(ctx, inventory: inventory)
    {client, pid} = login(ctx)
    zero_phase(pid)
    ticks(pid, 39)
    assert state(pid).player.health.value == 20.0
    stale = tick(pid)
    assert state(pid).player.health.value == 19.0
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:freeze")
    {<<19.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    send(pid, {:player_tick, stale})
    assert state(pid).player.health.value == 19.0
    ticks(pid, 40)
    assert state(pid).player.health.value == 18.0
    assert state(pid).inventory == inventory
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 18.0 and saved.frozen_ticks == 140

    assert saved.inventory.slots == inventory.slots and saved.transfer_sequence == 0 and
             saved.outbox == nil

    {_client, owner} = login(ctx)
    assert state(owner).player.health.value == 18.0
    assert state(owner).player.environment.damage_phase < 4
    refute state(owner).player.environment.damage_due
  end

  test "blocked geometry coalesces due periods and a fresh observation consumes only once", ctx do
    seed(ctx)
    {_client, pid} = login(ctx)
    zero_phase(pid)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      for _ <- 1..80, do: tick(pid, false)
      assert state(pid).player.environment.damage_due
      assert state(pid).player.health.value == 20.0
      Valimc.TestRegionGate.resume(region)
      # An expired query is discarded; an admitted tick starts a fresh one.
      tick(pid)
      assert state(pid).player.health.value == 19.0
      refute state(pid).player.environment.damage_due
      tick(pid)
      assert state(pid).player.health.value == 19.0
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "leaving powder or equipping native immune gear before a due read prevents cold damage",
       ctx do
    seed(ctx)
    {client, pid} = login(ctx)
    zero_phase(pid)
    ticks(pid, 39)
    client = Client.teleport(client, pid, %{ctx.pose | x: ctx.pose.x + 3})
    tick(pid)
    assert state(pid).player.health.value == 20.0
    assert state(pid).player.environment.frozen_ticks == 138
    _client = Client.teleport(client, pid, ctx.pose)

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %Inventory{slots: %{5 => ItemStack.new("leather_helmet")}},
          player: %{
            s.player
            | environment: %PlayerEnvironment{frozen_ticks: 140, damage_phase: 39}
          }
      }
    end)

    tick(pid)
    assert state(pid).player.health.value == 20.0
    assert state(pid).player.environment.frozen_ticks == 138
    refute state(pid).player.environment.damage_due
  end

  for {enchantment, damage} <- [{"protection", 0.8400000333786011}, {"feather_falling", 1.0}] do
    test "native #{enchantment} freezing defense uses only applicable worn effects", ctx do
      gear = %{
        ItemStack.new("iron_boots")
        | components: %{
            "minecraft:enchantments" => %{("minecraft:" <> unquote(enchantment)) => 4}
          }
      }

      inventory = %Inventory{slots: %{8 => gear}}
      seed(ctx, inventory: inventory)
      {_client, pid} = login(ctx)
      zero_phase(pid)
      ticks(pid, 40)
      <<expected::float-32>> = <<20.0 - unquote(damage)::float-32>>
      assert state(pid).player.health.value == expected
      assert state(pid).inventory == inventory
    end
  end

  for mode <- [:creative, :spectator] do
    test "#{mode} remains immune to freezing consequences", ctx do
      seed(ctx, mode: unquote(mode))
      {_client, pid} = login(ctx)
      zero_phase(pid)
      ticks(pid, 40)
      assert state(pid).player.health.value == 20.0 and state(pid).life_stage == :alive
    end
  end

  test "fatal cold seals inventory and respawns without a previous body's pending consequence",
       ctx do
    inventory = %Inventory{slots: Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)})}
    seed(ctx, health: 1.0, inventory: inventory)
    {client, pid} = login(ctx)
    zero_phase(pid)
    ticks(pid, 40)
    {_, client} = Client.await(client, :play, "player_combat_kill")
    wait(fn -> state(pid).life_stage == :dead end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.transfer_sequence == 2 and saved.outbox == nil
    assert saved.inventory.slots == %{} and map_size(World.item_snapshot(ctx.key)) == 8
    assert state(pid).pose_checked == nil
    assert state(pid).player.environment.damage_phase == 0
    refute state(pid).player.environment.damage_due
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {<<20.0::float-32, _::binary>>, _client} = Client.await(client, :play, "set_health")
    assert state(pid).life_stage == :alive and state(pid).inventory.slots == %{}
    assert state(pid).player.environment == %PlayerEnvironment{}
    tick(pid)
    assert state(pid).player.health.value == 20.0
  end
end
