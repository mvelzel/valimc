defmodule Valimc.MobAiConnectionTest do
  @moduledoc """
  Mob AI live in a group (VMC-041a): a summoned zombie targets a survival
  player, walks to it and hits it; a pig follows a player holding a carrot,
  and panics when the player hits it. A blaze (VMC-043d) sets the player on
  fire with its fireballs; zombified piglins leave the player alone until it
  hits one, then all turn on it; a piglin leaves a player in a golden
  helmet alone until it hits it. A magma cube hurts the player it touches
  and splits in halves when it dies. A hoglin charges the player, hits and
  throws it.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000

  alias Valimc.Entity.{Body, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Food
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestPlayer
  alias Valimc.World.Region

  setup do
    ctx = TestPlayer.scope("MobAi", {146_000, 997}, survival: {2, false})
    # Mobs think where entities simulate.
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
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Food{}
    }

    TestPlayer.save(ctx, player, inventory)
  end

  defp summon(ctx, type, uuid, dx, equipment \\ %{}) do
    {:ok, body} = Body.new(type)
    body = %{body | mob: %{body.mob | equipment: Map.merge(body.mob.equipment, equipment)}}
    summon_body(ctx, body, uuid, dx)
  end

  defp summon_body(ctx, body, uuid, dx) do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    record = Store.body_record(body, uuid, {ctx.pose.x + dx, 64.0, ctx.pose.z})
    :ok = Region.drop_items(owner, [record])
    Valimc.TestWait.until(fn -> match?({:ok, _}, Store.find(store(owner), uuid)) end)
    owner
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp entry(owner, uuid) do
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    store(owner).entries[id]
  end

  defp distance(owner, uuid, ctx) do
    e = entry(owner, uuid).entity
    :math.sqrt((e.x - ctx.pose.x) ** 2 + (e.z - ctx.pose.z) ** 2)
  end

  defp running?(owner, uuid, module) do
    case entry(owner, uuid).body.mob.ai do
      %Valimc.AI.Mind{goals: goals} ->
        Enum.any?(Tuple.to_list(goals), &(&1.running and &1.module == module))

      _ ->
        false
    end
  end

  test "a zombie targets the player, walks to it and hits it", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    uuid = <<11::128>>
    owner = summon(ctx, "minecraft:zombie", uuid, 6.0)

    # Hit at normal difficulty: a zombie's 3.
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 17.0 end, 30_000)
    assert entry(owner, uuid).body.mob.ai.target == {:player, ctx.uuid}
    assert distance(owner, uuid, ctx) < 2.0
  end

  test "a pig follows a player holding a carrot and panics when hit", ctx do
    save(ctx, %Inventory{slots: %{36 => ItemStack.new("carrot")}})
    {_client, _pid} = TestPlayer.login(ctx)
    uuid = <<12::128>>
    owner = summon(ctx, "minecraft:pig", uuid, 6.0)

    # Tempted, it stops within its 2.5 blocks.
    Valimc.TestWait.until(fn -> distance(owner, uuid, ctx) < 3.0 end, 30_000)
    assert running?(owner, uuid, Valimc.AI.Goals.Tempt)

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 1.0,
      attacker: %{
        uuid: ctx.uuid,
        entity_id: 1,
        player: true,
        type: "minecraft:player",
        mainhand: nil
      },
      position: {ctx.pose.x, 64.0, ctx.pose.z}
    }

    {:ok, _} = Region.hurt_entity(owner, uuid, hit)
    Valimc.TestWait.until(fn -> running?(owner, uuid, Valimc.AI.Goals.Panic) end, 10_000)
  end

  test "a blaze's fireballs set the player on fire", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    uuid = <<13::128>>
    owner = summon(ctx, "minecraft:blaze", uuid, 8.0)

    # Charged for three seconds, then three small fireballs: 5 each, and fire.
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).fire_ticks > 0 end, 30_000)
    assert TestPlayer.living(pid).health.value < 20.0
    assert entry(owner, uuid).body.mob.ai.target == {:player, ctx.uuid}
  end

  test "zombified piglins turn on the player who hits one of them", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    [a, b] = [<<14::128>>, <<15::128>>]
    owner = summon(ctx, "minecraft:zombified_piglin", a, 5.0)
    summon(ctx, "minecraft:zombified_piglin", b, -5.0)
    Valimc.TestWait.until(fn -> entry(owner, b).body.mob.ai != nil end, 10_000)
    assert entry(owner, a).body.mob.ai.target == nil

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 1.0,
      attacker: %{
        uuid: ctx.uuid,
        entity_id: 1,
        player: true,
        type: "minecraft:player",
        mainhand: nil
      },
      position: {ctx.pose.x, 64.0, ctx.pose.z}
    }

    {:ok, _} = Region.hurt_entity(owner, a, hit)

    # Both angry; a zombified piglin's 5 lands.
    Valimc.TestWait.until(
      fn -> entry(owner, b).body.mob.ai.target == {:player, ctx.uuid} end,
      10_000
    )

    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value <= 15.0 end, 30_000)
  end

  test "a piglin spares a player in gold until the player hits it", ctx do
    save(ctx, %Inventory{slots: %{5 => ItemStack.new("golden_helmet")}})
    {_client, pid} = TestPlayer.login(ctx)
    uuid = <<16::128>>
    sword = %{mainhand: ItemStack.new("golden_sword")}
    owner = summon(ctx, "minecraft:piglin", uuid, 4.0, sword)

    # Gold on its head: twenty ticks of sensing, and no target.
    Valimc.TestWait.until(fn -> entry(owner, uuid).body.mob.ai != nil end, 10_000)
    Process.sleep(1_500)
    assert entry(owner, uuid).body.mob.ai.target == nil
    assert TestPlayer.living(pid).health.value == 20.0

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 1.0,
      attacker: %{
        uuid: ctx.uuid,
        entity_id: 1,
        player: true,
        type: "minecraft:player",
        mainhand: nil
      },
      position: {ctx.pose.x, 64.0, ctx.pose.z}
    }

    {:ok, _} = Region.hurt_entity(owner, uuid, hit)

    Valimc.TestWait.until(
      fn -> entry(owner, uuid).body.mob.ai.target == {:player, ctx.uuid} end,
      10_000
    )

    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value < 20.0 end, 30_000)
  end

  test "a live pufferfish contact cannot reapply poison during a refused repeat", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    poison = Valimc.Data.EffectTypes.id("poison")
    {:ok, body} = Body.new("minecraft:pufferfish")

    body = %{
      body
      | no_gravity: true,
        data: %{body.data | puff: 2},
        mob: %{body.mob | no_ai: true}
    }

    owner = summon_body(ctx, body, <<31::128>>, 1.0)
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value == 17.0 end)
    assert Map.has_key?(TestPlayer.living(pid).effects, poison)
    Valimc.TestConn.replace(pid, &put_in(&1.player.living.effects, %{}))
    before = Valimc.TestRegion.section(owner).game_tick
    Valimc.TestWait.until(fn -> Valimc.TestRegion.section(owner).game_tick >= before + 3 end)
    assert TestPlayer.living(pid).health.value == 17.0
    assert TestPlayer.living(pid).effects == %{}
  end

  test "a magma cube hurts the player it touches and splits when it dies", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    uuid = <<18::128>>
    {:ok, body} = Body.new("minecraft:magma_cube")
    {mob, data} = Valimc.AI.Mobs.MagmaCube.set_size(body.mob, body.data, 2)
    owner = summon_body(ctx, %{body | mob: mob, data: data}, uuid, 3.0)

    # Its size and two: 4 at normal difficulty.
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value <= 16.0 end, 30_000)

    hit = %{
      source: Valimc.Living.DamageSource.new(:player_attack),
      amount: 100.0,
      attacker: %{
        uuid: ctx.uuid,
        entity_id: 1,
        player: true,
        type: "minecraft:player",
        mainhand: nil
      },
      position: {ctx.pose.x, 64.0, ctx.pose.z}
    }

    {:ok, _} = Region.hurt_entity(owner, uuid, hit)

    # Removed after its death animation, it leaves two to four of size one.
    Valimc.TestWait.until(
      fn ->
        cubes =
          for {_, %{body: %Body{type: "minecraft:magma_cube"} = b}} <- store(owner).entries,
              do: b.data.size

        match?({:error, _}, Store.find(store(owner), uuid)) and length(cubes) in 2..4 and
          Enum.all?(cubes, &(&1 == 1))
      end,
      10_000
    )
  end

  test "a hoglin charges the player and hits it", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    uuid = <<19::128>>
    owner = summon(ctx, "minecraft:hoglin", uuid, 5.0)

    # Half its 6 and up to 5 more at normal difficulty, then a throw.
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value <= 17.0 end, 30_000)
    assert entry(owner, uuid).body.mob.ai.target == {:player, ctx.uuid}
  end

  test "a ghast charges and its fireball hurts the player", ctx do
    save(ctx, %Inventory{})
    {_client, pid} = TestPlayer.login(ctx)
    owner = summon(ctx, "minecraft:ghast", <<17::128>>, 10.0)

    # A second's charge, then a large fireball: its hit and blast.
    Valimc.TestWait.until(fn -> TestPlayer.living(pid).health.value < 20.0 end, 30_000)
    assert entry(owner, <<17::128>>).body.mob.ai.target == {:player, ctx.uuid}
  end
end
