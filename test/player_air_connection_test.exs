defmodule Valimc.PlayerAirConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.{Connection, Inventory, PlayerHealth, PlayerSnapshot, World}

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [login: 1, state: 1]

  setup do: Valimc.TestPlayer.scope("Air", {94_000, 984})

  defp tick(pid, settle \\ true), do: Valimc.TestPlayer.tick(pid, settle)
  defp ticks(pid, count), do: Valimc.TestPlayer.ticks(pid, count, true)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

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

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))

    for y <- [64, 65],
        do: :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 89)
  end

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
        not state(pid).simulation_due and Valimc.TestConn.job(state(pid), :pose) == nil and
          Valimc.TestConn.job(state(pid), :motion) == nil
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

  test "retired underwater geometry cannot spend air after a dry relocation", ctx do
    seed(ctx, air: -19)
    {client, pid} = login(ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      tick(pid, false)
      job = wait(fn -> Valimc.TestConn.job(state(pid), :pose) end)
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
