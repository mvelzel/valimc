defmodule Valimc.ProjectileConnectionTest do
  @moduledoc """
  Projectiles through a connection (VMC-037o): a fully drawn bow's arrow
  hurts a zombie, a mob's arrow (`mob_shoot`, VMC-043b's skeletons) hurts
  the player, and an ender pearl landing in another group brings its
  thrower there with the pearl's damage.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000

  alias Valimc.Commands.Source
  alias Valimc.Entity.{Body, Projectile, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Food
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.{Region, RegionData}

  setup do
    ctx = TestPlayer.scope("Projectile", {151_000, 993}, survival: {2, false})
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key), item_simulation: true)
    ctx
  end

  defp save(ctx, inventory) do
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
      yaw: -90.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Food{}
    }

    TestPlayer.save(ctx, player, inventory)
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp health(owner, uuid) do
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    Valimc.TestBodies.body(store(owner).entries[id]).mob.living.health.value
  end

  test "a drawn bow's arrow hurts a zombie, and a mob's arrow hurts the player", ctx do
    bow = ItemStack.new("bow")
    save(ctx, %Inventory{slots: %{36 => bow, 9 => ItemStack.new("arrow", 16)}})
    {client, pid} = TestPlayer.login(ctx)

    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, zombie} = Body.new("minecraft:zombie")
    uuid = <<6::128>>
    position = {ctx.pose.x + 6.0, 64.0, ctx.pose.z}
    :ok = Region.drop_items(owner, [Store.body_record(%{zombie | yaw: 90.0}, uuid, position)])
    {_, client} = Client.await(client, :play, "add_entity")

    # Drawn for a full second (facing east, at the zombie's middle), then released.
    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 8.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :bow}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 21)

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)
    Valimc.TestWait.until(fn -> health(owner, uuid) < 20.0 end)

    state = TestPlayer.state(pid)
    assert state.inventory.slots[9].count == 15
    assert state.inventory.slots[36].components["minecraft:damage"] == 1

    # The zombie shoots back (as a skeleton's ranged goal will) until one lands.
    target = {ctx.pose.x, 64.0, ctx.pose.z, 1.8}

    assert Enum.any?(1..8, fn _ ->
             Valimc.TestRegion.replace_section(owner, fn section ->
               {:ok, section} = RegionData.mob_shoot(section, uuid, target)
               section
             end)

             Process.sleep(500)
             TestPlayer.living(pid).health.value < 20.0
           end)
  end

  test "a crossbow charges and shoots its arrow; a snowball is thrown", ctx do
    inventory = %Inventory{
      slots: %{
        36 => ItemStack.new("crossbow"),
        37 => ItemStack.new("snowball", 4),
        9 => ItemStack.new("arrow", 2)
      }
    }

    save(ctx, inventory)
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)

    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 0.0::float-32>>])

    # 25 ticks of charge load an arrow into the crossbow.
    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :crossbow}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 27)

    Valimc.TestWait.until(fn ->
      match?(
        [%ItemStack{}],
        TestPlayer.state(pid).inventory.slots[36].components["minecraft:charged_projectiles"]
      )
    end)

    assert TestPlayer.state(pid).inventory.slots[9].count == 1

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)
    Client.send_packet(client, :play, "use_item", use)

    arrows = fn ->
      for {_, %{body: %Body{type: "minecraft:arrow"} = body}} <- store(owner).entries, do: body
    end

    Valimc.TestWait.until(fn -> arrows.() != [] end)
    [arrow] = arrows.()
    assert arrow.data.crit and arrow.data.sound == "minecraft:item.crossbow.hit"

    assert TestPlayer.state(pid).inventory.slots[36].components["minecraft:charged_projectiles"] ==
             []

    # The snowball in the next slot.
    Client.send_packet(client, :play, "set_carried_item", <<1::16>>)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.selected == 1 end)
    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.slots[37].count == 3 end)
  end

  test "a Multishot, Quick Charge III crossbow loads three arrows from one in ten ticks (VMC-037q)",
       ctx do
    crossbow = %{
      ItemStack.new("crossbow")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:multishot" => 1, "minecraft:quick_charge" => 3}
        }
    }

    save(ctx, %Inventory{slots: %{36 => crossbow, 9 => ItemStack.new("arrow", 2)}})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)

    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 0.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :crossbow}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 11)

    loaded = fn ->
      TestPlayer.state(pid).inventory.slots[36].components["minecraft:charged_projectiles"]
    end

    Valimc.TestWait.until(fn -> match?([_, _, _], loaded.()) end)
    [first, second, third] = loaded.()
    refute Map.has_key?(first.components, "minecraft:intangible_projectile")
    assert Map.has_key?(second.components, "minecraft:intangible_projectile")
    assert Map.has_key?(third.components, "minecraft:intangible_projectile")
    assert TestPlayer.state(pid).inventory.slots[9].count == 1

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)
    Client.send_packet(client, :play, "use_item", use)

    arrows = fn ->
      for {_, %{body: %Body{type: "minecraft:arrow"} = body}} <- store(owner).entries, do: body
    end

    Valimc.TestWait.until(fn -> length(arrows.()) == 3 end)
    # Three shots wear the crossbow by three.
    assert TestPlayer.state(pid).inventory.slots[36].components["minecraft:damage"] == 3
    _ = client
  end

  test "an Infinity, Flame, Power V bow keeps its arrow and shoots it burning (VMC-037q)", ctx do
    bow = %{
      ItemStack.new("bow")
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:infinity" => 1,
            "minecraft:flame" => 1,
            "minecraft:power" => 5
          }
        }
    }

    save(ctx, %Inventory{slots: %{36 => bow, 9 => ItemStack.new("arrow", 1)}})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)

    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 0.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :bow}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 21)

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)

    arrows = fn ->
      for {_, %{body: %Body{type: "minecraft:arrow"} = body}} <- store(owner).entries, do: body
    end

    Valimc.TestWait.until(fn -> arrows.() != [] end)
    [arrow] = arrows.()
    assert Projectile.burning?(arrow)
    assert arrow.data.pickup == :creative_only
    assert arrow.data.weapon.components["minecraft:enchantments"]["minecraft:power"] == 5
    assert TestPlayer.state(pid).inventory.slots[9].count == 1
    _ = client
  end

  test "a Loyalty trident thrown at the ground comes back to its thrower (VMC-037q)", ctx do
    trident = %{
      ItemStack.new("trident")
      | components: %{"minecraft:enchantments" => %{"minecraft:loyalty" => 3}}
    }

    save(ctx, %Inventory{slots: %{36 => trident}})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)

    # Raised for half a second, looking almost straight down, then thrown.
    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 80.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :trident}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 11)

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)

    tridents = fn ->
      for {_, %{body: %Body{type: "minecraft:trident"} = body}} <- store(owner).entries, do: body
    end

    Valimc.TestWait.until(fn -> tridents.() != [] end)
    [thrown] = tridents.()
    assert thrown.data.loyalty == 3
    assert TestPlayer.state(pid).inventory.slots[36] == nil

    # Stuck, it turns back after four ticks and its thrower takes it.
    Valimc.TestWait.until(fn -> match?(%{}, TestPlayer.state(pid).inventory.slots[36]) end, 20_000)
    returned = TestPlayer.state(pid).inventory.slots[36]
    assert returned.components["minecraft:damage"] == 1
    assert tridents.() == []
    _ = client
  end

  test "an arrow shot into the ground is picked up again", ctx do
    save(ctx, %Inventory{slots: %{36 => ItemStack.new("bow"), 9 => ItemStack.new("arrow", 2)}})
    {client, pid} = TestPlayer.login(ctx)

    # Drawn fully, looking a little ahead of the feet.
    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 80.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> match?(%{kind: :bow}, TestPlayer.state(pid).active_use) end)
    TestPlayer.ticks(pid, 21)

    release =
      IO.iodata_to_binary([
        Wire.varint(ItemTypes.action_id("release_use_item")),
        Wire.position({0, 0, 0}),
        <<0>>,
        Wire.varint(2)
      ])

    Client.send_packet(client, :play, "player_action", release)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.slots[9].count == 1 end)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.slots[9].count == 2 end)
  end

  test "a thrown ender pearl brings its thrower where it lands", ctx do
    save(ctx, %Inventory{slots: %{36 => ItemStack.new("ender_pearl", 2)}})
    {client, pid} = TestPlayer.login(ctx)
    start = TestPlayer.state(pid).player

    # Facing east and down: it lands a few blocks away on the floor.
    use =
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(1), <<-90.0::float-32, 40.0::float-32>>])

    Client.send_packet(client, :play, "use_item", use)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.slots[36].count == 1 end)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).player.x - start.x > 1.0 end)
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 15.0 end)
  end

  test "an ender pearl landing in another group brings its thrower there", ctx do
    save(ctx, %Inventory{slots: %{}})
    {_client, pid} = TestPlayer.login(ctx)
    {rx, rz} = ctx.key
    far = {rx + 2, rz}
    Valimc.TestScope.isolate([far], item_simulation: true)

    on_exit(fn ->
      # The destination now hosts the player and its view's neighbours.
      Valimc.TestScope.stop_players(ctx.base)
      Valimc.TestScope.stop_neighbourhood(far)
    end)

    {:ok, there} = Valimc.TestWorld.owner(far)
    :ok = Valimc.TestScope.simulate(there, far)
    refute elem(there, 0) == elem(elem(Valimc.TestWorld.owner(ctx.key), 1), 0)

    {x, z} = {(rx + 2) * 128 + 20.5, rz * 128 + 20.5}
    source = %{Source.rcon() | dimension: :overworld, position: {x, 64.0, z}}

    Valimc.Commands.run(
      source,
      "fill #{floor(x) - 2} 63 #{floor(z) - 2} #{floor(x) + 2} 63 #{floor(z) + 2} stone"
    )

    Source.collect(source)

    me = TestPlayer.state(pid).player

    pearl = %{
      Projectile.new("minecraft:ender_pearl", %{uuid: ctx.uuid, id: me.entity_id, player: true})
      | velocity: {0.0, -0.5, 0.0}
    }

    :ok = Region.drop_items(there, [Store.body_record(pearl, <<7::128>>, {x, 66.0, z})])

    Valimc.TestWait.until(fn ->
      player = TestPlayer.state(pid).player
      abs(player.x - x) < 1.0 and abs(player.z - z) < 1.0
    end)

    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 15.0 end)
    # The group of the section it landed in hosts the player now.
    # The group owning the section it landed in hosts the player (the groups
    # may since have merged, the player's view now reaching both).
    Valimc.TestWait.until(fn ->
      {:ok, {group, _}} = Valimc.TestWorld.owner(far)
      Valimc.Player.Storage.host(ctx.uuid) == group
    end)
  end
end
