defmodule Valimc.MobAiConnectionTest do
  @moduledoc """
  Mob AI live in a group (VMC-041a): a summoned zombie targets a survival
  player, walks to it and hits it; a pig follows a player holding a carrot,
  and panics when the player hits it. A blaze (VMC-043d) sets the player on
  fire with its fireballs; zombified piglins leave the player alone until it
  hits one, then all turn on it.
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

  defp summon(ctx, type, uuid, dx) do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new(type)
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
end
