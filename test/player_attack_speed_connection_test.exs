defmodule Valimc.PlayerAttackSpeedConnectionTest do
  # Login/effect/death flows share the global player lifecycle and socket listener.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Data.EffectTypes
  alias Valimc.Living.Attributes
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Vitals
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.TestClient, as: Client
  alias Valimc.{TestConn, TestPlayer}

  setup do
    ctx = TestPlayer.scope("Speed", {159_000, 642}, survival: {2, false})

    inventory = %Inventory{
      slots: %{
        36 => ItemStack.new("diamond_sword"),
        37 => ItemStack.new("diamond_axe"),
        38 => ItemStack.new("stone")
      }
    }

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival)
      })

    TestPlayer.save(ctx, player, inventory)
    ctx
  end

  defp await_speed(client, entity, hand, effects) do
    {:ok, %{attribute: {id, base, modifiers}}} = Attributes.attack_speed(hand, effects)
    current = Map.get(Map.get(client, :attributes, %{}), {entity, id})

    if current && elem(current, 0) == base && Enum.sort(elem(current, 1)) == Enum.sort(modifiers) do
      client
    else
      {packet, body, client} = Client.read(client)
      client = Client.auto_reply(client, :play, Data.name(:play, :clientbound, packet), body)
      await_speed(client, entity, hand, effects)
    end
  end

  defp effect(pid, name, incoming) do
    TestConn.call(pid, fn state ->
      {:ok, _, state} = Vitals.apply_effect(state, EffectTypes.id(name), incoming)
      {:reply, :ok, state}
    end)
  end

  test "login, held changes, effect promotion/removal and expiry update the cooldown attribute",
       ctx do
    {client, pid} = TestPlayer.login(ctx)
    entity = TestPlayer.state(pid).player.entity_id
    sword = ItemStack.new("diamond_sword")
    axe = ItemStack.new("diamond_axe")
    client = await_speed(client, entity, sword, %{})
    Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
    client = await_speed(client, entity, axe, %{})

    :ok = effect(pid, "haste", [{-1, 1, false, true, true}])
    client = await_speed(client, entity, axe, TestPlayer.living(pid).effects)
    :ok = effect(pid, "mining_fatigue", [{2, 1, false, true, true}])
    client = await_speed(client, entity, axe, TestPlayer.living(pid).effects)
    TestPlayer.ticks(pid, 2)
    refute Map.has_key?(TestPlayer.living(pid).effects, EffectTypes.id("mining_fatigue"))
    client = await_speed(client, entity, axe, TestPlayer.living(pid).effects)
    :ok = effect(pid, "haste", :remove)
    client = await_speed(client, entity, axe, %{})
    Client.send_packet(client, :play, "set_carried_item", <<2::signed-16>>)
    _client = await_speed(client, entity, ItemStack.new("stone"), %{})
    {:ok, %{attribute: expected}} = Attributes.attack_speed(nil, %{})
    assert TestPlayer.state(pid).attack_speed_view == expected
  end

  test "a new client after reconnect receives the saved weapon's attack speed", ctx do
    {client, pid} = TestPlayer.login(ctx)
    entity = TestPlayer.state(pid).player.entity_id
    _client = await_speed(client, entity, ItemStack.new("diamond_sword"), %{})
    TestPlayer.checkpointed(pid)
    Client.close(client)
    Valimc.TestWait.until(fn -> not Process.alive?(pid) end)
    {client, pid} = TestPlayer.login(ctx)

    _client =
      await_speed(
        client,
        TestPlayer.state(pid).player.entity_id,
        ItemStack.new("diamond_sword"),
        %{}
      )

    assert TestPlayer.state(pid).attack_speed_view != nil
  end

  test "respawn resets the weapon and effect attribute in the new client entity state", ctx do
    {client, pid} = TestPlayer.login(ctx)
    entity = TestPlayer.state(pid).player.entity_id
    client = await_speed(client, entity, ItemStack.new("diamond_sword"), %{})
    :ok = effect(pid, "mining_fatigue", [{-1, 1, false, true, true}])

    client =
      await_speed(client, entity, ItemStack.new("diamond_sword"), TestPlayer.living(pid).effects)

    TestConn.call(pid, fn state ->
      {:reply, :ok, Vitals.apply_effect_action(state, {:hurt, :generic_kill, 100.0})}
    end)

    Valimc.TestWait.until(fn -> TestPlayer.state(pid).life_stage == :dead end)
    Client.send_packet(client, :play, "client_command", <<0>>)
    {_respawn, client} = Client.await(client, :play, "respawn")
    next = TestPlayer.state(pid)
    _client = await_speed(client, next.player.entity_id, nil, %{})
    assert next.life_stage == :alive
    assert next.player.living.effects == %{}
    {:ok, %{attribute: expected}} = Attributes.attack_speed(nil, %{})
    assert next.attack_speed_view == expected
  end
end
