defmodule Valimc.CombatConnectionTest do
  @moduledoc """
  Melee through a connection (VMC-037n): a player's full-strength sword hits
  kill a summoned zombie, which drops its loot and experience; a zombie's hits
  on an armoured player deal the armor's share, knock the player back, and a
  raised shield blocks them.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000

  alias Valimc.Entity.{Body, Store}
  alias Valimc.Living.Damage
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Food
  alias Valimc.Protocol.{ItemStack, Packets, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.{Region, RegionData}

  setup do
    ctx = TestPlayer.scope("Combat", {143_000, 993}, survival: {2, false})
    # Bodies age (their hurt cooldown runs) where items simulate.
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key), item_simulation: true)
    ctx
  end

  defp save(ctx, yaw, inventory) do
    player = %{
      living: %Valimc.Living{
        freezing: %Valimc.Living.Freezing{},
        health: %Valimc.Living.Health{value: 20.0},
        air_supply: 300,
        effects: %{},
        absorption: 0.0
      },
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: yaw,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Food{}
    }

    TestPlayer.save(ctx, player, inventory)
  end

  # A zombie two blocks east of the player, facing west at it.
  defp summon(ctx, uuid) do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new("minecraft:zombie")
    # No goals: the test moves it alone (VMC-041a).
    body = put_in(body.mob.no_ai, true)
    record = Store.body_record(%{body | yaw: 90.0}, uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})
    :ok = Region.drop_items(owner, [record])

    Valimc.TestWait.until(fn ->
      match?({:ok, _}, Store.find(store(owner), uuid)) and
        Enum.any?(Valimc.World.bodies(:overworld), &(elem(&1, 1).uuid == uuid))
    end)

    owner
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp body(owner, uuid) do
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    {id, store(owner).entries[id]}
  end

  test "full-strength sword hits kill a zombie, which drops its loot and experience", ctx do
    save(ctx, -90.0, %Inventory{slots: %{36 => ItemStack.new("diamond_sword")}})
    {client, pid} = TestPlayer.login(ctx)
    uuid = <<5::128>>
    owner = summon(ctx, uuid)
    {id, _} = body(owner, uuid)
    # The client tracks the zombie before it attacks it.
    {_, client} = Client.await(client, :play, "add_entity")
    {:ok, dealt} = Damage.armor_absorb(7.0, 2.0, 0.0)

    hit = fn ->
      # The zombie's hurt cooldown runs on its group's ticks; a sword charges in
      # 12.5 of the player's (the first tick after login starts the count over
      # for the newly held sword).
      Valimc.TestWait.until(fn ->
        elem(body(owner, uuid), 1).body.mob.living.health.cooldown <= 10
      end)

      before = elem(body(owner, uuid), 1).body.mob.living.health.value
      TestPlayer.ticks(pid, 14)
      Client.send_packet(client, :play, "attack", Wire.varint(id))
      Client.send_packet(client, :play, "punch", <<>>)
      # Landed, and the swing after it started the strength over.
      Valimc.TestWait.until(fn ->
        elem(body(owner, uuid), 1).body.mob.living.health.value < before and
          TestPlayer.state(pid).attack.ticker == 0
      end)
    end

    hit.()
    expected = Valimc.Data.Float32.round(20.0 - dealt)

    Valimc.TestWait.until(fn ->
      elem(body(owner, uuid), 1).body.mob.living.health.value == expected
    end)

    {payload, client} = Client.await(client, :play, "damage_event")
    me = TestPlayer.state(pid).player.entity_id
    {_, event} = Packets.damage_event(id, :player_attack, me, me)
    assert payload == IO.iodata_to_binary(event)

    hit.()
    hit.()

    # Its 5 experience: in orbs, or already picked up by the player beside it.
    Valimc.TestWait.until(fn ->
      orbs = for %{kind: :orb} = e <- Map.values(store(owner).entries), do: e.value * e.count
      Enum.sum(orbs) + TestPlayer.state(pid).player.progression.experience.total == 5
    end)

    refute Body.alive?(elem(body(owner, uuid), 1).body)
    # The sword wore by one point a hit.
    assert TestPlayer.state(pid).inventory.slots[36].components["minecraft:damage"] == 3
    _ = client
  end

  test "a zombie's hits go through armor and knock the player back; a raised shield blocks them",
       ctx do
    inventory = %Inventory{
      slots: %{6 => ItemStack.new("iron_chestplate"), 45 => ItemStack.new("shield")}
    }

    save(ctx, -90.0, inventory)
    {client, pid} = TestPlayer.login(ctx)
    uuid = <<6::128>>
    owner = summon(ctx, uuid)

    attack = fn ->
      Valimc.TestRegion.replace_section(owner, fn section ->
        :ok = RegionData.mob_attack(section, uuid, ctx.uuid)
        section
      end)
    end

    attack.()
    # A zombie's 3 at normal difficulty, through an iron chestplate's 6 armor.
    {:ok, dealt} = Damage.armor_absorb(3.0, 6.0, 0.0)
    expected = Valimc.Data.Float32.round(20.0 - dealt)
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == expected end)
    {_, client} = Client.await(client, :play, "set_entity_motion")

    # Raised for the shield's block delay, facing the zombie.
    TestPlayer.ticks(pid, 20)

    Client.send_packet(
      client,
      :play,
      "use_item",
      IO.iodata_to_binary([Wire.varint(1), Wire.varint(1), <<-90.0::float-32, 0::float-32>>])
    )

    Valimc.TestWait.until(fn -> match?(%{blocking: true}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 6)
    attack.()

    Valimc.TestWait.until(fn ->
      shield = TestPlayer.state(pid).inventory.slots[45]
      shield.components["minecraft:damage"] == 4
    end)

    assert TestPlayer.living(pid).health.value == expected
    _ = client
  end
end
