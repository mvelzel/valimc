defmodule Valimc.GroupProjectileTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.Dragon.{Flight, Phases}
  alias Valimc.Entity.{Body, EffectCloud, Projectile, Store}
  alias Valimc.Storage.{Log, RegionLog}
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    a = {119_000 + rem(nonce, 3333) * 3, 2400}
    b = {elem(a, 0) + 1, elem(a, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-group-shots-#{nonce}")

    TestScope.isolate([a, b],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false,
      item_simulation: true
    )

    on_exit(fn ->
      for key <- [a, b], {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, {pa, ea}} = Valimc.TestWorld.owner(a)
    {:ok, {pb, eb}} = Valimc.TestWorld.owner(b)
    {:ok, [_]} = Region.hand_over(pb, pa)
    Valimc.TestWait.until(fn -> match?({^pa, _, _}, Valimc.TestWorld.lookup(b)) end)
    for {key, epoch} <- [{a, ea}, {b, eb}], do: :ok = TestScope.simulate({pa, epoch}, key)

    %{
      a: a,
      b: b,
      base: base,
      pa: pa,
      ea: ea,
      eb: eb,
      edge: elem(b, 0) * 128.0,
      z: elem(a, 1) * 128.0
    }
  end

  defp body(type) do
    {:ok, body} = Body.new(type)
    put_in(body.mob.no_ai, true)
  end

  defp entry(owner, uuid) do
    store = Valimc.TestRegion.section(owner).entities.store

    case Store.find(store, uuid) do
      {:ok, {_, id, _}} -> store.entries[id]
      _ -> nil
    end
  end

  defp record(body, n, at), do: Store.body_record(body, <<n::128>>, at)

  defp arrow(damage \\ 2.0, speed \\ 3.0) do
    owner = %{uuid: <<501::128>>, id: 900, player: true, type: "minecraft:player"}

    arrow =
      Projectile.new("minecraft:arrow", owner) |> Projectile.shoot({1.0, 0.0, 0.0}, speed, 0.0)

    %{arrow | data: %{arrow.data | damage: damage}}
  end

  test "a mob collides with a neighboring-section shulker lid and crosses after its death", c do
    TestScope.isolate([c.a, c.b], mob_goals: false)
    a = {c.pa, c.ea}
    b = {c.pa, c.eb}
    shell = body("minecraft:shulker")
    shell = %{shell | data: %{shell.data | attach_face: 5, peek: 100, peek_amount: 1.0}}
    :ok = Region.drop_items(b, [record(shell, 621, {c.edge + 0.5, 80.0, c.z + 20.5})])
    {:ok, mover} = Body.new("minecraft:husk")
    mover = %{mover | no_gravity: true, velocity: {4.0, 0.0, 0.0}}
    :ok = Region.drop_items(a, [record(mover, 622, {c.edge - 2.0, 80.0, c.z + 20.5})])
    {:ok, _} = Region.step(a, 1)
    assert_in_delta entry(a, <<622::128>>).entity.x, c.edge - 1.3, 1.0e-7
    {:ok, 1} = Region.kill_entities(b, [<<621::128>>])

    Valimc.TestRegion.replace_section(a, fn section ->
      {:ok, {_, id, _}} = Store.find(section.entities.store, <<622::128>>)
      body = %{section.entities.store.entries[id].body | velocity: {4.0, 0.0, 0.0}}
      put_in(section.entities.store, Store.change_body(section.entities.store, id, body))
    end)

    {:ok, _} = Region.step(a, 1)
    assert entry(a, <<622::128>>) == nil
    assert entry(b, <<622::128>>).entity.x > c.edge
    # One movement per group tick across this adoption is VMC-043e18.
  end

  test "an arrow hits an open shulker lid across the section edge, but misses its closed cube",
       c do
    a = {c.pa, c.ea}
    b = {c.pa, c.eb}

    for {open, n, offset} <- [{true, 601, 20.5}, {false, 602, 40.5}] do
      body = body("minecraft:shulker")

      body = %{
        body
        | data: %{
            body.data
            | attach_face: 5,
              peek: if(open, do: 100, else: 0),
              peek_amount: if(open, do: 1.0, else: 0.0)
          }
      }

      :ok = Region.drop_items(b, [record(body, n, {c.edge + 0.5, 80.0, c.z + offset})])
      shot = %{arrow() | velocity: {0.0, 0.0, 3.0}}
      :ok = Region.drop_items(a, [record(shot, n + 10, {c.edge - 0.5, 80.5, c.z + offset - 2.0})])
    end

    {:ok, _} = Region.step(a, 1)
    assert entry(b, <<601::128>>).body.mob.living.health.value == 24.0
    assert entry(a, <<611::128>>) == nil
    assert entry(b, <<602::128>>).body.mob.living.health.value == 30.0
    assert entry(a, <<612::128>>) != nil
  end

  test "foreign dragon parts admit or reflect, clouds apply once, and one frame reloads both sides",
       c do
    a = {c.pa, c.ea}
    b = {c.pa, c.eb}

    dragons =
      for {phase, n, offset} <- [{6, 510, 20.5}, {0, 511, 44.5}] do
        at = {c.edge + 1.5, 80.0, c.z + offset}
        flight = Flight.step(%Flight{position: at, yaw: -90.0}, nil, phase)
        body = body("minecraft:ender_dragon")

        body = %{
          body
          | yaw: -90.0,
            data: %{body.data | phase: phase, brain: %Phases{phase: phase, flight: flight}}
        }

        {record(body, n, at), elem(flight.parts, 0)}
      end

    pig = put_in(body("minecraft:pig").mob.living.health.value, 6.0)

    :ok =
      Region.drop_items(
        b,
        Enum.map(dragons, &elem(&1, 0)) ++
          [record(pig, 512, {c.edge + 0.5, 80.0, c.z + 68.5})]
      )

    cloud = EffectCloud.dragon_breath(nil)

    cloud = %{
      cloud
      | data: %{
          cloud.data
          | age: 4,
            wait: 0,
            radius_per_tick: 0.0,
            effects: [{Valimc.Data.EffectTypes.id("instant_health"), 0}]
        }
    }

    {:ok, crystal} = Body.new("minecraft:end_crystal")
    :ok = Region.drop_items(b, [record(crystal, 517, {c.edge + 0.5, 80.0, c.z + 90.5})])
    harm = put_in(cloud.data.effects, [{Valimc.Data.EffectTypes.id("instant_damage"), 1}])

    shots =
      for {{_, {x, y, z}}, n} <- Enum.zip(dragons, [513, 514]),
          do: record(arrow(), n, {x - 2.0, y + 0.5, z})

    {_, {x, y, z}} = List.last(dragons)

    shots =
      shots ++
        [
          record(arrow(), 515, {x - 2.0, y + 0.5, z}),
          record(cloud, 516, {c.edge - 0.5, 80.0, c.z + 68.5}),
          record(harm, 518, {c.edge - 0.5, 80.0, c.z + 90.5})
        ]

    :ok = Region.drop_items(a, shots)
    {:ok, _} = Region.step(a, 1)
    assert entry(b, <<510::128>>).body.mob.living.health.value == 200.0
    assert entry(b, <<511::128>>).body.mob.living.health.value == 194.0
    assert entry(a, <<516::128>>).body.data.age == 5
    assert Map.has_key?(entry(a, <<516::128>>).body.data.victims, <<512::128>>)
    assert entry(b, <<512::128>>).body.mob.living.health.value == 8.0
    assert entry(b, <<517::128>>) != nil
    assert entry(a, <<518::128>>).body.data.victims == %{}
    assert entry(a, <<513::128>>).body.data.fire == 20
    assert elem(entry(a, <<513::128>>).body.velocity, 0) < 0
    assert entry(a, <<514::128>>) == nil and entry(a, <<515::128>>) == nil
    :ok = Region.flush(c.pa)
    :ok = Log.sync(c.base, {:region, :overworld, c.a})
    stripe = Log.stripe({:region, :overworld, c.a})
    {:ok, %{frames: frames}} = RegionLog.read(Log.dir(c.base, stripe))
    owners = [{:region, :overworld, c.a}, {:region, :overworld, c.b}]

    assert Enum.any?(frames, fn %{ops: ops} ->
             present = for {:frame, owner, _, _} <- ops, do: owner
             Enum.all?(owners, &(&1 in present))
           end)

    TestScope.kill(c.pa)
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup(c.b) == nil end)
    {:ok, a} = Valimc.TestWorld.owner(c.a)
    {:ok, b} = Valimc.TestWorld.owner(c.b)
    assert entry(a, <<513::128>>).body.data.fire == 20
    assert entry(b, <<511::128>>).body.mob.living.health.value == 194.0
    assert entry(b, <<512::128>>).body.mob.living.health.value == 8.0
    # Replaying an operation at its previous revision cannot repeat a hurt.
    store = Valimc.TestRegion.section(b).entities.store
    {:ok, {_, id, revision}} = Store.find(store, <<511::128>>)
    assert {:error, :stale_item} = Store.change_entry(store, id, revision - 1, :remove)
  end

  test "an immediate foreign blast fences a worker's copied store", c do
    b = {c.pa, c.eb}
    at = {c.edge + 1.0, 80.0, c.z + 40.5}
    :ok = Region.drop_items(b, [record(body("minecraft:pig"), 530, at)])
    from = {self(), make_ref()}

    Valimc.TestRegion.replace_section(b, fn state ->
      store = state.entities.store
      pending = %{kind: :item_merge_auto, acceptance_deadline: nil, from: from, base_store: store}

      {:ok, state} =
        Valimc.World.RegionData.start_job(
          state,
          :plan,
          fn ->
            receive do
              :finish -> {:write, store, {:ok, []}}
            end
          end,
          supervisor: Valimc.ItemWorkers,
          deadline: 5000,
          data: pending
        )

      state
    end)

    worker = Valimc.TestRegion.section(b).jobs.entries.plan.pid
    blast = Valimc.World.Explosion.crystal({c.edge - 1.0, 80.0, c.z + 40.5})
    send(c.pa, {:resource, c.ea, {:explode, blast}})
    Valimc.TestWait.until(fn -> entry(b, <<530::128>>).body.mob.living.health.value == 0.0 end)
    send(worker, :finish)
    ref = elem(from, 1)
    assert_receive {^ref, {:error, {:retry, :stale_item_plan}}}
    assert entry(b, <<530::128>>).body.mob.living.health.value == 0.0
    refute Valimc.World.Jobs.running?(Valimc.TestRegion.section(b).jobs, :plan)
  end

  test "a foreign crystal's explosion precedes another arrow hit in the same callback", c do
    a = {c.pa, c.ea}
    b = {c.pa, c.eb}
    {:ok, crystal} = Body.new("minecraft:end_crystal")
    zombie = body("minecraft:zombie")
    health = %{zombie.mob.living.health | maximum: 200.0, value: 200.0}

    zombie = %{
      zombie
      | mob: %{
          zombie.mob
          | living: %{zombie.mob.living | health: health},
            attributes: %{"minecraft:max_health" => %{base: 200.0, modifiers: []}}
        }
    }

    dead = put_in(body("minecraft:zombie").mob.living.health.value, 1.0)

    dead = %{
      dead
      | mob: %{
          dead.mob
          | equipment: %{mainhand: Valimc.Protocol.ItemStack.new("diamond")},
            drop_chances: %{mainhand: 2.0}
        }
    }

    :ok =
      Region.drop_items(b, [
        record(crystal, 520, {c.edge + 0.5, 80.0, c.z + 40.5}),
        record(zombie, 521, {c.edge + 1.5, 80.0, c.z + 44.5}),
        record(crystal, 524, {c.edge + 0.5, 80.0, c.z + 54.5}),
        record(dead, 526, {c.edge + 1.5, 80.0, c.z + 47.5})
      ])

    :ok =
      Region.drop_items(a, [
        record(arrow(2.0, 6.0), 522, {c.edge - 3.5, 80.5, c.z + 40.5}),
        record(arrow(25.0, 6.0), 523, {c.edge - 3.5, 80.5, c.z + 44.5}),
        record(arrow(2.0, 6.0), 525, {c.edge - 3.5, 80.5, c.z + 54.5})
      ])

    {:ok, _} = Region.step(a, 1)
    assert entry(b, <<520::128>>) == nil
    assert entry(b, <<524::128>>) == nil
    assert entry(b, <<526::128>>).body.mob.living.health.value == 0.0
    diamond = Valimc.Protocol.ItemTypes.id("diamond")

    refute Enum.any?(Valimc.TestRegion.section(b).entities.store.entries, fn
             {_, %{kind: :item, stack: %{item_id: ^diamond}}} -> true
             _ -> false
           end)

    health = entry(b, <<521::128>>).body.mob.living.health.value
    assert health > 40.0 and health < 70.0
    assert entry(a, <<522::128>>) == nil and entry(a, <<523::128>>) == nil
    assert Process.alive?(c.pa)
    :ok = Region.flush(c.pa)
  end
end
