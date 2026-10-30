defmodule Valimc.EntityBodiesTest do
  @moduledoc "Bodies (VMC-043a): one record for mobs and other entities, kept, handed over and replicated."
  use ExUnit.Case, async: true
  alias Valimc.Data.{Blocks, EntityTypes}
  alias Valimc.Entity.{Body, ItemMotionState, Mob, Store, Tracking}
  alias Valimc.Protocol.{EntityPackets, ItemStack, Packets}
  alias Valimc.TestScope
  alias Valimc.World.Region

  defp summoned(type, key, position, uuid \\ <<7::128>>) do
    {:ok, body} = Body.new(type)
    record = Store.body_record(body, uuid, position)
    {:ok, store, {_, id, _}} = Store.create_record(Store.new(), key, record)
    {store, id, record}
  end

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  # One tracking tick with every changed view's tracker ticking: its frame by id.
  defp step(tracking, views, tick) do
    {tracking, publication} =
      Tracking.pass(tracking, views, {%{}, %{}}, nil, tick, simulated: MapSet.new())

    frame = publication.frame |> Tracking.decode() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    {tracking, frame}
  end

  describe "records" do
    test "a zombie pairs with its health and attributes, a primed TNT with nothing" do
      {store, id, record} = summoned("minecraft:zombie", {0, 0}, {1.5, 64.0, 2.5})
      view = store.views[id]
      assert view.kind == :mob and view.type == "minecraft:zombie" and view.alive

      assert view.metadata == [
               binary(EntityPackets.metadata(id, health: 20.0)),
               binary(Packets.attributes(id, Mob.synced("minecraft:zombie", %{})))
             ]

      assert Store.valid_record?({0, 0}, record)
      assert Store.record(store.entries[id]) == record

      {tnt, tnt_id, _} = summoned("minecraft:tnt", {0, 0}, {3.5, 64.0, 3.5})
      assert tnt.views[tnt_id].kind == :object and tnt.views[tnt_id].metadata == []

      assert tnt.entries[tnt_id].body.data == %{
               fuse: 80,
               block_state: Blocks.default_state("tnt")
             }
    end

    test "a record of an unknown type, a wrong kind or a broken mob is refused" do
      {_, _, record} = summoned("minecraft:zombie", {0, 0}, {1.5, 64.0, 2.5})
      refute Store.valid_record?({0, 0}, %{record | type: "minecraft:unknown"})
      # A type without behaviour is kept (VMC-042b: what generation adds).
      assert Store.valid_record?({0, 0}, %{record | type: "minecraft:snow_golem", data: %{}})
      refute Store.valid_record?({0, 0}, %{record | kind: :object})
      refute Store.valid_record?({0, 0}, put_in(record, [:mob, :equipment], %{hand: nil}))
      refute Store.valid_record?({1, 0}, record)
      assert {:ok, %Store{}} = Store.restore({0, 0}, [record])
    end
  end

  describe "kill and death" do
    test "a killed zombie hurts, dies, poofs and expires after 20 ticks" do
      {store, id, _} = summoned("minecraft:zombie", {0, 0}, {1.5, 64.0, 2.5})
      {:ok, store} = Store.kill(store, id)
      entry = store.entries[id]
      assert entry.body.mob.living.health.value == 0.0
      refute store.views[id].alive

      assert Enum.map(entry.events, &elem(&1, 1)) == [
               binary(Packets.damage_event(id, :generic_kill)),
               binary(EntityPackets.entity_event(id, 3))
             ]

      # Killing it again does nothing.
      assert {:ok, ^store} = Store.kill(store, id)

      {store, []} = Store.age(store, 18)
      {store, []} = Store.age(store, 1)

      assert List.last(store.entries[id].events) ==
               {3, binary(EntityPackets.entity_event(id, 60))}

      assert {_, [{_, ^id, _}]} = Store.age(store, 1)
    end

    test "a killed primed TNT is removed at once" do
      {store, id, _} = summoned("minecraft:tnt", {0, 0}, {3.5, 64.0, 3.5})
      {:ok, store} = Store.kill(store, id)
      assert store.entries == %{} and store.views == %{}
    end
  end

  describe "replication" do
    test "trackers spawn the body facing its yaw, then send its death as it happens" do
      {store, id, _} = summoned("minecraft:zombie", {0, 0}, {1.5, 64.0, 2.5})
      # The first update sends the position, as vanilla's tick 0 does.
      {tracking, frame} = step(%Tracking{}, store.views, 1)
      assert frame == %{id => [binary(EntityPackets.move(id, {0, 0, 0}, false))]}
      [row] = Map.values(Tracking.published(tracking))
      assert row.range == EntityTypes.tracking_range("zombie") and row.type == "minecraft:zombie"
      position = %{entity_id: id, uuid: <<7::128>>, x: 1.5, y: 64.0, z: 2.5}
      assert row.spawn == binary(EntityPackets.spawn(position, "minecraft:zombie"))

      {:ok, store} = Store.kill(store, id)
      {_tracking, frame} = step(tracking, store.views, 2)

      assert frame[id] == [
               binary(Packets.damage_event(id, :generic_kill)),
               binary(EntityPackets.entity_event(id, 3)),
               binary(EntityPackets.metadata(id, pose: :dying, health: 0.0))
             ]
    end
  end

  describe "owners" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {29_000 + rem(nonce, 3_333) * 3, 900}
      destination = {elem(key, 0) + 1, elem(key, 1)}
      base = Path.join(System.tmp_dir!(), "valimc-bodies-#{nonce}")
      # Two separate groups: the regionizer would make them one.
      TestScope.isolate(TestScope.neighborhood(key), world_path: base, regionizer: false)
      File.mkdir_p!(base)
      Valimc.TestDisk.write(base, key, :items, %{records: []})
      Valimc.TestDisk.write(base, destination, :items, %{records: []})
      {:ok, owner} = Valimc.TestWorld.item_owner(key)
      {:ok, other} = Valimc.TestWorld.item_owner(destination)

      on_exit(fn ->
        for region <- [key, destination], {pid, _} <- Valimc.TestWorld.registered(region) do
          :sys.resume(pid)
          TestScope.kill(pid)
        end

        File.rm_rf(base)
      end)

      %{key: key, destination: destination, base: base, owner: owner, other: other}
    end

    defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

    defp saved(base, key),
      do: Map.new(Valimc.TestDisk.read(base, key, :items).records, &{&1.uuid, &1})

    defp restart({pid, _}, key) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      {:ok, next} = Valimc.TestWorld.item_owner(key)
      next
    end

    test "a zombie and a primed TNT survive a restart and hand off across a group line", ctx do
      {rx, rz} = ctx.key
      zombie = <<1::128>>
      tnt = <<2::128>>

      records =
        for {type, uuid, dx} <- [
              {"minecraft:zombie", zombie, 120.5},
              {"minecraft:tnt", tnt, 121.5}
            ] do
          {:ok, body} = Body.new(type)
          Store.body_record(body, uuid, {rx * 128 + dx, 64.0, rz * 128 + 4.5})
        end

      :ok = Region.drop_items(ctx.owner, records)
      {pid, _} = ctx.owner
      :ok = Region.flush(pid)
      assert %{^zombie => %{kind: :mob}, ^tnt => %{kind: :object}} = saved(ctx.base, ctx.key)

      owner = restart(ctx.owner, ctx.key)
      assert {:ok, _} = Store.find(store(owner), zombie)
      assert {:ok, _} = Store.find(store(owner), tnt)

      # Across the group line, facing west.
      across = {(rx + 1) * 128 + 2.5, 64.0, rz * 128 + 4.5}

      for uuid <- [zombie, tnt] do
        :ok = Region.move_entity(owner, uuid, across, {90.0, 0.0})

        Valimc.TestWait.until(fn ->
          store(owner).ledger.outgoing == nil and
            match?({:ok, _}, Store.find(store(ctx.other), uuid))
        end)
      end

      {other_pid, _} = ctx.other
      :ok = Region.flush(pid_of(owner))
      :ok = Region.flush(other_pid)
      moved = saved(ctx.base, ctx.destination)
      assert %{kind: :mob, hops: 1, rotation: {90.0, +0.0, 90.0}} = moved[zombie]
      assert %{kind: :object, hops: 1} = moved[tnt]
      refute Map.has_key?(saved(ctx.base, ctx.key), zombie)
    end

    defp pid_of({pid, _}), do: pid

    test "/summon makes modelled types, /kill and /tp select bodies", ctx do
      {rx, rz} = ctx.key
      {x, z} = {rx * 128 + 60.5, rz * 128 + 60.5}

      source = %{
        Valimc.Commands.Source.rcon()
        | dimension: :overworld,
          position: {x, 64.0, z}
      }

      run = fn input ->
        Valimc.Commands.run(source, input)
        Valimc.Commands.Source.collect(source)
      end

      assert run.("summon zombie") =~ "Summoned new Zombie"
      assert run.("summon tnt ~1 ~ ~") =~ "Summoned new Primed TNT"
      assert run.("summon snow_golem") =~ "not supported yet"
      assert run.("summon zombie ~ ~ ~ {NoAI:1b}") =~ "not supported yet"
      Valimc.TestWait.until(fn -> map_size(store(ctx.owner).entries) == 2 end)

      Valimc.TestWait.until(fn ->
        length(
          Valimc.World.bodies(:overworld)
          |> Enum.filter(&(elem(&1, 0) == Valimc.TestWorld.section(ctx.key)))
        ) == 2
      end)

      assert run.("tp @e[type=tnt,distance=..3] ~ ~ ~2") =~ "Teleported Primed TNT"
      # `name=` matches `Entity.getName()`: a name tag's name, else the type's.
      assert run.("tp @e[name=Zombie,distance=..3] ~ ~ ~") =~ "Teleported Zombie"

      [zombie] =
        for {_, %{body: %{type: "minecraft:zombie"}} = e} <- store(ctx.owner).entries,
            do: e.entity.uuid

      :ok = Region.name_entity(ctx.owner, zombie, Valimc.Text.literal("Bob"))

      Valimc.TestWait.until(fn ->
        Enum.any?(
          Valimc.World.bodies(:overworld),
          &match?({_, %{uuid: ^zombie, body: %{custom_name: {:compound, _}}}}, &1)
        )
      end)

      assert run.("kill @e[name=Zombie,distance=..3]") =~ "No entity was found"
      assert run.("kill @e[name=Bob,distance=..3]") =~ "Killed Bob"
      assert run.("kill @e[type=!player,type=!item,distance=..5]") =~ "Killed Primed TNT"
      # The zombie is dying, not yet gone (its loot dropped); the TNT is gone.
      assert [%{kind: :mob, body: body}] =
               for(
                 %{kind: kind} = e <- Map.values(store(ctx.owner).entries),
                 kind != :item,
                 do: e
               )

      refute Body.alive?(body)
    end

    test "/kill and /tp select dropped items and orbs by type, distance, sort and limit", ctx do
      {rx, rz} = ctx.key
      {x, z} = {rx * 128 + 60.5, rz * 128 + 60.5}
      source = %{Valimc.Commands.Source.rcon() | dimension: :overworld, position: {x, 64.0, z}}
      [flesh, stone, orb] = [<<11::128>>, <<12::128>>, <<13::128>>]
      still = %ItemMotionState{no_gravity: true}

      run = fn input ->
        Valimc.Commands.run(source, input)
        Valimc.Commands.Source.collect(source)
      end

      :ok =
        Region.drop_items(ctx.owner, [
          %{uuid: flesh, x: x + 1.0, y: 64.0, z: z, stack: ItemStack.new("rotten_flesh", 1)},
          %{uuid: stone, x: x + 4.0, y: 64.0, z: z, stack: ItemStack.new("stone", 3)},
          %{kind: :orb, uuid: orb, x: x + 2.0, y: 64.0, z: z, value: 3, count: 1, age: 0}
          |> Map.put(:motion, still)
        ])

      section = Valimc.TestWorld.section(ctx.key)
      ours = fn -> for {^section, view} <- Valimc.World.entities(:overworld), do: view end
      Valimc.TestWait.until(fn -> length(ours.()) == 3 end)

      assert run.("tp @e[type=item,sort=nearest,limit=1] ~ ~ ~5") =~ "Teleported Rotten Flesh"
      {:ok, {_, id, _}} = Store.find(store(ctx.owner), flesh)

      assert %{entity: %{z: moved}, motion: %{velocity: {+0.0, +0.0, +0.0}}} =
               store(ctx.owner).entries[id]

      assert moved == z + 5.0

      Valimc.TestWait.until(fn -> Enum.any?(ours.(), &(&1.at == {x, 64.0, z + 5.0})) end)

      assert run.("kill @e[name=Stone,distance=..6]") =~ "Killed Stone"
      assert run.("kill @e[type=experience_orb,distance=..3]") =~ "Killed Experience Orb"
      assert run.("kill @e[distance=..6]") =~ "Killed Rotten Flesh"
      assert store(ctx.owner).entries == %{}
    end
  end
end
