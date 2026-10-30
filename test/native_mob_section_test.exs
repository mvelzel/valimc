defmodule Valimc.NativeMobSectionTest do
  @moduledoc """
  VMC-081d: a section's plain mobs live in its native section: its store
  keeps their rows, every action on them goes through the section, their
  records are the section's and persist, and they move between sections
  whole.
  """
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, NativeBody, Store}
  alias Valimc.Living.DamageSource
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {65_000 + rem(nonce, 333) * 3, 2310}
    base = Path.join(System.tmp_dir!(), "valimc-native-mobs-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual,
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

    east = {rx + 1, rz}
    Valimc.TestDisk.write(base, east, :items, %{records: []})
    {:ok, other} = Valimc.TestWorld.item_owner(east)
    edge = (rx + 1) * 128

    for x <- (edge - 4)..(edge + 3),
        z <- (z0 - 1)..(z0 + 1),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    on_exit(fn ->
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

  defp summon(ctx, type, uuid, position) do
    {:ok, body} = Body.new(type)
    :ok = Region.drop_items(ctx.owner, [Store.body_record(body, uuid, position)])
  end

  defp store(ctx), do: Valimc.TestRegion.section(ctx.owner).entities.store

  defp entry(ctx, uuid) do
    store = store(ctx)
    {:ok, {_, id, _}} = Store.find(store, uuid)
    store.entries[id]
  end

  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  defp hit(amount) do
    player = %{
      uuid: <<77::128>>,
      entity_id: 999_999,
      player: true,
      type: "minecraft:player",
      mainhand: nil
    }

    %{
      source: DamageSource.new(:player_attack),
      amount: amount,
      attacker: player,
      direct: player,
      position: nil
    }
  end

  test "a plain mob is native: it falls, lands and is published from its row", ctx do
    {x, z} = ctx.at
    summon(ctx, "minecraft:wolf", <<1::128>>, {x, 70.0, z})
    e = entry(ctx, <<1::128>>)
    assert Store.native_entry?(e)
    assert %NativeBody{type: "minecraft:wolf", alive: true} = e.body
    step(ctx, 30)
    e = entry(ctx, <<1::128>>)
    assert e.entity.y == 64.0 and e.body.on_ground
    # Three blocks past its safe distance: three points of its eight.
    record = Store.record(e)
    assert record.mob.living.health.value == 5.0
    assert record.type == "minecraft:wolf" and record.x == x
    # Its view publishes its row.
    view = store(ctx).views[e.entity.entity_id]
    assert view.body == e.body and view.alive
  end

  test "a player's hit, a name tag and /kill go through its section", ctx do
    {x, z} = ctx.at
    summon(ctx, "minecraft:goat", <<2::128>>, {x, 64.0, z})
    step(ctx, 1)

    assert {:ok, %{hurt: true, full: true, previous: 10.0, health: 7.0}} =
             Region.hurt_entity(ctx.owner, <<2::128>>, hit(3.0))

    e = entry(ctx, <<2::128>>)
    assert Store.record(e).mob.living.health.value == 7.0
    assert Enum.any?(e.events, fn {_, packet} -> is_tuple(packet) end)

    name = Valimc.Text.literal("Billy")
    assert :ok = Region.name_entity(ctx.owner, <<2::128>>, name)
    e = entry(ctx, <<2::128>>)
    assert e.body.custom_name == name and e.body.persistent
    assert Store.record(e).custom_name == name

    assert {:ok, 1} = Region.kill_entities(ctx.owner, [<<2::128>>])
    refute entry(ctx, <<2::128>>).body.alive
    # Its death animation ends and it leaves.
    step(ctx, 25)
    assert {:error, _} = Store.find(store(ctx), <<2::128>>)
  end

  test "its tracker is native: each tick's frame holds what an Elixir tracker sends", ctx do
    alias Valimc.Entity.{Publication, Tracker, Tracking}
    {x, z} = ctx.at
    summon(ctx, "minecraft:wolf", <<9::128>>, {x, 70.0, z})
    id = entry(ctx, <<9::128>>).entity.entity_id
    section = Valimc.TestRegion.section(ctx.owner)
    tracker = Tracker.new_body(section.entities.store.views[id])
    last = elem(Publication.frames(section.publication, nil), 1)

    # Falling, landing, a hit (its events, then its health) and a name.
    {_, _, count} =
      Enum.reduce(1..40, {tracker, last, 0}, fn tick, {tracker, last, count} ->
        if tick == 20, do: Region.hurt_entity(ctx.owner, <<9::128>>, hit(2.0))
        if tick == 30, do: Region.name_entity(ctx.owner, <<9::128>>, Valimc.Text.literal("Rex"))
        step(ctx, 1)
        section = Valimc.TestRegion.section(ctx.owner)
        {tracker, expected} = Tracker.tick_body(tracker, section.entities.store.views[id])
        {:ok, newest, frames} = Publication.frames(section.publication, last)

        sent =
          for {_, frame} <- frames, {^id, packet} <- Tracking.decode(frame), do: packet

        assert sent == expected, "tick #{tick}"
        {tracker, newest, count + length(sent)}
      end)

    assert count >= 10
  end

  test "its records persist: a reloaded section has the same mob", ctx do
    {x, z} = ctx.at
    summon(ctx, "minecraft:panda", <<3::128>>, {x, 66.0, z})
    step(ctx, 10)
    before = Store.record(entry(ctx, <<3::128>>))
    {pid, _} = ctx.owner
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    ctx = %{ctx | owner: owner}
    e = entry(ctx, <<3::128>>)
    assert Store.native_entry?(e)
    assert Store.record(e) == before
  end

  test "a teleport across the section line moves it whole to the sibling section", ctx do
    {_, z} = ctx.at
    summon(ctx, "minecraft:fox", <<4::128>>, {ctx.edge - 1.5, 64.0, z})
    step(ctx, 2)
    target = {ctx.edge + 1.5, 64.0, z}
    assert :ok = Region.move_entity(ctx.owner, <<4::128>>, target, {90.0, 0.0})

    found =
      Valimc.TestWait.until(fn ->
        Enum.find_value(Valimc.TestWorld.registered(ctx.east), fn {pid, _} ->
          store = Valimc.TestRegion.section(pid, ctx.east).entities.store

          case Store.find(store, <<4::128>>) do
            {:ok, {_, id, _}} -> store.entries[id]
            _ -> nil
          end
        end)
      end)

    assert Store.native_entry?(found)
    record = Store.record(found)
    assert {record.x, record.y, record.z} == target
    assert record.rotation == {90.0, 0.0, 90.0}
    assert {:error, _} = Store.find(store(ctx), <<4::128>>)
  end

  test "pushed across the section line, it moves to that section's owner whole", ctx do
    {_, z} = ctx.at
    {:ok, body} = Body.new("minecraft:armadillo")
    body = %{body | velocity: {1.2, 0.0, 0.0}, on_ground: true}

    :ok =
      Region.drop_items(ctx.owner, [
        Store.body_record(body, <<7::128>>, {ctx.edge - 0.6, 64.0, z})
      ])

    find = fn key ->
      Enum.find_value(Valimc.TestWorld.registered(key), fn {pid, _} ->
        store = Valimc.TestRegion.section(pid, key).entities.store

        case Store.find(store, <<7::128>>) do
          {:ok, {_, id, _}} -> store.entries[id]
          _ -> nil
        end
      end)
    end

    found =
      Valimc.TestWait.until(fn ->
        for key <- [ctx.key, ctx.east], {pid, _} <- Valimc.TestWorld.registered(key) do
          TestScope.simulate(pid, key)
          Region.step({pid, nil}, 1)
        end

        find.(ctx.east)
      end)

    assert Store.native_entry?(found)
    assert found.entity.x > ctx.edge
    assert Store.record(found).type == "minecraft:armadillo"
    assert find.(ctx.key) == nil
  end

  test "a teleport to another group's section hands it off durably", ctx do
    {x, z} = ctx.at
    {rx, rz} = ctx.key
    far = {rx + 12, rz}
    base = Valimc.config(:world_path, ctx.key)

    TestScope.isolate(TestScope.neighborhood(far),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    Valimc.TestDisk.write(base, far, :items, %{records: []})
    {:ok, other} = Valimc.TestWorld.item_owner(far)
    on_exit(fn -> for {pid, _} <- Valimc.TestWorld.registered(far), do: TestScope.kill(pid) end)

    summon(ctx, "minecraft:llama", <<8::128>>, {x, 64.0, z})
    step(ctx, 1)
    native = store(ctx).native
    assert {1, _} = Valimc.Native.mob_section_info(native.ref)
    target = {(rx + 12) * 128 + 20.5, 70.0, z}
    assert :ok = Region.move_entity(ctx.owner, <<8::128>>, target, {45.0, 10.0})

    arrived =
      Valimc.TestWait.until(fn ->
        store = Valimc.TestRegion.section(other).entities.store

        case Store.find(store, <<8::128>>) do
          {:ok, {_, id, _}} -> store.entries[id]
          _ -> nil
        end
      end)

    assert Store.native_entry?(arrived)
    record = Store.record(arrived)
    assert {record.x, record.y, record.z} == target
    assert record.rotation == {45.0, 10.0, 45.0}
    assert record.hops == 1
    Valimc.TestWait.until(fn -> match?({0, _}, Valimc.Native.mob_section_info(native.ref)) end)
    assert {:error, _} = Store.find(store(ctx), <<8::128>>)
  end

  test "an explosion hurts and pushes it", ctx do
    {x, z} = ctx.at
    summon(ctx, "minecraft:sniffer", <<5::128>>, {x, 64.0, z})
    step(ctx, 1)

    tnt =
      Store.body_record(
        %{Body.primed_tnt(1) | velocity: {0.0, 0.0, 0.0}},
        <<6::128>>,
        {x + 1.0, 64.0, z}
      )

    :ok = Region.drop_items(ctx.owner, [tnt])
    step(ctx, 5)
    e = entry(ctx, <<5::128>>)
    record = Store.record(e)
    assert record.mob.living.health.value < 14.0
    {vx, _, _} = record.velocity
    assert vx != 0.0 or e.entity.x != x
  end
end
