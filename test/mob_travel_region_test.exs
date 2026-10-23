defmodule Valimc.MobTravelRegionTest do
  @moduledoc "Mobs travel in their owner's entity phase (VMC-015i): they fall, land, are hurt and pushed."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {64_000 + rem(nonce, 333) * 3, 2300}
    base = Path.join(System.tmp_dir!(), "valimc-mob-travel-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual,
      # No goals: the tests move the mobs alone (VMC-041a).
      mob_goals: false
    )

    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :items, %{records: []})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    {x0, z0} = {rx * 128 + 8, rz * 128 + 8}
    stone = Valimc.Data.Blocks.default_state("stone")

    for x <- (x0 - 3)..(x0 + 3),
        z <- (z0 - 3)..(z0 + 3),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    # A strip across the line to the eastern section.
    east = {rx + 1, rz}
    Valimc.TestDisk.write(base, east, :items, %{records: []})
    {:ok, other} = Valimc.TestWorld.item_owner(east)
    edge = (rx + 1) * 128

    for x <- (edge - 4)..(edge + 3),
        z <- (z0 - 1)..(z0 + 1),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    on_exit(fn ->
      # Sections may have merged into one group, which can retire meanwhile.
      for k <- TestScope.neighborhood(key), {pid, _} <- Valimc.TestWorld.registered(k) do
        try do
          :sys.resume(pid)
          TestScope.kill(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, other: other, east: east, edge: edge, at: {x0 + 0.5, z0 + 0.5}}
  end

  defp summon(ctx, uuid, {x, y, z}) do
    # A husk: a zombie's body, and the sun does not burn it (VMC-043b).
    {:ok, body} = Body.new("minecraft:husk")
    :ok = Region.drop_items(ctx.owner, [Store.body_record(body, uuid, {x, y, z})])
  end

  defp entry(ctx, uuid) do
    store = Valimc.TestRegion.section(ctx.owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, uuid)
    store.entries[id]
  end

  # One owner tick at a time: each moves the mobs once.
  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  test "a zombie falls six blocks, lands on the stone and takes vanilla's fall damage", ctx do
    {x, z} = ctx.at
    summon(ctx, <<1::128>>, {x, 70.0, z})
    step(ctx, 30)
    e = entry(ctx, <<1::128>>)
    assert e.entity.y == 64.0 and e.body.on_ground
    # Six blocks past a safe distance of three: three points (vanilla's fixture).
    assert e.body.mob.living.health.value == 17.0
    assert e.body.mob.motion.fall_distance == 0.0
  end

  test "a zombie falling onto farmland tramples it to dirt (VMC-039a)", ctx do
    {x, z} = ctx.at
    cell = {floor(x), 63, floor(z)}
    Valimc.TestBlocks.set(cell, Valimc.Data.Blocks.default_state("farmland"))
    summon(ctx, <<1::128>>, {x, 70.0, z})
    step(ctx, 30)
    assert Valimc.TestBlocks.get(cell) == Valimc.Data.Blocks.default_state("dirt")
  end

  test "two overlapping zombies push each other apart", ctx do
    {x, z} = ctx.at
    summon(ctx, <<1::128>>, {x, 64.0, z})
    summon(ctx, <<2::128>>, {x + 0.2, 64.0, z + 0.1})
    step(ctx, 20)
    a = entry(ctx, <<1::128>>).entity
    b = entry(ctx, <<2::128>>).entity
    # Pushed until their boxes no longer overlap (0.6 wide).
    assert (b.x - a.x) ** 2 + (b.z - a.z) ** 2 > 0.36
  end

  test "a zombie told to move walks toward its target", ctx do
    {x, z} = ctx.at
    summon(ctx, <<1::128>>, {x - 2.0, 64.0, z})

    for _ <- 1..20 do
      store = Valimc.TestRegion.section(ctx.owner).entities.store
      {:ok, {_, id, _}} = Store.find(store, <<1::128>>)
      target = {x + 2.0, 64.0, z}

      # The AI's place (VMC-041a): navigation sets the wanted position.
      Valimc.TestRegion.replace_section(ctx.owner, fn section ->
        update_in(section.entities.store.entries[id].body.mob.motion, fn motion ->
          Valimc.Entity.MobMotion.move_to(motion, target, 1.0)
        end)
      end)

      step(ctx, 1)
    end

    e = entry(ctx, <<1::128>>)
    assert e.entity.x > x - 1.0 and e.body.yaw == 270.0
  end

  test "a zombie walking across a section line moves to that section's owner", ctx do
    {_, z} = ctx.at
    summon(ctx, <<1::128>>, {ctx.edge - 1.5, 64.0, z})
    target = {ctx.edge + 2.5, 64.0, z}

    # Whichever group owns each section now (the regionizer may merge them).
    find = fn key ->
      Enum.find_value(Valimc.TestWorld.registered(key), fn {pid, _} ->
        store = Valimc.TestRegion.section(pid, key).entities.store

        case Store.find(store, <<1::128>>) do
          {:ok, {_, id, _}} -> {pid, id}
          _ -> nil
        end
      end)
    end

    Valimc.TestWait.until(fn ->
      case find.(ctx.key) do
        {pid, id} ->
          Valimc.TestRegion.replace_section(
            pid,
            fn section ->
              update_in(section.entities.store.entries[id].body.mob.motion, fn motion ->
                Valimc.Entity.MobMotion.move_to(motion, target, 1.0)
              end)
            end,
            ctx.key
          )

          for key <- [ctx.key, ctx.east], {pid, _} <- Valimc.TestWorld.registered(key) do
            TestScope.simulate(pid, key)
            Region.step({pid, nil}, 1)
          end

          false

        nil ->
          find.(ctx.east)
      end
    end)
  end

  test "an endermite that lived its 2400 ticks leaves its owner; a persistent one stays (VMC-043e)",
       ctx do
    {x, z} = ctx.at

    for {uuid, persistent, dx} <- [{<<7::128>>, false, 0.0}, {<<8::128>>, true, 2.0}] do
      {:ok, body} = Body.new("minecraft:endermite")
      body = %{body | data: %{life: 2398}, mob: %{body.mob | persistent: persistent}}
      :ok = Region.drop_items(ctx.owner, [Store.body_record(body, uuid, {x + dx, 64.0, z})])
    end

    step(ctx, 1)
    assert entry(ctx, <<7::128>>).body.data.life == 2399
    step(ctx, 1)
    store = Valimc.TestRegion.section(ctx.owner).entities.store
    assert {:error, _} = Store.find(store, <<7::128>>)
    assert entry(ctx, <<8::128>>).body.data.life == 2398
  end

  test "a shulker with nothing to hold teleports onto the floor (VMC-043e)", ctx do
    {x, z} = ctx.at
    {:ok, body} = Body.new("minecraft:shulker")
    :ok = Region.drop_items(ctx.owner, [Store.body_record(body, <<9::128>>, {x, 70.0, z})])

    landed =
      Enum.find_value(1..60, fn _ ->
        step(ctx, 1)
        %{entity: e, body: body} = entry(ctx, <<9::128>>)
        if e.y == 64.0, do: {e, body}
      end)

    assert {e, body} = landed
    assert body.data.attach_face == 0
    assert abs(e.x - x) <= 8.5 and abs(e.z - z) <= 8.5
  end

  test "a shulker's bullet hits a zombie for 4 and lifts it (VMC-043e)", ctx do
    {x, z} = ctx.at
    # A husk (the sun does not burn it), its goals off for the scope: a
    # `NoAI` mob would not travel, so the bullet could not lift it.
    {:ok, zombie} = Body.new("minecraft:husk")

    :ok =
      Region.drop_items(ctx.owner, [Store.body_record(zombie, <<10::128>>, {x + 3.0, 64.0, z})])

    step(ctx, 1)
    target = entry(ctx, <<10::128>>)

    seen = %{
      ref: {:mob, <<10::128>>},
      uuid: <<10::128>>,
      position: {target.entity.x, target.entity.y, target.entity.z},
      box: {x + 2.7, 64.0, z - 0.3, x + 3.3, 65.95, z + 0.3}
    }

    owner = %{uuid: <<11::128>>, id: 999_999, player: false, type: "minecraft:shulker"}
    air = fn _ -> Valimc.Data.Blocks.default_state("air") end

    bullet =
      Valimc.Entity.ShulkerBullet.new(owner, {x, 64.5, z}, seen, 1, <<12::128>>, air)

    :ok = Region.drop_items(ctx.owner, [Store.body_record(bullet, <<12::128>>, {x, 64.5, z})])

    hit =
      Enum.find_value(1..200, fn _ ->
        step(ctx, 1)
        %{body: body} = entry(ctx, <<10::128>>)
        if body.mob.living.health.value < 20.0, do: body
      end)

    # 4, less a zombie's armor of 2.
    assert hit.mob.living.health.value == Valimc.Data.Float32.round(20.0 - 3.936)
    assert hit.mob.living.effects[Valimc.Data.EffectTypes.id("levitation")]
  end
end
