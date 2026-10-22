defmodule Valimc.PlayerAirConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Effects, Freezing, Health}
  @moduletag :tcp

  alias Valimc.{Connection, Inventory}
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1, login: 1, put_living: 2, state: 1]

  setup do: Valimc.TestPlayer.scope("Air", {94_000, 984})

  defp tick(pid, settle \\ true), do: Valimc.TestPlayer.tick(pid, settle)
  defp ticks(pid, count), do: Valimc.TestPlayer.ticks(pid, count, true)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{
          freezing: %Freezing{},
          health: %Health{value: Keyword.get(opts, :health, 20.0)},
          air_supply: Keyword.get(opts, :air, 1)
        },
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        last_death: nil
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
    put_living(pid, air_supply: 1)
    stale = tick(pid)

    assert living(pid).air_supply == 0 and
             living(pid).health.value == 20.0

    client = await_air(client, state(pid).player.entity_id, 0)
    ticks(pid, 19)

    assert living(pid).air_supply == -19 and
             living(pid).health.value == 20.0

    tick(pid)

    assert living(pid).air_supply == 0 and
             living(pid).health.value == 18.0

    {body, client} = Client.await(client, :play, "entity_event")
    assert body == <<state(pid).player.entity_id::signed-32, 67>>
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:drown")
    {<<18.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    send(pid, {:player_tick, stale})

    assert living(pid).air_supply == 0 and
             living(pid).health.value == 18.0

    ticks(pid, 20)
    assert living(pid).health.value == 16.0 and state(pid).inventory == inventory
    ticks(pid, 7)
    assert living(pid).air_supply == -7
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.air_supply == -7 and saved.health.value == 16.0
    {_client, owner} = login(ctx)
    assert living(owner).air_supply in -8..-7

    assert living(owner).health.value == 16.0 and
             state(owner).inventory.slots == inventory.slots
  end

  test "a grant after the drowning tick cannot reduce its damage", ctx do
    seed(ctx, air: -19)
    {_client, pid} = login(ctx)
    put_living(pid, air_supply: -19)
    tick(pid, false)
    assert state(pid).environment_effects == %{}
    {:ok, effect} = Effects.new(-1, 4)

    assert {:ok, true} =
             Connection.add_effect(pid, Valimc.Protocol.EffectTypes.id("resistance"), effect)

    assert living(pid).health.value == 18.0 and living(pid).air_supply == 0
    put_living(pid, &%{&1 | air_supply: -19, health: %{&1.health | cooldown: 0}})
    tick(pid)
    assert living(pid).health.value == 18.0 and living(pid).air_supply == 0
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
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0 and saved.air_supply == 0
    assert saved.inventory.slots == %{}
    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1
    ticks(pid, 2)
    assert living(pid).air_supply == 0
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {<<20.0::float-32, _::binary>>, _client} = Client.await(client, :play, "set_health")
    assert state(pid).life_stage == :alive and living(pid).air_supply == 300
    assert state(pid).inventory.slots == %{}
  end
end
