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
    {id, Valimc.TestBodies.entry(store(owner).entries[id])}
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

  test "zero attack speed from high Mining Fatigue remains a weak attack without closing the connection",
       ctx do
    save(ctx, -90.0, %Inventory{slots: %{36 => ItemStack.new("diamond_sword")}})
    {client, pid} = TestPlayer.login(ctx)
    uuid = <<861::128>>
    owner = summon(ctx, uuid)
    {id, _} = body(owner, uuid)
    {_entity, client} = Client.await(client, :play, "add_entity")
    fatigue = Valimc.Data.EffectTypes.id("mining_fatigue")

    :ok =
      Valimc.TestConn.call(pid, fn state ->
        {:ok, _, next} =
          Valimc.Player.Vitals.apply_effect(state, fatigue, [{-1, 9, false, true, true}])

        {:reply, :ok, next}
      end)

    Client.send_packet(client, :play, "attack", Wire.varint(id))

    Valimc.TestWait.until(fn ->
      elem(body(owner, uuid), 1).body.mob.living.health.value < 20.0
    end)

    assert elem(body(owner, uuid), 1).body.mob.living.health.value > 18.0
    assert Process.alive?(pid)
    assert Valimc.Living.Melee.strength(1000, 0.0) == 0.0
  end

  test "punching a bullet sends native break feedback and leaves the connection alive", ctx do
    save(ctx, -90.0, Inventory.new())
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, bullet} = Body.new("minecraft:shulker_bullet")
    bullet = %{bullet | no_gravity: true}
    at = {ctx.pose.x + 2.0, 65.0, ctx.pose.z}
    uuid = <<860::128>>
    :ok = Region.drop_items(owner, [Store.body_record(bullet, uuid, at)])
    {id, _} = body(owner, uuid)
    {_entity, client} = Client.await(client, :play, "add_entity")
    Client.send_packet(client, :play, "attack", Wire.varint(id))

    {_, expected} =
      Valimc.Protocol.CombatPackets.sound(
        "minecraft:entity.shulker_bullet.hurt",
        "hostile",
        at,
        1.0,
        1.0,
        0
      )

    {sound, _} = Wire.take_varint(IO.iodata_to_binary(expected))

    {payload, client} =
      Enum.reduce_while(1..8, {nil, client}, fn _, {_, client} ->
        {payload, client} = Client.await(client, :play, "sound")
        {event, _} = Wire.take_varint(payload)
        if event == sound, do: {:halt, {payload, client}}, else: {:cont, {nil, client}}
      end)

    assert payload != nil

    assert binary_part(payload, 0, byte_size(payload) - 8) ==
             binary_part(IO.iodata_to_binary(expected), 0, byte_size(payload) - 8)

    {particles, _client} = Client.await(client, :play, "level_particles")

    {_, expected} =
      Valimc.Protocol.CombatPackets.particles("minecraft:crit", at, {0.2, 0.2, 0.2}, 0.0, 15)

    assert particles == IO.iodata_to_binary(expected)
    assert Process.alive?(pid)
    assert {:error, _} = Store.find(store(owner), uuid)
    assert {:error, :missing_item} = Region.hurt_entity(owner, uuid, %{amount: 1.0})
  end

  # A shulker's peek set in its section.
  defp peek(owner, uuid, peek) do
    Valimc.TestRegion.replace_section(owner, fn section ->
      {:ok, {_, id, _}} = Store.find(section.entities.store, uuid)
      %{native: ref} = section.entities.store.entries[id]
      {:ok, {_, events, {position, row}}} = Valimc.Native.mob_section_data(ref, id, :peek, peek)
      store = Store.native_change(section.entities.store, id, position, row, events)
      put_in(section.entities.store, store)
    end)
  end

  test "the hosted session follows an opening lid and closing does not pull it back", ctx do
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key),
      region_ticks: :manual,
      regionizer: false
    )

    TestPlayer.save(ctx, Map.put(ctx.pose, :y, 65.0), Inventory.new())
    {_client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    :ok = Valimc.TestScope.simulate(owner, ctx.key)
    {:ok, shell} = Body.new("minecraft:shulker")
    shell = %{shell | mob: %{shell.mob | no_ai: true}, data: %{shell.data | peek: 100}}
    uuid = <<850::128>>

    :ok =
      Region.drop_items(owner, [Store.body_record(shell, uuid, {ctx.pose.x, 64.0, ctx.pose.z})])

    {_, {_, dy, _}} =
      Valimc.Native.mob_oracle_body_opening(
        0,
        0.0,
        Valimc.Data.Float32.round(0.05),
        {ctx.pose.x, 64.0, ctx.pose.z}
      )

    assert {:ok, _} = Region.step(owner, 1)
    assert_in_delta TestPlayer.state(pid).player.y, 65.0 + dy, 1.0e-9

    # Its lid closes, in its section.
    peek(owner, uuid, 0)

    assert {:ok, _} = Region.step(owner, 1)
    assert_in_delta TestPlayer.state(pid).player.y, 65.0 + dy, 1.0e-9

    Valimc.TestConn.replace(pid, fn s ->
      %{
        s
        | player: %{
            s.player
            | game_mode: Valimc.Player.GameMode.new(:spectator),
              abilities: Valimc.Player.Abilities.for_mode(:spectator)
          }
      }
    end)

    peek(owner, uuid, 100)

    assert {:ok, _} = Region.step(owner, 1)
    assert_in_delta TestPlayer.state(pid).player.y, 65.0 + dy, 1.0e-9
  end

  test "attack reach includes the open shulker lid beyond its closed cube", ctx do
    save(ctx, 0.0, %Inventory{})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, base} = Body.new("minecraft:shulker")
    base = put_in(base.mob.no_ai, true)

    for {open, n} <- [{true, 41}, {false, 42}] do
      body = %{
        base
        | data: %{
            base.data
            | attach_face: 5,
              peek: if(open, do: 100, else: 0),
              peek_amount: if(open, do: 1.0, else: 0.0)
          }
      }

      :ok =
        Region.drop_items(owner, [
          Store.body_record(body, <<n::128>>, {ctx.pose.x + 7.2, 64.0, ctx.pose.z})
        ])
    end

    Valimc.TestWait.until(fn ->
      views = Valimc.World.bodies(:overworld)

      Enum.all?([<<41::128>>, <<42::128>>], fn uuid ->
        Enum.any?(views, &(elem(&1, 1).uuid == uuid))
      end)
    end)

    {open, _} = body(owner, <<41::128>>)
    {closed, _} = body(owner, <<42::128>>)
    TestPlayer.ticks(pid, 22)
    Client.send_packet(client, :play, "attack", Wire.varint(closed))
    _ = Client.barrier(client)
    assert elem(body(owner, <<42::128>>), 1).body.mob.living.health.value == 30.0
    Client.send_packet(client, :play, "attack", Wire.varint(open))

    Valimc.TestWait.until(fn ->
      elem(body(owner, <<41::128>>), 1).body.mob.living.health.value < 30.0
    end)
  end

  test "a guardian retaliates even when its hurt window refuses the next hit", ctx do
    save(ctx, 0.0, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new("minecraft:guardian")
    body = %{body | no_gravity: true, mob: %{body.mob | no_ai: true}}
    uuid = <<34::128>>
    record = Store.body_record(body, uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})
    :ok = Region.drop_items(owner, [record])

    # Its mind made in its section.
    Valimc.TestWait.until(fn ->
      case Store.find(store(owner), uuid) do
        {:ok, {_, id, _}} ->
          %{native: ref} = store(owner).entries[id]
          Valimc.Native.mob_section_oracle_mind(ref, id) != nil

        _ ->
          false
      end
    end)

    player = %{
      uuid: ctx.uuid,
      entity_id: 1,
      player: true,
      type: "minecraft:player",
      mainhand: nil
    }

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 1.0,
      attacker: player,
      direct: player,
      position: {ctx.pose.x, 64.0, ctx.pose.z}
    }

    assert {:ok, %{hurt: true, health: 29.0}} = Region.hurt_entity(owner, uuid, hit)
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 18.0 end)

    # Pin the two independent damage windows in this headless regression.
    Valimc.TestConn.replace(pid, &put_in(&1.player.living.health.cooldown, 0))

    Valimc.TestRegion.replace_section(owner, fn section ->
      {:ok, {_, id, _}} = Store.find(section.entities.store, uuid)
      store = Valimc.TestBodies.set(section.entities.store, id, {:cooldown, 20})
      put_in(section.entities.store, store)
    end)

    assert {:ok, %{hurt: false}} = Region.hurt_entity(owner, uuid, hit)
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 16.0 end)
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    assert Valimc.TestBodies.body(store(owner).entries[id]).mob.living.health.value == 29.0
  end

  test "pufferfish post-hit poison and sting follow damage admission, shields and immunity",
       ctx do
    save(ctx, -90.0, %Inventory{slots: %{45 => ItemStack.new("shield")}})
    {client, pid} = TestPlayer.login(ctx)
    poison = Valimc.Data.EffectTypes.id("poison")

    fish = %{
      uuid: <<32::128>>,
      entity_id: 999,
      player: false,
      type: "minecraft:pufferfish",
      mainhand: nil
    }

    hit = %{
      source: Valimc.Living.DamageSource.new(:mob_attack),
      amount: 3.0,
      attacker: fish,
      direct: fish,
      position: {ctx.pose.x + 2.0, 64.0, ctx.pose.z},
      taken_actions: [:puffer_sting, {:add, poison, [{120, 0, false, true, true}]}]
    }

    # A packet barrier from the actual session lets refused-hit assertions
    # account for every preceding sting without a timed socket poll.
    drain = fn client ->
      marker = <<12, 77.0::float-32>>

      Valimc.TestConn.replace(pid, fn s ->
        Valimc.Protocol.Codec.send_packets(s, [Packets.packet("game_event", marker)])
        s
      end)

      Enum.reduce_while(1..5000, {client, 0}, fn _, {client, count} ->
        {id, body, client} = Client.read(client)
        name = Valimc.Protocol.Data.name(:play, :clientbound, id)

        cond do
          name == "game_event" and body == marker -> {:halt, {client, count}}
          name == "game_event" and body == <<9, 0.0::float-32>> -> {:cont, {client, count + 1}}
          true -> {:cont, {Client.auto_reply(client, :play, name, body), count}}
        end
      end)
    end

    send(pid, {:hurt, hit})
    {client, 1} = drain.(client)
    assert TestPlayer.living(pid).health.value == 17.0
    assert Map.has_key?(TestPlayer.living(pid).effects, poison)

    # The same hit in the hurt window cannot restore poison after removal.
    Valimc.TestConn.replace(pid, &put_in(&1.player.living.effects, %{}))
    send(pid, {:hurt, hit})
    {client, 0} = drain.(client)
    assert TestPlayer.living(pid).effects == %{}
    assert TestPlayer.living(pid).health.value == 17.0

    Client.send_packet(client, :play, "use_item", [
      Wire.varint(1),
      Wire.varint(1),
      <<-90.0::float-32, 0.0::float-32>>
    ])

    Valimc.TestWait.until(fn -> match?(%{blocking: true}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 6)
    Valimc.TestConn.replace(pid, &put_in(&1.player.living.health.cooldown, 0))
    send(pid, {:hurt, hit})
    {client, 0} = drain.(client)
    assert TestPlayer.state(pid).inventory.slots[45].components["minecraft:damage"] == 4
    assert TestPlayer.living(pid).health.value == 17.0
    assert TestPlayer.living(pid).effects == %{}

    Valimc.TestConn.replace(pid, fn s ->
      s = put_in(s.player.abilities.invulnerable, true)
      %{s | active_use: nil}
    end)

    send(pid, {:hurt, hit})
    {client, 0} = drain.(client)
    assert TestPlayer.living(pid).effects == %{}

    Valimc.TestConn.replace(pid, fn s ->
      s = put_in(s.player.abilities.invulnerable, false)
      put_in(s.player.living.health, %{s.player.living.health | value: 0.5, cooldown: 0})
    end)

    send(pid, {:hurt, hit})
    {_client, 1} = drain.(client)
    assert TestPlayer.state(pid).life_stage == :dead
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
    # A contact hit has no prebuilt killer label (a pufferfish's sting).
    Valimc.TestConn.replace(pid, fn s ->
      health = %{s.player.living.health | value: 0.5, cooldown: 0}
      s = put_in(s.player.living.health, health)
      %{s | active_use: nil}
    end)

    fish = %{
      uuid: <<8::128>>,
      entity_id: 999,
      player: false,
      type: "minecraft:pufferfish",
      mainhand: nil
    }

    send(
      pid,
      {:hurt,
       %{
         source: Valimc.Living.DamageSource.new(:mob_attack),
         amount: 6.0,
         attacker: fish,
         direct: fish
       }}
    )

    {death, client} = Client.await(client, :play, "player_combat_kill")
    assert :binary.match(death, "entity.minecraft.pufferfish") != :nomatch
    _ = Client.barrier(client)
    assert TestPlayer.living(pid).health.value == 0.0
  end

  test "a Fire Aspect sword sets a zombie alight; Thorns hurts the zombie hitting back (VMC-037q)",
       ctx do
    sword = %{
      ItemStack.new("diamond_sword")
      | components: %{"minecraft:enchantments" => %{"minecraft:fire_aspect" => 2}}
    }

    # Thorns past its maximum level always answers (a chance of 1.5).
    chestplate = %{
      ItemStack.new("iron_chestplate")
      | components: %{"minecraft:enchantments" => %{"minecraft:thorns" => 10}}
    }

    save(ctx, -90.0, %Inventory{slots: %{36 => sword, 6 => chestplate}})
    {client, pid} = TestPlayer.login(ctx)
    uuid = <<9::128>>
    owner = summon(ctx, uuid)
    {id, _} = body(owner, uuid)
    {_, client} = Client.await(client, :play, "add_entity")

    TestPlayer.ticks(pid, 14)
    Client.send_packet(client, :play, "attack", Wire.varint(id))

    # Fire Aspect II: eight seconds.
    Valimc.TestWait.until(fn -> elem(body(owner, uuid), 1).body.mob.living.fire_ticks == 160 end)
    health = elem(body(owner, uuid), 1).body.mob.living.health.value

    Valimc.TestWait.until(fn ->
      elem(body(owner, uuid), 1).body.mob.living.health.cooldown <= 0
    end)

    Valimc.TestRegion.replace_section(owner, fn section ->
      :ok = RegionData.mob_attack(section, uuid, ctx.uuid)
      section
    end)

    # The zombie takes 1 to 5 thorns damage; the chestplate wears by 2 and
    # by the zombie's hit.
    Valimc.TestWait.until(fn ->
      elem(body(owner, uuid), 1).body.mob.living.health.value < health
    end)

    assert TestPlayer.state(pid).inventory.slots[6].components["minecraft:damage"] >= 2
    _ = client
  end
end
