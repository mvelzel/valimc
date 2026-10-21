defmodule Valimc.PlayerFreezeDamageConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{Inventory, PlayerEnvironment, PlayerHealth, PlayerSnapshot, World}

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [login: 1, state: 1]

  setup do: Valimc.TestPlayer.scope("Cold", {82_000, 982})

  defp tick(pid, settle \\ true), do: Valimc.TestPlayer.tick(pid, settle)
  defp ticks(pid, count), do: Valimc.TestPlayer.ticks(pid, count, true)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

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

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))

    for y <- [64, 65],
        do:
          :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 30519)
  end

  # Retire wall timers while driving the real owner handler with single-use tokens.

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
