defmodule Valimc.NaturalSpawningTest do
  @moduledoc """
  Natural spawning in a group (VMC-042a): the caps hold for one player, for
  two players in one group and for players in separate groups; mobs despawn
  at vanilla's distances and in peaceful; a name tag makes a mob persistent.
  A spawner block spawns near a player, a swamp hut's piece its witches
  (VMC-042b). A village's cat spawner brings a cat near five claimed homes,
  not four (VMC-044a3); the trader spawner brings a wandering trader to wander
  by its player (VMC-044a4).
  The oracle stage `natural_spawning` holds the rules' fixtures.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.{EntityTypes, Grid}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.TestScope
  alias Valimc.World.{Region, RegionData, Spawning}

  @night %{
    dimension: "minecraft:overworld",
    zoom_seed: 0,
    seed: 0,
    sea_level: 63,
    max_y: 319,
    darken: 11,
    thundering: false,
    difficulty: 2,
    slime_chance: 0.0,
    border: {-29_999_984.0, -29_999_984.0, 29_999_984.0, 29_999_984.0}
  }

  setup do
    Spawning.install!()
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-spawning-#{nonce}")
    # Two sections far enough apart for separate groups.
    keys = [{70_000 + rem(nonce, 300) * 9, 2600}, {70_000 + rem(nonce, 300) * 9 + 5, 2600}]

    TestScope.isolate(Enum.flat_map(keys, &TestScope.neighborhood/1),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)

    owners =
      for key <- keys do
        Valimc.TestDisk.write(base, key, :items, %{records: []})
        {:ok, owner} = Valimc.TestWorld.item_owner(key)
        {key, owner}
      end

    on_exit(fn ->
      for key <- keys,
          k <- TestScope.neighborhood(key),
          {pid, _} <- Valimc.TestWorld.registered(k) do
        try do
          TestScope.kill(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(base)
    end)

    %{owners: owners}
  end

  # A group of the owners' sections, every chunk simulated, as a group's
  # tick reads them.
  defp group(owners, players, env, spawning, tick) do
    size = Grid.region_size()

    sections =
      for owner <- owners, into: %{} do
        resource = Valimc.TestRegion.section(owner)
        {rx, rz} = resource.key

        chunks =
          for x <- 0..(size - 1),
              z <- 0..(size - 1),
              into: MapSet.new(),
              do: {rx * size + x, rz * size + z}

        {resource.key, put_in(resource.tickets.simulated, chunks)}
      end

    %{
      sections: sections,
      stores: for({_, r} <- sections, do: r.blocks.ref),
      absent: [],
      players: players,
      spawning: spawning,
      environment: env,
      dimension: :overworld,
      game_time: tick
    }
  end

  # A tick's plan, applied in the owners.
  defp tick(owners, players, env, spawning, tick) do
    owners = List.wrap(owners)
    group = group(owners, players, env, spawning, tick)
    {spawning, plan} = Spawning.plan(group)
    {sections, plan} = RegionData.spawn_packs(group.sections, plan)
    by_key = Map.new(owners, &{Valimc.TestRegion.section(&1).key, &1})

    for {key, {records, discards, resets, _events}} <- plan do
      Valimc.TestRegion.replace_section(
        by_key[key],
        &RegionData.spawned(%{&1 | ai_random: sections[key].ai_random}, records, discards, resets)
      )
    end

    {spawning, plan}
  end

  defp mobs(owner) do
    for {_, %{kind: :mob, body: body, entity: e}} <-
          Valimc.TestRegion.section(owner).entities.store.entries,
        do: {body.type, {e.x, e.y, e.z}}
  end

  defp monsters_near(mobs, {px, _, pz}) do
    Enum.count(mobs, fn {type, {x, _, z}} ->
      EntityTypes.fetch(type).category == :monster and
        (div_floor(x) * 16 + 8 - px) ** 2 + (div_floor(z) * 16 + 8 - pz) ** 2 < 16_384
    end)
  end

  defp div_floor(v), do: Integer.floor_div(floor(v), 16)

  defp centre({rx, rz}, dx, dz), do: {rx * 128 + dx * 1.0, 64.0, rz * 128 + dz * 1.0}

  defp run(owners, players, ticks) do
    Enum.reduce(1..ticks, Spawning.new(), fn t, spawning ->
      elem(tick(owners, players, @night, spawning, t), 0)
    end)
  end

  test "one player's monsters stop at the cap of 70", %{owners: [{key, owner} | _]} do
    {x, y, z} = centre(key, 64, 64)
    run(owner, [{x, y, z, false, false}], 400)
    near = monsters_near(mobs(owner), {x, y, z})
    # The cap stops a category at the next chunk; one attempt adds at most a cluster.
    assert near >= 66 and near <= 73
    # Every spawn kept vanilla's 24 blocks from the player.
    assert Enum.all?(mobs(owner), fn {_, {mx, my, mz}} ->
             (mx - x) ** 2 + (my - y) ** 2 + (mz - z) ** 2 > 576
           end)
  end

  test "two players of one group each hold their own local cap", %{
    owners: [{a_key, a}, {b_key, b}]
  } do
    # One group holding both sections, a player in each, 640 blocks apart.
    {ax, ay, az} = centre(a_key, 64, 64)
    {bx, by, bz} = centre(b_key, 64, 64)
    run([a, b], [{ax, ay, az, false, false}, {bx, by, bz, false, false}], 400)
    assert monsters_near(mobs(a), {ax, ay, az}) in 66..73
    assert monsters_near(mobs(b), {bx, by, bz}) in 66..73
  end

  test "players in separate groups spawn under their own caps", %{
    owners: [{a_key, a}, {b_key, b}]
  } do
    {ax, ay, az} = centre(a_key, 64, 64)
    {bx, by, bz} = centre(b_key, 64, 64)
    run(a, [{ax, ay, az, false, false}], 300)
    run(b, [{bx, by, bz, false, false}], 300)
    assert monsters_near(mobs(a), {ax, ay, az}) in 66..73
    assert monsters_near(mobs(b), {bx, by, bz}) in 66..73
  end

  test "a spectator neither spawns nor keeps mobs", %{owners: [{key, owner} | _]} do
    {x, y, z} = centre(key, 64, 64)
    run(owner, [{x, y, z, true, false}], 100)
    assert mobs(owner) == []
  end

  defp place(owner, type, {x, y, z}, persistent \\ false) do
    {:ok, body} = Body.new(type)
    body = if persistent, do: Body.name(body, {:string, "Kept"}), else: body
    uuid = :crypto.strong_rand_bytes(16)
    :ok = Region.drop_items(owner, [Store.body_record(body, uuid, {x, y, z})])
    uuid
  end

  defp alive?(owner, uuid),
    do: match?({:ok, _}, Store.find(Valimc.TestRegion.section(owner).entities.store, uuid))

  test "mobs despawn at vanilla's distances; animals and named mobs stay", %{
    owners: [{key, owner} | _]
  } do
    # The player in a corner of the section, the mobs across it.
    {x, y, z} = centre(key, 2, 2)
    near = place(owner, "minecraft:zombie", {x + 20, y, z})
    mid = place(owner, "minecraft:zombie", {x + 100, y, z})
    far = place(owner, "minecraft:zombie", {x + 92, y, z + 92})
    cow = place(owner, "minecraft:cow", {x + 100, y, z + 100})
    named = place(owner, "minecraft:zombie", {x + 110, y, z + 80}, true)
    wild_fish = place(owner, "minecraft:cod", {x + 100, y, z + 100})
    {:ok, fish} = Valimc.Entity.Bucketable.release(Valimc.Protocol.ItemStack.new("cod_bucket"))
    bucketed = :crypto.strong_rand_bytes(16)
    :ok = Region.drop_items(owner, [Store.body_record(fish, bucketed, {x + 105, y, z + 100})])
    # No spawning: a day without monsters (a full sky; persistent categories wait).
    env = %{@night | darken: 0, difficulty: 2}
    {_, _} = tick(owner, [{x, y, z, false, false}], env, Spawning.new(), 3)
    assert alive?(owner, near) and alive?(owner, mid)
    refute alive?(owner, far)
    refute alive?(owner, wild_fish)
    assert alive?(owner, bucketed)
    assert alive?(owner, cow) and alive?(owner, named)

    # Peaceful: one tick discards every monster, named or not; the cow stays.
    {_, _} = tick(owner, [{x, y, z, false, false}], %{env | difficulty: 0}, Spawning.new(), 5)
    refute alive?(owner, near) or alive?(owner, mid) or alive?(owner, named)
    assert alive?(owner, cow)
    assert alive?(owner, bucketed)
  end

  test "a name tag names a mob and makes it persistent, over a record", %{
    owners: [{key, owner} | _]
  } do
    {x, y, z} = centre(key, 64, 64)
    uuid = place(owner, "minecraft:pig", {x, y, z})
    name = {:compound, %{"text" => {:string, "Wilbur"}}}
    assert :ok = Region.name_entity(owner, uuid, name)
    store = Valimc.TestRegion.section(owner).entities.store
    {:ok, {_, id, _}} = Store.find(store, uuid)
    entry = store.entries[id]
    assert entry.body.custom_name == name and entry.body.mob.persistent
    {:ok, restored} = Body.restore(Body.record(entry.body))
    assert restored.custom_name == name and restored.mob.persistent
    # Observers see the name (entity data field 2).
    [{_, metadata} | _] = Body.pairing(1, entry.body)
    assert :binary.match(metadata, "Wilbur") != :nomatch
  end

  test "a spawner block spawns its blazes around it while a player is near, up to six", %{
    owners: [{key, owner} | _]
  } do
    {x, y, z} = centre(key, 64, 64)
    {sx, sz} = {trunc(x) + 3, trunc(z)}
    spawner = {sx, 64, sz}
    state = Valimc.Data.Blocks.default_state("spawner")

    Valimc.TestRegion.replace_section(owner, fn resource ->
      :ok = Valimc.World.Blocks.put(resource.blocks, %{spawner => state})

      {:ok, entries} =
        Valimc.Worldgen.FullChunk.block_entities(
          [
            %{
              position: spawner,
              state: state,
              kind: "minecraft:mob_spawner",
              loot_table: nil,
              loot_seed: 0,
              spawner_entity: "minecraft:blaze",
              bees: [],
              exit: nil,
              nbt: nil
            }
          ],
          %{}
        )

      {:ok, entities} = Valimc.World.BlockEntities.add(resource.block_entities, entries)
      %{resource | block_entities: entities}
    end)

    # A night: a blaze needs the darkness a monster's walk target asks for.
    env = @night
    player = [{x, y, z, false, false}]

    spawning =
      Enum.reduce(1..399, Spawning.new(), fn t, spawning ->
        elem(tick(owner, player, env, spawning, t), 0)
      end)

    blazes = for {"minecraft:blaze", at} <- mobs(owner), do: at
    assert length(blazes) in 1..6

    assert Enum.all?(blazes, fn {bx, by, bz} ->
             abs(bx - sx - 0.5) <= 4 and abs(bz - sz - 0.5) <= 4 and by in [63.0, 64.0, 65.0]
           end)

    # The countdown restarted after the spawns, and stops with no player in range.
    {_nbt, _config, delay} = spawning.spawners[spawner]
    assert delay in 0..800
    far = [{x - 40, y, z, false, false}]
    {spawning, _} = tick(owner, far, env, spawning, 399)
    assert elem(spawning.spawners[spawner], 2) == delay
  end

  test "inside a swamp hut's piece the monsters are witches", %{owners: [{key, owner} | _]} do
    {x, y, z} = centre(key, 64, 64)
    # A hut's start kept by the chunks around one 40 blocks east of the player.
    {cx, cz} = {div(trunc(x) + 40, 16), div(trunc(z), 16)}
    piece = [cx * 16 - 16, 64, cz * 16 - 16, cx * 16 + 31, 70, cz * 16 + 31]
    kept = [{"minecraft:swamp_hut", piece, [piece]}]

    Valimc.TestRegion.replace_section(owner, fn resource ->
      %{
        resource
        | structures: Map.new(for dx <- -1..1, dz <- -1..1, do: {{cx + dx, cz + dz}, kept})
      }
    end)

    run(owner, [{x, y, z, false, false}], 400)
    [x0, y0, z0, x1, y1, z1] = piece

    inside =
      for {type, {mx, my, mz}} <- mobs(owner),
          EntityTypes.fetch(type).category == :monster,
          mx >= x0 and mx < x1 + 1 and my >= y0 and my < y1 + 1 and mz >= z0 and mz < z1 + 1,
          do: type

    assert inside != [] and Enum.all?(inside, &(&1 == "minecraft:witch"))
  end

  test "a village's cat spawner brings a cat near five claimed homes, not four", %{
    owners: [{key, owner} | _]
  } do
    {x, y, z} = centre(key, 64, 64)
    head = Valimc.Data.Blocks.state("red_bed", %{"facing" => "east", "part" => "head"})
    homes = for n <- 0..4, do: {floor(x) + 2 * n, 64, floor(z) + 3}
    for pos <- homes, do: Valimc.TestBlocks.set(pos, head)
    day = %{@night | darken: 0}
    player = [{x, y, z, false, false}]

    cats = fn claims ->
      Valimc.TestRegion.replace_section(
        owner,
        &%{&1 | poi_claims: Map.new(claims, fn p -> {p, 1} end)}
      )

      # Ten tries of the spawner, each a tick it comes up in.
      Enum.reduce(1..10, Spawning.new(), fn t, spawning ->
        elem(tick(owner, player, day, Map.put(spawning, :cats, 0), t), 0)
      end)

      Enum.count(mobs(owner), &(elem(&1, 0) == "minecraft:cat"))
    end

    assert cats.(Enum.take(homes, 4)) == 0
    assert cats.(homes) > 0
  end

  test "the trader spawner brings a wandering trader to wander by its player", %{
    owners: [{key, owner} | _]
  } do
    {x, y, z} = centre(key, 64, 64)
    player = [{x, y, z, false, false}]
    day = %{@night | darken: 0}

    # Thirty tries with the spawner's delay up and its chance sure; one in
    # ten draws through.
    Enum.reduce(1..30, Spawning.new(), fn t, spawning ->
      traders = %{tick: 1, delay: 1200, chance: 100, random: Valimc.Data.JavaRandom.new(t)}
      elem(tick(owner, player, day, %{spawning | traders: traders}, t), 0)
    end)

    store = Valimc.TestRegion.section(owner).entities.store

    traders =
      for {_, %{body: %{type: "minecraft:wandering_trader"} = body, entity: e}} <- store.entries,
          do: {body, e}

    assert [{body, e} | _] = traders
    reference = {floor(x), floor(y), floor(z)}
    assert body.data.despawn_delay == 48_000 and body.data.wander_target == reference
    assert body.mob.home == {reference, 16}
    assert abs(e.x - x) <= 48.5 and abs(e.z - z) <= 48.5 and e.y == 64.0
  end

  test "a tick's environment reads the published clock, weather and settings" do
    env = Spawning.environment(:overworld)
    assert env.dimension == "minecraft:overworld" and env.sea_level == 63 and env.max_y == 319
    assert env.darken in 0..15 and env.difficulty in 0..3
    nether = Spawning.environment(:the_nether)
    # The Nether's sky light level is 4 at any time: a darkening of 11.
    assert nether.darken == 11 and not nether.thundering
  end

  test "generated chunks get the biome's creatures on their grass", %{owners: [{_key, owner} | _]} do
    resource = Valimc.TestRegion.section(owner)
    {rx, rz} = resource.key
    chunks = for x <- 0..7, z <- 0..7, do: {rx * 8 + x, rz * 8 + z}
    records = Spawning.generated(resource, chunks)
    assert records != []

    for %{type: type, x: x, y: y, z: z} <- records do
      assert EntityTypes.fetch(type).category == :creature
      assert y == 64.0 and {div(floor(x), 128), div(floor(z), 128)} == {rx, rz}
    end
  end

  test "pack admission preserves leaders across sections and variants and ages over records", %{
    owners: owners
  } do
    [{a, owner_a}, {b, owner_b}] = owners

    sections =
      Map.new(owners, fn {key, owner} ->
        {key, %{Valimc.TestRegion.section(owner) | ai_random: Valimc.AI.Random.new(13)}}
      end)

    records =
      for {type, pack} <- [{"cod", 0}, {"tropical_fish", 1}, {"axolotl", 2}, {"turtle", 3}],
          i <- 0..3 do
        key = if rem(i, 2) == 0, do: a, else: b
        {:ok, body} = Body.spawned("minecraft:" <> type, :natural)
        record = Store.body_record(body, :crypto.strong_rand_bytes(16), centre(key, 60 + i, 64))

        {key,
         Map.merge(record, %{
           spawn_pack: {:natural, pack},
           spawn_order: pack * 4 + i,
           spawn_school: true
         })}
      end

    plan =
      Enum.reduce(Enum.reverse(records), %{}, fn {key, record}, acc ->
        Map.update(acc, key, {[record], [], [], []}, fn {r, d, s, e} ->
          {[record | r], d, s, e}
        end)
      end)

    {sections, plan} = RegionData.spawn_packs(sections, plan)
    # The batch is finalized exactly once, even when spawned/4 handles it again.
    assert RegionData.spawn_packs(sections, plan) == {sections, plan}

    for {key, owner} <- [{a, owner_a}, {b, owner_b}] do
      {made, _, _, _} = plan[key]

      Valimc.TestRegion.replace_section(owner, fn resource ->
        RegionData.spawned(%{resource | ai_random: sections[key].ai_random}, made, [], [])
      end)
    end

    bodies =
      Map.new(
        for {key, record} <- records do
          owner = if key == a, do: owner_a, else: owner_b
          store = Valimc.TestRegion.section(owner).entities.store
          {:ok, {_, id, _}} = Store.find(store, record.uuid)
          body = store.entries[id].body
          assert body.mob.finalize == nil
          {:ok, restored} = body |> Body.record() |> Body.restore()
          assert restored.data == body.data
          assert restored.mob.ai.random == body.mob.ai.random
          assert Valimc.AI.Mobs.Fish.school(restored.mob.ai).leader == nil
          {record.uuid, body}
        end
      )

    for pack <- 0..1 do
      members = Enum.filter(records, fn {_, r} -> r.spawn_pack == {:natural, pack} end)
      [{_, leader} | followers] = members
      assert Valimc.AI.Mobs.Fish.school(bodies[leader.uuid].mob.ai).school == 4

      for {_, follower} <- followers do
        assert Valimc.AI.Mobs.Fish.school(bodies[follower.uuid].mob.ai).leader == leader.uuid
      end

      if pack == 1 do
        variants = Enum.map(members, fn {_, r} -> bodies[r.uuid].data.variant end)
        assert length(Enum.uniq(variants)) == 1
      end
    end

    axolotls = for {_, r} <- records, r.spawn_pack == {:natural, 2}, do: bodies[r.uuid]
    assert Enum.map(axolotls, & &1.data.age) == [0, 0, -24_000, -24_000]
    assert length(Enum.uniq(Enum.map(axolotls, & &1.data.variant))) <= 2
  end
end
