defmodule Valimc.DragonActorTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.Dragon.{Actor, Flight, Paths, Phases}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    a = {123_000 + rem(nonce, 3333) * 3, 2500}
    b = {elem(a, 0) + 1, elem(a, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-dragon-actor-#{nonce}")

    Valimc.TestScope.isolate([a, b],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false,
      item_simulation: true
    )

    on_exit(fn ->
      for key <- [a, b],
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: Valimc.TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, {pid, ea}} = Valimc.TestWorld.owner(a)
    {:ok, {pb, eb}} = Valimc.TestWorld.owner(b)
    {:ok, [_]} = Region.hand_over(pb, pid)
    Valimc.TestWait.until(fn -> match?({^pid, _, _}, Valimc.TestWorld.lookup(b)) end)
    for {key, epoch} <- [{a, ea}, {b, eb}], do: :ok = Valimc.TestScope.simulate({pid, epoch}, key)

    %{
      a: a,
      b: b,
      source: {pid, ea},
      target: {pid, eb},
      pid: pid,
      base: base,
      edge: elem(b, 0) * 128.0,
      z: elem(a, 1) * 128.0
    }
  end

  defp dragon(at, phase, yaw \\ 0.0) do
    {:ok, body} = Body.new("minecraft:ender_dragon")
    flight = Flight.step(%Flight{position: at, yaw: yaw}, nil, phase)

    actor = %Actor{
      graph: Paths.graph(fn _, _ -> 80 end),
      phases: %Phases{phase: phase, flight: flight}
    }

    %{body | yaw: yaw, head_yaw: yaw, data: %{body.data | phase: phase, brain: actor}}
  end

  defp entry(owner, uuid) do
    store = Valimc.TestRegion.section(owner).entities.store

    case Store.find(store, uuid) do
      {:ok, {_, id, _}} -> store.entries[id]
      _ -> nil
    end
  end

  test "crossing into a later sibling ticks flight and hurt timers once, then reloads", c do
    at = {c.edge - 0.1, 80.0, c.z + 10.5}
    body = %{dragon(at, 10) | velocity: {1.0, 0.0, 0.0}}
    body = put_in(body.mob.living.health.hurt_ticks, 10)
    :ok = Region.drop_items(c.source, [Store.body_record(body, <<540::128>>, at)])
    {:ok, _} = Region.step(c.source, 1)
    assert entry(c.source, <<540::128>>) == nil
    e = entry(c.target, <<540::128>>)
    assert e.entity.x > c.edge
    assert e.body.data.brain.tick == 1 and e.body.data.brain.world_tick == 1
    assert e.body.mob.living.health.hurt_ticks == 9
    assert e.body.mob.ai.tick == 1
    assert length(Valimc.Entity.Dragon.boxes(e.body)) == 8
    :ok = Region.flush(c.pid)
    Valimc.TestScope.kill(c.pid)
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup(c.b) == nil end)
    {:ok, target} = Valimc.TestWorld.owner(c.b)
    saved = entry(target, <<540::128>>)
    assert saved.body.data.brain == e.body.data.brain
    assert saved.body.mob.living.health.hurt_ticks == 9
    :ok = Valimc.TestScope.simulate(target, c.b)
    {:ok, _} = Region.step(target, 1)
    assert entry(target, <<540::128>>).body.data.brain.tick == 2
    assert entry(target, <<540::128>>).body.mob.living.health.hurt_ticks == 8
  end

  test "perched breath appears in the head's sibling and a forced takeoff removes it", c do
    at = {c.edge - 2.0, 80.0, c.z + 40.5}
    body = dragon(at, 5, 90.0)
    body = put_in(body.data.brain.phases.ticks, 9)
    :ok = Region.drop_items(c.source, [Store.body_record(body, <<541::128>>, at)])
    {:ok, _} = Region.step(c.source, 1)
    dragon = entry(c.source, <<541::128>>)
    uuid = dragon.body.data.brain.flame
    assert is_binary(uuid)
    cloud = entry(c.target, uuid)
    assert cloud.body.type == "minecraft:area_effect_cloud"
    assert cloud.body.data.radius == 5.0 and cloud.body.data.duration == 200
    assert cloud.body.data.age == 0
    assert cloud.body.data.owner.uuid == <<541::128>>

    Valimc.TestRegion.replace_section(c.source, fn s ->
      e = entry_from_store(s.entities.store, <<541::128>>)
      body = %{e.body | data: %{e.body.data | phase: 4}}
      put_in(s.entities.store, Store.change_body(s.entities.store, e.entity.entity_id, body))
    end)

    {:ok, _} = Region.step(c.source, 1)
    assert entry(c.target, uuid) == nil
    assert entry(c.source, <<541::128>>).body.data.brain.flame == nil
  end

  test "a sibling crystal's destruction hurts the selected dragon once", c do
    at = {c.edge - 20.0, 81.0, c.z + 90.5}
    crystal_at = {c.edge + 10.0, 81.0, c.z + 90.5}

    for {key, owner, pos} <- [{c.a, c.source, at}, {c.b, c.target, crystal_at}] do
      cell = {floor(elem(pos, 0)), 80, floor(elem(pos, 2))}
      {:ok, observed} = Region.observe_blocks(owner, [cell])

      {:ok, _} =
        Region.set_blocks(owner, observed.fence, %{
          cell => Valimc.Data.Blocks.default_state("obsidian")
        })

      chunk = Valimc.Data.Grid.chunk_key(elem(pos, 0), elem(pos, 2))
      {:ok, %{images: images}} = Region.column_images(owner, [chunk])
      :ok = Valimc.World.RegionStorage.import(c.base, :the_end, key, %{columns: images})
    end

    {:ok, {pid, ea}} = Valimc.TestWorld.owner({:the_end, c.a})
    {:ok, {pb, eb}} = Valimc.TestWorld.owner({:the_end, c.b})
    {:ok, [_]} = Region.hand_over(pb, pid)

    Valimc.TestWait.until(fn ->
      match?({^pid, _, _}, Valimc.TestWorld.lookup({:the_end, c.b}))
    end)

    source = {pid, ea}
    target = {pid, eb}
    {:ok, crystal} = Body.new("minecraft:end_crystal")
    body = dragon(at, 10)
    body = %{body | mob: %{body.mob | no_ai: true}}
    body = put_in(body.mob.living.health.value, 150.0)
    body = put_in(body.data.brain.crystal, <<544::128>>)
    :ok = Region.drop_items(source, [Store.body_record(body, <<543::128>>, at)])
    :ok = Region.drop_items(target, [Store.body_record(crystal, <<544::128>>, crystal_at)])

    hit = %{
      source: Valimc.Living.DamageSource.new(:generic),
      amount: 1.0,
      attacker: nil,
      position: crystal_at
    }

    assert {:ok, %{hurt: true}} = Region.hurt_entity(target, <<544::128>>, hit)
    assert entry(target, <<544::128>>) == nil
    damaged = entry(source, <<543::128>>).body
    assert damaged.mob.living.health.value == 140.0
    assert damaged.data.brain.ambient == -80

    for {key, epoch} <- [{c.a, ea}, {c.b, eb}],
        do: :ok = Valimc.TestScope.simulate({pid, epoch}, key)

    {:ok, _} = Region.step(source, 1)
    damaged = entry(source, <<543::128>>).body
    assert damaged.mob.living.health.value == 140.0
    assert damaged.data.brain.crystal == nil
    :ok = Region.flush(pid)
  end

  test "the death clock rises and awards the repeat-kill bursts once", c do
    at = {c.edge - 20.0, 80.0, c.z + 60.5}
    body = dragon(at, 6)
    body = put_in(body.mob.living.health.value, 0.0)
    body = put_in(body.data.death_time, 149)
    :ok = Region.drop_items(c.source, [Store.body_record(body, <<542::128>>, at)])
    {:ok, _} = Region.step(c.source, 1)
    e = entry(c.source, <<542::128>>)
    assert e.body.data.death_time == 150
    assert_in_delta e.entity.y, 80.10000000149012, 1.0e-9
    {:ok, _} = Region.step(c.source, 50)
    assert entry(c.source, <<542::128>>) == nil

    total = fn ->
      for owner <- [c.source, c.target],
          {_, %{kind: :orb, value: value, count: count}} <-
            Valimc.TestRegion.section(owner).entities.store.entries,
          reduce: 0 do
        sum -> sum + value * count
      end
    end

    assert total.() == 500
    {:ok, _} = Region.step(c.source, 2)
    assert total.() == 500
    :ok = Region.flush(c.pid)
  end

  defp entry_from_store(store, uuid) do
    {:ok, {_, id, _}} = Store.find(store, uuid)
    store.entries[id]
  end
end
