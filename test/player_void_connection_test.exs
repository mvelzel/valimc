defmodule Valimc.PlayerVoidConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerHealth, PlayerSnapshot, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [login: 1, state: 1, tick: 1, ticks: 2]

  setup do
    ctx = Valimc.TestPlayer.scope("Void", {105_000, 986})
    put_in(ctx.pose.y, -129.0)
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx, opts) do
    mode = Keyword.get(opts, :mode, :survival)

    player =
      Map.merge(ctx.pose, %{
        y: Keyword.get(opts, :y, -129.0),
        game_mode: Valimc.GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
        health: %PlayerHealth{value: Keyword.get(opts, :health, 20.0)},
        last_death: nil,
        air_supply: 300
      })

    Valimc.TestPlayer.save(ctx, player, Keyword.get(opts, :inventory, %Inventory{}))
  end

  test "strict boundary uses accepted position, never the predicted gravity destination", ctx do
    seed(ctx, y: -128.0)
    {client, pid} = login(ctx)
    ticks(pid, 25)
    wait(fn -> elem(state(pid).player.motion.velocity, 1) < 0.0 end)
    assert state(pid).player.y == -128.0 and state(pid).player.health.value == 20.0
    p = state(pid).player

    Client.send_raw(client, [
      Wire.frame(
        Data.id(:play, :serverbound, "move_player_pos"),
        <<p.x::float-64, -128.125::float-64, p.z::float-64, 0>>,
        client.threshold
      ),
      Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, client.threshold)
    ])

    wait(fn -> state(pid).player.y == -128.125 end)
    tick(pid)
    assert state(pid).player.health.value == 16.0
  end

  test "admitted ticks share the native cooldown, packet source and persistent health", ctx do
    seed(ctx, inventory: %Inventory{slots: %{36 => ItemStack.new("stone", 7)}})
    {client, pid} = login(ctx)
    stale = tick(pid)
    before = state(pid)
    assert before.player.health.value == 16.0 and before.player.health.cooldown == 20
    for _ <- 1..20, do: send(pid, {:player_tick, stale})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick
    assert state(pid).player.health == before.player.health
    # The current token before its deadline also cannot advance damage/cooldown.
    send(pid, {:player_tick, state(pid).simulation_clock.token})
    assert state(pid).simulation_clock.tick == before.simulation_clock.tick
    assert state(pid).player.health == before.player.health
    {body, client} = Client.await(client, :play, "damage_event")
    {entity, rest} = Wire.take_varint(body)
    {source, <<0, 0, 0>>} = Wire.take_varint(rest)
    assert entity == state(pid).player.entity_id
    assert source == Data.registry_id("minecraft:damage_type", "minecraft:out_of_world")
    {<<16.0::float-32, _::binary>>, client} = Client.await(client, :play, "set_health")
    ticks(pid, 9)
    assert state(pid).player.health.value == 16.0
    tick(pid)
    assert state(pid).player.health.value == 12.0
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    assert saved.health.value == 12.0 and saved.pose.y == -129.0
    assert saved.inventory.slots[36] == ItemStack.new("stone", 7)
    assert saved.transfer_sequence == 0 and saved.outbox == nil
    {_client, owner} = login(ctx)
    assert state(owner).player.health.value == 12.0 and state(owner).player.health.cooldown == 0
    tick(owner)
    assert state(owner).player.health.value == 8.0
  end

  test "void consequences do not wait on stalled geometry and ignore armor/enchantment defenses",
       ctx do
    gear = %{
      ItemStack.new("iron_helmet")
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:protection" => 255,
            "minecraft:feather_falling" => 255
          }
        }
    }

    inventory = %Inventory{slots: %{5 => gear}}
    seed(ctx, inventory: inventory)
    {_client, pid} = login(ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    Valimc.TestRegionGate.stall(region)

    try do
      tick(pid)
      assert state(pid).player.health.value == 16.0
      ticks(pid, 10)
      assert state(pid).player.health.value == 12.0
      assert state(pid).inventory.slots == inventory.slots
    after
      Valimc.TestRegionGate.resume(region)
    end
  end

  test "a fatal tick seals once while its writer is stalled, then respawns after durable batches",
       ctx do
    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:vanishing_curse" => 0}
        }
    }

    inventory = %Inventory{
      slots: Map.put(Map.new(36..43, &{&1, ItemStack.new("stone", &1 - 35)}), 5, helmet)
    }

    seed(ctx, health: 4.0, inventory: inventory)
    {client, pid} = login(ctx)
    writer = state(pid).player_store
    :sys.suspend(writer)

    try do
      tick(pid)
      {body, client} = Client.await(client, :play, "player_combat_kill")
      assert :binary.match(body, "death.attack.outOfWorld") != :nomatch
      assert state(pid).life_stage == :sealing_death
      marker = state(pid).save_ref
      ticks(pid, 15)
      assert state(pid).save_ref == marker and state(pid).player.health.value == 0.0
      Client.send_packet(client, :play, "client_command", <<0>>)
      wait(fn -> state(pid).respawn_requested end)
      :sys.resume(writer)
      {_, client} = Client.await(client, :play, "respawn")
      {<<13, 0::32>>, client} = Client.await(client, :play, "game_event")
      {<<20.0::float-32, _::binary>>, _client} = Client.await(client, :play, "set_health")
      assert state(pid).life_stage == :alive and state(pid).inventory.slots == %{}
      assert state(pid).player.y == 64.0 and state(pid).player.air_supply == 300
      {:ok, saved} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
      assert saved.health.value == 20.0 and saved.transfer_sequence == 2 and saved.outbox == nil
      assert saved.last_death == {floor(ctx.pose.x), -129, floor(ctx.pose.z)}
      records = World.item_snapshot(ctx.key)
      assert map_size(records) == 8
      ticks(pid, 12)
      assert state(pid).player.health.value == 20.0
      assert World.item_snapshot(ctx.key) == records
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end
end
