defmodule Valimc.PlayerFreezeDamageConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.Living.{Freezing, Health}
  @moduletag :tcp

  alias Valimc.Inventory
  alias Valimc.Player.State, as: PlayerState

  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [living: 1, login: 1, put_living: 2, state: 1]

  setup do: Valimc.TestPlayer.scope("Cold", {82_000, 982})

  defp tick(pid, settle \\ true), do: Valimc.TestPlayer.tick(pid, settle)
  defp ticks(pid, count), do: Valimc.TestPlayer.ticks(pid, count, true)

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{
          freezing: %Freezing{frozen_ticks: 140},
          health: %Health{value: Keyword.get(opts, :health, 20.0)}
        },
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        last_death: nil
      })

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))

    for y <- [64, 65],
        do:
          :ok = Valimc.TestRegion.set_published({floor(ctx.pose.x), y, floor(ctx.pose.z)}, 30519)
  end

  # Retire wall timers while driving the real owner handler with single-use tokens.

  defp zero_phase(pid),
    do: put_living(pid, &%{&1 | freezing: %{&1.freezing | damage_phase: 0, damage_due: false}})

  test "full freezing damages every 40 admitted ticks, emits native packets and survives reconnect",
       ctx do
    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    seed(ctx, inventory: inventory)
    {client, pid} = login(ctx)
    zero_phase(pid)
    ticks(pid, 39)
    assert living(pid).health.value == 20.0
    stale = tick(pid)
    assert living(pid).health.value == 19.0
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:freeze")
    {<<19.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    send(pid, {:player_tick, stale})
    assert living(pid).health.value == 19.0
    ticks(pid, 40)
    assert living(pid).health.value == 18.0
    assert state(pid).inventory == inventory
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 18.0 and saved.frozen_ticks == 140

    assert saved.inventory.slots == inventory.slots

    {_client, owner} = login(ctx)
    assert living(owner).health.value == 18.0
    assert living(owner).freezing.damage_phase < 4
    refute living(owner).freezing.damage_due
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
    {:ok, saved} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 0.0
    assert saved.inventory.slots == %{} and map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 8
    assert state(pid).pose_checked == nil
    assert living(pid).freezing.damage_phase == 0
    refute living(pid).freezing.damage_due
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_, client} = Client.await(client, :play, "respawn")
    {<<20.0::float-32, _::binary>>, _client} = Client.await(client, :play, "set_health")
    assert state(pid).life_stage == :alive and state(pid).inventory.slots == %{}
    assert living(pid).freezing == %Freezing{}
    tick(pid)
    assert living(pid).health.value == 20.0
  end
end
