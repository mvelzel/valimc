defmodule Valimc.ProjectileTest do
  @moduledoc """
  Projectiles (VMC-037o): what each kind's hit does (`World.Projectiles`),
  splash potions and the dragon's breath cloud, and projectiles flying in a
  section: an arrow that hurts a zombie and one that sticks in stone, a
  mob's shot, and a ghast's fireball blowing its crater.
  """
  use ExUnit.Case, async: true
  alias Valimc.Commands.Source
  alias Valimc.Entity.{Body, EffectCloud, Projectile, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Projectiles, Region}

  @owner %{uuid: <<9::128>>, id: 900, player: true}
  @context %{mob_griefing: true}

  defp entry(body, position \\ {0.5, 65.0, 0.5}) do
    {x, y, z} = position
    %{entity: %{x: x, y: y, z: z, uuid: <<4::128>>, entity_id: 40}, body: body, revision: 1}
  end

  # A kernel result moving `body` to `position` with `hit`.
  defp result(body, position, hit),
    do:
      {:ok, {position, body.velocity, {body.yaw, body.pitch}, 1, {false, false, true}, -1}, hit,
       {0.0, 0.0}, false}

  defp zombie_target,
    do: %{
      ref: {:mob, 7},
      uuid: <<7::128>>,
      type: "minecraft:zombie",
      position: {5.5, 64.0, 0.5},
      box: {5.2, 64.0, 0.2, 5.8, 65.95, 0.8}
    }

  test "an arrow hits for ceil(speed × damage); a hit that does not take bounces it back" do
    arrow = %{Projectile.new("minecraft:arrow", @owner) | velocity: {3.0, 0.0, 0.0}}
    hit = {:entities, [{70, {5.2, 65.0, 0.5}}]}

    plan =
      Projectiles.plan(
        entry(arrow),
        result(arrow, {5.2, 65.0, 0.5}, hit),
        %{70 => zombie_target()},
        @context
      )

    assert {:hurt, %{ref: {:mob, 7}}, hit, next} = plan
    assert hit.amount == 6.0 and hit.direct.entity_id == 40 and hit.attacker.entity_id == 900
    assert hit.direction == {-3.0, -0.0}
    assert {:remove, [{:sound, "minecraft:entity.arrow.hit", _, _, 1.0, _}]} = next.(true)

    # Reversed at a tenth of its speed, then drag and gravity.
    assert {:keep, bounced, {5.2, 65.0, 0.5}, []} = next.(false)
    {vx, vy, _} = bounced.velocity
    assert_in_delta vx, -0.3 * 0.99, 1.0e-6
    assert_in_delta vy, -0.05, 1.0e-9
    assert bounced.yaw >= 170.0 and bounced.data.impulse == 1
  end

  test "a stuck arrow sticks with its sound and despawns after 1200 ticks" do
    arrow = Projectile.new("minecraft:arrow", @owner)
    block = {:block, {3.0, 64.0, 0.5}, 4, {3, 64, 0}, false, false}

    {:keep, stuck, _, [sound]} =
      Projectiles.plan(entry(arrow), result(arrow, {2.95, 64.0, 0.5}, block), %{}, @context)

    assert {:sound, "minecraft:entity.arrow.hit", "neutral", _, 1.0, _} = sound
    assert stuck.data.shake == 7

    stuck = %{stuck | data: %{stuck.data | in_ground: true, life: 1198}}

    still =
      {:ok, {{2.95, 64.0, 0.5}, {0.0, 0.0, 0.0}, {0.0, 0.0}, 9, {false, true, true}, 1}, nil,
       {0.0, 0.0}, false}

    assert {:keep, %{data: %{life: 1199}}, _, []} =
             Projectiles.plan(entry(stuck), still, %{}, @context)

    old = %{stuck | data: %{stuck.data | life: 1199}}
    assert {:remove, []} = Projectiles.plan(entry(old), still, %{}, @context)
  end

  test "thrown items: a snowball breaks, eggs hatch chicks, a pearl calls its owner" do
    at = {3.0, 64.0, 0.5}
    block = {:block, at, 1, {3, 63, 0}, false, false}
    snowball = Projectile.new("minecraft:snowball", @owner)

    assert {:remove, [{:event, 3, ^at}]} =
             Projectiles.plan(entry(snowball), result(snowball, at, block), %{}, @context)

    :rand.seed(:exsss, {1, 2, 3})
    egg = Projectile.new("minecraft:egg", @owner)

    chicks =
      for _ <- 1..400,
          {:remove, effects} = Projectiles.plan(entry(egg), result(egg, at, block), %{}, @context),
          {:spawn, record} <- effects,
          do: record

    # One egg in eight hatches, one hatching in 32 gives four.
    assert length(chicks) in 30..80
    assert Enum.all?(chicks, &(&1.type == "minecraft:chicken" and &1.data.age == -24_000))

    pearl = Projectile.new("minecraft:ender_pearl", @owner)
    old = {0.5, 65.0, 0.5}
    uuid = @owner.uuid

    assert {:remove, [{:player, ^uuid, {:ender_pearl, ^old}}]} =
             Projectiles.plan(entry(pearl, old), result(pearl, at, block), %{}, @context)
  end

  test "fireballs: a small one lights the block it hits, a large one explodes, the dragon's breathes" do
    small = Projectile.new("minecraft:small_fireball", nil)
    # The top face (1) of the cell below: fire goes above it.
    block = {:block, {3.0, 64.0, 0.5}, 1, {3, 63, 0}, false, false}

    assert {:remove, [{:fire, {3, 64, 0}}]} =
             Projectiles.plan(entry(small), result(small, {3.0, 64.0, 0.5}, block), %{}, @context)

    ghast = %{uuid: <<8::128>>, id: 800, player: false, type: "minecraft:ghast"}
    large = Projectile.new("minecraft:fireball", ghast)

    assert {:hurt, _, %{amount: 6.0, source: source}, next} =
             Projectiles.plan(
               entry(large),
               result(large, {5.2, 65.0, 0.5}, {:entity, 70, {5.2, 65.0, 0.5}}),
               %{70 => zombie_target()},
               @context
             )

    assert Valimc.Living.DamageSource.type(source) == :fireball
    assert {:remove, [{:explode, explosion}]} = next.(true)
    assert explosion.radius == 1.0 and explosion.fire and explosion.interacts

    dragon = Projectile.new("minecraft:dragon_fireball", nil)

    {:remove, [{:cloud, record}, {:level_event, _, 2006, 1}]} =
      Projectiles.plan(entry(dragon), result(dragon, {3.0, 64.0, 0.5}, block), %{}, @context)

    assert record.type == "minecraft:area_effect_cloud" and record.data.radius == 3.0
  end

  test "an eye of ender heads for its stronghold, or 12 blocks toward it and 8 up (VMC-026d)" do
    eye = Projectile.new("minecraft:eye_of_ender", nil)
    near = Projectile.signal_to(eye, {0.5, 70.0, 0.5}, {6.5, 0.0, 8.5})
    assert near.data.target == {6.5, 0.0, 8.5} and near.data.life == 0

    # 300 east and 400 south: 12 blocks along (0.6, 0.8).
    far = Projectile.signal_to(eye, {0.0, 70.0, 0.0}, {300.0, 0.0, 400.0})
    {tx, 78.0, tz} = far.data.target
    assert_in_delta tx, 7.2, 1.0e-12
    assert_in_delta tz, 9.6, 1.0e-12
  end

  test "an eye of ender drops or shatters after 80 ticks" do
    eye = Projectile.new("minecraft:eye_of_ender", nil)
    eye = %{eye | data: %{eye.data | life: 80, survive: false}}

    flight =
      {:ok, {{3.0, 70.0, 0.5}, {0.1, 0.0, 0.0}, {0.0, 0.0}, 81, {false, false, true}, -1}, nil,
       {0.0, 0.0}, false}

    assert {:remove,
            [
              {:sound, "minecraft:entity.ender_eye.death", _, _, _, _},
              {:level_event, {3, 70, 0}, 2003, 0}
            ]} = Projectiles.plan(entry(eye), flight, %{}, @context)

    eye = %{eye | data: %{eye.data | survive: true}}

    assert {:remove, [_, {:spawn, %{stack: %ItemStack{}}}]} =
             Projectiles.plan(entry(eye), flight, %{}, @context)
  end

  test "a splash potion's effects fall off with distance; undead are healed by harming" do
    harming = %{
      ItemStack.new("splash_potion")
      | components: %{
          "minecraft:potion_contents" => %{
            Valimc.Protocol.PotionContents.empty()
            | potion: Valimc.Data.PotionTypes.id("harming")
          }
        }
    }

    potion = Projectile.new("minecraft:splash_potion", @owner, harming)

    player = %{
      ref: {:player, <<1::128>>},
      type: "minecraft:player",
      box: {0.7, 64.0, 0.7, 1.3, 65.8, 1.3}
    }

    far = %{player | ref: {:player, <<2::128>>}, box: {5.7, 64.0, 0.7, 6.3, 65.8, 1.3}}
    zombie = %{zombie_target() | box: {1.7, 64.0, 0.2, 2.3, 65.95, 0.8}}

    {hits, [{:level_event, _, 2007, _}]} =
      Projectiles.splash(potion, {1.0, 64.0, 1.0}, [player, far, zombie], 10)

    by = Map.new(hits, fn {t, actions} -> {t.ref, actions} end)
    # Instant Damage I at the potion: 6; undead heal 4 scaled.
    assert [{:hurt, :indirect_magic, 6.0}] = by[{:player, <<1::128>>}]
    assert [{:heal, heal}] = by[{:mob, 7}]
    # Scaled by its distance, rounded: 4 * 0.86 + 0.5.
    assert heal == 4.0
    refute Map.has_key?(by, {:player, <<2::128>>})
  end

  test "the dragon's breath waits, then hurts each living entity in it every 20 ticks" do
    cloud = EffectCloud.dragon_breath(nil)

    target = %{
      ref: {:player, <<1::128>>},
      uuid: <<1::128>>,
      type: "minecraft:player",
      position: {1.0, 64.0, 0.5},
      box: {0.7, 64.0, 0.2, 1.3, 65.8, 0.8}
    }

    zombie = %{
      zombie_target()
      | position: {2.0, 64.0, 0.5},
        box: {1.7, 64.0, 0.2, 2.3, 65.95, 0.8}
    }

    {cloud, events} =
      Enum.reduce(1..45, {cloud, []}, fn _, {c, events} ->
        {:keep, c, effects} = EffectCloud.tick(c, {0.5, 64.0, 0.5}, [target, zombie])
        {c, events ++ Enum.map(effects, &{c.data.age, &1})}
      end)

    assert [
             {20, {:hurt, _, 6.0}},
             {20, {:heal, _, 4.0}},
             {40, {:hurt, _, 6.0}},
             {40, {:heal, _, 4.0}}
           ] = events

    assert cloud.data.radius > 3.0 and not cloud.data.waiting
  end

  describe "in a section" do
    # x -533760..-533633, z 1152..1279.
    @key {-4170, 9}
    @x -533_700
    @y 80
    @z 1200

    setup do
      Valimc.TestScope.isolate([@key], item_simulation: true)
      {:ok, owner} = Valimc.TestWorld.owner(@key)
      :ok = Valimc.TestScope.simulate(owner, @key)

      on_exit(fn ->
        for {pid, _} <- Valimc.TestWorld.registered(@key), do: Valimc.TestScope.kill(pid)
      end)

      run("fill #{@x - 8} #{@y - 1} #{@z - 8} #{@x + 12} #{@y - 1} #{@z + 8} stone")
      %{owner: owner}
    end

    defp run(input) do
      source = %{Source.rcon() | dimension: :overworld, position: {@x + 0.5, @y * 1.0, @z + 0.5}}
      Valimc.Commands.run(source, input)
      Source.collect(source)
    end

    defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

    defp find(owner, uuid) do
      case Store.find(store(owner), uuid) do
        {:ok, {_, id, _}} -> store(owner).entries[id]
        _ -> nil
      end
    end

    defp shoot(owner, uuid, type, position, velocity, owner_info \\ @owner) do
      body = %{Projectile.new(type, owner_info) | velocity: velocity}
      :ok = Region.drop_items(owner, [Store.body_record(body, uuid, position)])
    end

    defp zombie(owner, uuid, position) do
      {:ok, body} = Body.new("minecraft:zombie")
      :ok = Region.drop_items(owner, [Store.body_record(body, uuid, position)])
    end

    test "an arrow hurts the zombie it hits and another sticks in the stone", %{owner: owner} do
      zombie(owner, <<1::128>>, {@x + 6.5, @y * 1.0, @z + 0.5})

      shoot(
        owner,
        <<2::128>>,
        "minecraft:arrow",
        {@x + 0.5, @y + 1.0, @z + 0.5},
        {2.5, 0.05, 0.0}
      )

      shoot(
        owner,
        <<3::128>>,
        "minecraft:arrow",
        {@x - 3.5, @y + 3.0, @z + 0.5},
        {0.0, -1.5, 0.0}
      )

      Valimc.TestWait.until(fn ->
        find(owner, <<2::128>>) == nil and
          find(owner, <<1::128>>).body.mob.living.health.value < 20.0
      end)

      Valimc.TestWait.until(fn ->
        match?(%{body: %{data: %{in_ground: true}}}, find(owner, <<3::128>>))
      end)

      stuck = find(owner, <<3::128>>)
      assert_in_delta stuck.entity.y, @y + 0.05, 1.0e-6
      assert stuck.body.velocity == {0.0, 0.0, 0.0}
    end

    test "a mob shoots an arrow at a target", %{owner: owner} do
      zombie(owner, <<5::128>>, {@x + 0.5, @y * 1.0, @z + 0.5})
      zombie(owner, <<6::128>>, {@x + 8.5, @y * 1.0, @z + 0.5})
      Valimc.TestWait.until(fn -> find(owner, <<6::128>>) != nil end)

      # The spread at this difficulty may miss: shoot until one lands.
      shot = fn ->
        Valimc.TestRegion.replace_section(owner, fn section ->
          target = {@x + 8.5, @y * 1.0, @z + 0.5, 1.95}
          {:ok, section} = Valimc.World.RegionData.mob_shoot(section, <<5::128>>, target)
          section
        end)

        arrows = for {_, %{body: %{type: "minecraft:arrow"} = b}} <- store(owner).entries, do: b

        assert Enum.any?(
                 arrows,
                 &(&1.data.owner.uuid == <<5::128>> and &1.data.pickup == :disallowed)
               )

        Process.sleep(500)
        find(owner, <<6::128>>).body.mob.living.health.value < 20.0
      end

      assert Enum.any?(1..8, fn _ -> shot.() end)
    end

    test "a ghast's fireball blows a crater where it lands", %{owner: owner} do
      # A radius 1 explosion breaks dirt, not stone.
      run("setblock #{@x} #{@y - 1} #{@z} dirt")
      ghast = %{uuid: <<8::128>>, id: 800, player: false, type: "minecraft:ghast"}

      shoot(
        owner,
        <<7::128>>,
        "minecraft:fireball",
        {@x + 0.5, @y + 2.0, @z + 0.5},
        {0.0, -0.1, 0.0},
        ghast
      )

      Valimc.TestWait.until(fn ->
        Valimc.TestBlocks.get({@x, @y - 1, @z}) == Valimc.Data.Blocks.default_state("air")
      end)
    end
  end
end
