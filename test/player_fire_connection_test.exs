defmodule Valimc.PlayerFireConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerHealth, PlayerSnapshot, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [state: 1]

  setup do: Valimc.TestPlayer.scope("Fire", {170_000, 983})

  defp tick(pid, settle \\ true),
    do: Valimc.TestPlayer.tick(pid, if(settle, do: :simulation, else: false))

  defp login(ctx, expected_effect \\ nil),
    do: Valimc.TestPlayer.login(ctx, before_load: &effect_on_join(&1, &2, expected_effect))

  defp effect_on_join(client, _pid, nil), do: client

  defp effect_on_join(client, pid, expected) do
    {{entity, id, ticks, level, flags}, client} = effect_packet(client)
    assert entity == state(pid).player.entity_id
    assert {id, ticks, level, flags} == expected
    client
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp material(ctx, name) do
    id = %{"air" => 0, "water" => 89, "lava" => 105, "fire" => 4931, "soul_fire" => 5443}[name]

    for y <- [64, 65],
        do: :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x), y, floor(ctx.pose.z)}, id)
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

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))
    material(ctx, Keyword.get(opts, :material, "lava"))
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
    Valimc.TestRegionGate.stall(owner)

    try do
      for _ <- 1..21, do: tick(pid, false)
      pending = state(pid)
      assert pending.player.fire_ticks == 79 and pending.fire_damage_due
      assert pending.player.health.value == 20.0
      assert pending.pose_job != nil or pending.motion_job != nil
    after
      Valimc.TestRegionGate.resume(owner)
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

  defp rain do
    alias Valimc.World.Clock
    :ok = Clock.configure({:advance_weather, false})
    :ok = Clock.configure({:weather, :rain, 600})
    # Full intensity at once rather than the 0.01-per-tick ramp.
    rain_level(1.0)
    wait(fn -> Clock.weather().wet end)

    on_exit(fn ->
      :ok = Clock.configure({:weather, :clear, 0})
      rain_level(0.0)
      wait(fn -> not Clock.weather().wet end)
      :ok = Clock.configure({:advance_weather, true})
    end)
  end

  defp rain_level(level),
    do:
      :sys.replace_state(Valimc.World.Clock, fn s -> put_in(s.data.weather.rain_level, level) end)

  test "rain extinguishes after natural ignition when a transparent roof is removed", ctx do
    rain()
    seed(ctx, fire: -1, material: "fire")
    roof = {floor(ctx.pose.x), 66, floor(ctx.pose.z)}
    :ok = Valimc.TestRegion.set_published(roof, Data.block("glass"))
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
end
