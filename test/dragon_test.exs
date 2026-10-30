defmodule Valimc.DragonTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Dragon, Ids, Projectile, Store}
  alias Valimc.TestBodies
  alias Valimc.World.Region

  test "one persisted body reserves eight client parts and keeps them through handoff" do
    {:ok, body} =
      Body.generated(
        "minecraft:ender_dragon",
        "{DragonPhase:6,sitting_damage_received:12.5f,DragonDeathTime:9}",
        true
      )

    assert body.data.phase == 6 and body.data.sitting_damage == 12.5 and body.data.death_time == 9
    {brain, boxes} = TestBodies.dragon_phases(6, {40.0, 90.0, 40.0})
    body = %{body | data: %{body.data | brain: brain}}

    {:ok, store, handle = {_, id, _}} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<61::128>>, {40.0, 90.0, 40.0})
      )

    assert map_size(store.entries) == 1 and map_size(store.views) == 1
    {:ok, next} = Ids.next()
    assert next > id + 8
    {:ok, empty, [record]} = Store.withdraw(store, [handle])
    assert empty.entries == %{}
    {:ok, moved, {_, ^id, _}} = Store.create_record(Store.new(), {0, 0}, record)
    assert moved.entries[id].body.data.brain == brain
    assert Dragon.boxes(moved.entries[id].body) == boxes
    {:ok, restored} = Store.restore({0, 0}, [Store.record(moved.entries[id])])
    [{restored_id, restored_entry}] = Map.to_list(restored.entries)
    assert restored_id > next and restored_entry.body.data == body.data
    {:ok, after_restore} = Ids.next()
    assert after_restore > restored_id + 8
    assert Body.kill(body) == :remove
  end

  test "the owner rejects and ignites a perched arrow, then accepts a head hit in flight" do
    nonce = System.unique_integer([:positive])
    key = {115_000 + rem(nonce, 3333) * 3, 2300}
    base = Path.join(System.tmp_dir!(), "valimc-dragon-#{nonce}")
    Valimc.TestScope.isolate(key, world_path: base, region_ticks: :manual, item_simulation: true)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: Valimc.TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.owner(key)
    {sx, sz} = key
    at = {sx * 128 + 40.0, 80.0, sz * 128 + 40.0}
    {:ok, body} = Body.new("minecraft:ender_dragon")
    {phases, _} = TestBodies.dragon_phases(6, at)
    flight = phases.flight

    body = %{
      body
      | mob: %{body.mob | no_ai: true},
        data: %{body.data | phase: 6, brain: phases}
    }

    :ok = Region.drop_items(owner, [Store.body_record(body, <<62::128>>, at)])
    :ok = Valimc.TestScope.simulate(owner, key)
    {hx, hy, hz} = elem(flight.parts, 0)
    me = %{uuid: <<65::128>>, id: 900, player: true, type: "minecraft:player"}
    arrow = Projectile.new("minecraft:arrow", me) |> Projectile.shoot({1.0, 0.0, 0.0}, 3.0, 0.0)

    shoot = fn uuid ->
      :ok = Region.drop_items(owner, [Store.body_record(arrow, uuid, {hx - 2.0, hy + 0.5, hz})])
      {:ok, _} = Region.step(owner, 1)
    end

    shoot.(<<63::128>>)
    store = Valimc.TestRegion.section(owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, <<62::128>>)
    {:ok, {_, arrow_id, _}} = Store.find(store, <<63::128>>)
    assert Valimc.TestBodies.body(store.entries[id]).mob.living.health.value == 200.0
    assert store.entries[arrow_id].body.data.fire == 20
    assert elem(store.entries[arrow_id].body.velocity, 0) < 0

    Valimc.TestRegion.replace_section(owner, fn s ->
      flying = &%{&1 | data: %{&1.data | phase: 0}}
      put_in(s.entities.store, Valimc.TestBodies.replace(s.entities.store, id, flying))
    end)

    shoot.(<<64::128>>)
    store = Valimc.TestRegion.section(owner).entities.store
    assert Valimc.TestBodies.body(store.entries[id]).mob.living.health.value == 194.0
    assert {:error, :missing_item} = Store.find(store, <<64::128>>)
  end
end

defmodule Valimc.DragonConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.Region

  test "the client's head and body ids hurt the same root and leave the session usable" do
    ctx = TestPlayer.scope("Dragon", {161_000, 2301}, survival: {2, false})

    player =
      Map.merge(ctx.pose, %{
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
        motion: %Valimc.Player.Motion{},
        food: %Valimc.Player.Food{}
      })

    TestPlayer.save(ctx, player, %Inventory{slots: %{36 => ItemStack.new("diamond_sword")}})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    at = {ctx.pose.x + 2.0, 64.0, ctx.pose.z + 6.5}
    {:ok, body} = Body.new("minecraft:ender_dragon")
    {phases, _} = Valimc.TestBodies.dragon_phases(6, at)

    body = %{
      body
      | mob: %{body.mob | no_ai: true},
        data: %{body.data | phase: 6, brain: phases}
    }

    :ok = Region.drop_items(owner, [Store.body_record(body, <<66::128>>, at)])

    Valimc.TestWait.until(fn ->
      Enum.any?(Valimc.World.bodies(:overworld), &(elem(&1, 1).uuid == <<66::128>>))
    end)

    store = Valimc.TestRegion.section(owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, <<66::128>>)
    {_, client} = Client.await(client, :play, "add_entity")

    for {part, expected} <- [{1, 193.0}, {3, 190.25}] do
      Valimc.TestRegion.replace_section(owner, fn s ->
        ready = &put_in(&1.mob.living.health.cooldown, 0)
        put_in(s.entities.store, Valimc.TestBodies.replace(s.entities.store, id, ready))
      end)

      TestPlayer.ticks(pid, 14)
      test = self()

      Valimc.TestConn.replace(pid, fn s ->
        # The native part is not a LivingEntity: falling cannot make this a
        # critical hit, though the parent's equipment receives weapon wear.
        s = put_in(s.player.motion.fall_distance, 1.0)
        s = put_in(s.player.motion.on_ground, false)
        send(test, {:target, Valimc.Player.Attack.target(s, id + part)})
        s
      end)

      assert_receive {:target, {:ok, %{dragon_part: actual}, _}}, 1000
      assert actual == part - 1
      Client.send_packet(client, :play, "attack", Wire.varint(id + part))

      Valimc.TestWait.until(fn ->
        Valimc.TestBodies.body(Valimc.TestRegion.section(owner).entities.store.entries[id]).mob.living.health.value ==
          expected
      end)
    end

    assert TestPlayer.state(pid).inventory.slots[36].components["minecraft:damage"] == 2
    Client.send_packet(client, :play, "set_carried_item", <<1::16>>)
    _ = Client.barrier(client)
    assert TestPlayer.state(pid).inventory.selected == 1
  end
end
