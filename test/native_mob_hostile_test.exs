defmodule Valimc.NativeMobHostileTest do
  @moduledoc """
  The native hostile families (VMC-081d, `valimc_core::mobs::monsters`)
  against `Valimc.AI.Mobs`: their registered goals against vanilla's; whole
  sections of them thinking tick by tick over generated terrain as the farm
  animals do (`Valimc.NativeMobScene`), spawned through `finalizeSpawn`
  (armour, weapons and their enchanting, babies, jockeys, Halloween heads),
  with the sun and each family's part after the move, every record, mind
  and effect and the level random equal every tick; and what happens to
  them outside a tick (conversions, interactions, splits) on both sides.
  """
  use ExUnit.Case, async: true

  import Valimc.NativeMobScene

  alias Valimc.AI.Conversion
  alias Valimc.Entity.Body
  alias Valimc.Native

  setup_all do
    setup()
  end

  test "the hostile families are native, their goals vanilla's" do
    assert {:ok, types} = Native.mob_kinds()

    for type <-
          ~w(minecraft:zombie minecraft:husk minecraft:zombie_villager minecraft:skeleton
             minecraft:stray minecraft:bogged minecraft:creeper minecraft:spider
             minecraft:cave_spider minecraft:enderman minecraft:witch minecraft:slime
             minecraft:magma_cube minecraft:drowned),
        do: assert(type in types)
  end

  defp loot, do: Valimc.Blocks.Loot.registry()

  defp effects(observed), do: List.flatten(for {_, _, e, _} <- observed, do: e)
  defp minds(observed), do: List.flatten(for {_, m, _, _} <- observed, do: m)

  defp running?(observed, goal),
    do: Enum.any?(minds(observed), &(is_tuple(&1) and goal in elem(&1, 3)))

  ## Zombies

  @zombies ~w(minecraft:zombie minecraft:husk minecraft:zombie_villager)

  test "zombies spawn armed, hunt players and villagers, and alert their kind", ctx do
    spots = land(ctx.blocks, 16, :rand.seed_s(:exsss, 101))
    {[here, villager, golem], rest} = Enum.split(spots, 3)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@zombies)), 1) do
        mob(n, type, spot, finalize: if(rem(n, 4) == 0, do: :spawner, else: :natural))
      end

    statues = [
      mob(90, "minecraft:villager", villager, no_ai: true),
      mob(91, "minecraft:iron_golem", golem, no_ai: true)
    ]

    acts = for i <- [0, 3], do: {3, i, :hurt}

    scene =
      scene([player(0, here)],
        ticks: 240,
        time: 18_000,
        day: 900_000,
        bright: false,
        difficulty: :hard,
        halloween: true,
        statues: statues,
        acts: acts,
        post: true,
        loot: loot(),
        level: 13
      )

    observed = compare(ctx, scene, entries)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:attack, _}, &1))
    assert Enum.any?(effects, &match?({:alert, _, _}, &1))
    assert running?(observed, "Valimc.AI.Goals.MeleeAttack")
  end

  test "zombies spawn as babies and jockeys, and go for golems", ctx do
    spots = land(ctx.blocks, 30, :rand.seed_s(:exsss, 102))
    {[golem, chicken], rest} = Enum.split(spots, 2)

    # Many spawns draw the rare outcomes: babies, jockeys, leaders, weapons.
    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@zombies)), 1),
          do: mob(n, type, spot, finalize: :natural)

    statues = [
      mob(90, "minecraft:iron_golem", golem, no_ai: true),
      mob(91, "minecraft:chicken", chicken, no_ai: true)
    ]

    observed =
      for level <- 1..6 do
        scene =
          scene([],
            ticks: 30,
            bright: false,
            difficulty: :hard,
            day: 2_000_000,
            statues: statues,
            post: true,
            loot: loot(),
            level: 100 + level
          )

        compare(ctx, scene, entries)
      end

    ticks = Enum.concat(observed)
    effects = effects(ticks)
    records = List.flatten(for {r, _, _, _} <- ticks, do: r)
    assert Enum.any?(effects, &match?({:spawn, "minecraft:chicken", _}, &1))
    assert Enum.any?(records, &(&1.data[:baby] == true))
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :mainhand))
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :chest))

    assert Enum.any?(records, fn r ->
             Enum.any?(r.mob.equipment, fn {_, s} -> s.components["minecraft:enchantments"] end)
           end)

    assert running?(ticks, "Valimc.AI.Goals.MeleeAttack")
  end

  test "zombies burn by day, set what they hit alight, and drown", ctx do
    spots = land(ctx.blocks, 6, :rand.seed_s(:exsss, 103))
    pools = water(ctx.blocks, 2, :rand.seed_s(:exsss, 104))
    {[here], rest} = Enum.split(spots, 1)
    {hx, hy, hz} = here

    water = Valimc.Protocol.Data.block("water")
    soaked = [motion: [water: 1.0, eye_water: true, eye: {true, water}]]

    burning =
      for {{x, y, z}, n} <- Enum.with_index([{hx + 1, hy, hz} | rest], 1) do
        type = if rem(n, 2) == 0, do: "minecraft:husk", else: "minecraft:zombie"
        mob(n, type, {x, y, z}, fire: if(n <= 2, do: 300, else: 0))
      end

    drowning =
      for {{{x, y, z}, type}, n} <-
            Enum.with_index(Enum.zip(pools, ["minecraft:zombie", "minecraft:husk"]), 20) do
        mob(n, type, {x, y - 1, z}, [data: [in_water: 598]] ++ soaked)
      end

    scene =
      scene([player(0, here)],
        ticks: 320,
        bright: true,
        monsters_burn: true,
        post: true,
        level: 17
      )

    observed = compare(ctx, scene, burning ++ drowning)
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:convert, "minecraft:drowned"}, &1))
    assert Enum.any?(effects, &match?({:convert, "minecraft:zombie"}, &1))
    assert Enum.any?(effects, &match?({:attack_extra, _, _}, &1))
  end

  ## Skeletons

  @skeletons ~w(minecraft:skeleton minecraft:stray minecraft:bogged)

  test "skeletons spawn with bows, strafe and shoot, and flee wolves", ctx do
    spots = land(ctx.blocks, 14, :rand.seed_s(:exsss, 111))
    {[here, wolf, golem], rest} = Enum.split(spots, 3)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@skeletons)), 1) do
        # Every fourth keeps no bow: melee, its weapon goal's other half.
        mob(n, type, spot, finalize: if(rem(n, 4) != 0, do: :natural))
      end

    statues = [
      mob(90, "minecraft:wolf", wolf, no_ai: true),
      mob(91, "minecraft:iron_golem", golem, no_ai: true)
    ]

    for difficulty <- [:normal, :hard] do
      scene =
        scene([player(0, here)],
          ticks: 240,
          time: 18_000,
          day: 900_000,
          bright: false,
          difficulty: difficulty,
          halloween: true,
          statues: statues,
          acts: [{5, 3, :hurt}],
          post: true,
          loot: loot(),
          level: 23
        )

      observed = compare(ctx, scene, entries)
      assert Enum.any?(effects(observed), &match?({:shoot, _}, &1))
      assert running?(observed, "Valimc.AI.Mobs.Skeleton.Weapon")
    end
  end

  test "skeletons keep out of the sun, flee it burning, and freeze into strays", ctx do
    spots = land(ctx.blocks, 9, :rand.seed_s(:exsss, 112))
    {[here, snow], rest} = Enum.split(spots, 2)

    entries =
      for {{spot, type}, n} <- Enum.with_index(Enum.zip(rest, Stream.cycle(@skeletons)), 1),
          do: mob(n, type, spot, fire: if(rem(n, 2) == 0, do: 200, else: 0))

    frozen =
      mob(30, "minecraft:skeleton", snow,
        data: [in_snow: 138],
        motion: [powder_snow: true]
      )

    scene =
      scene([player(0, here, mode: :creative)],
        ticks: 320,
        bright: true,
        monsters_burn: true,
        acts: [{60, 0, :fire}, {61, 1, :fire}],
        post: true,
        level: 29
      )

    observed = compare(ctx, scene, entries ++ [frozen])
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:convert, "minecraft:stray"}, &1))
    assert running?(observed, "Valimc.AI.Goals.FleeSun")
  end

  ## Creepers

  test "creepers chase, swell, explode, and flee cats", ctx do
    spots = land(ctx.blocks, 12, :rand.seed_s(:exsss, 121))
    {[here, cat], rest} = Enum.split(spots, 2)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        data =
          cond do
            n == 3 -> [ignited: true]
            n == 4 -> [powered: true]
            true -> []
          end

        mob(n, "minecraft:creeper", spot, data: data, finalize: :natural)
      end

    {hx, hy, hz} = here
    near = mob(20, "minecraft:creeper", {hx + 2, hy, hz + 1})

    scene =
      scene([player(0, here)],
        ticks: 240,
        bright: false,
        statues: [mob(90, "minecraft:cat", cat, no_ai: true)],
        acts: [{30, 5, :hurt}],
        post: true,
        level: 31
      )

    observed = compare(ctx, scene, entries ++ [near])
    effects = effects(observed)
    assert Enum.any?(effects, &match?({:explode, %{powered: false}}, &1))
    assert Enum.any?(effects, &match?({:discard}, &1))
    assert running?(observed, "Valimc.AI.Mobs.Creeper.Swell")
  end

  defp interact(ctx, body, item) do
    body = put_in(body.mob.ai, Valimc.AI.mind(body.type, uuid(1), nil, body.data))
    record = entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})
    {:ok, restored} = Body.restore(record)
    player = uuid(2000)

    {native, native_record} =
      Native.mob_parity_interact(
        ctx.facts,
        record,
        item,
        {player, {2.5, 64.0, 0.5}, 2000},
        false,
        nil,
        []
      )

    request = %{item: item, infinite: false, player: player}

    case {native, Valimc.AI.Mobs.interact(restored, request)} do
      {:pass, :pass} ->
        :pass

      {{:done, hand, swing, [], others, [], nil, []}, {:ok, body, outcome}} ->
        assert {hand, swing, others} == {outcome.hand, outcome.swing, outcome.others}

        assert native_record ==
                 entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})

        :done
    end
  end

  test "flint and steel or a fire charge lights a creeper", ctx do
    {:ok, creeper} = Body.new("minecraft:creeper")
    stack = &Valimc.Protocol.ItemStack.new/1
    assert interact(ctx, creeper, stack.("minecraft:flint_and_steel")) == :done
    assert interact(ctx, creeper, stack.("minecraft:fire_charge")) == :done
    assert interact(ctx, creeper, stack.("minecraft:stick")) == :pass
  end

  ## Spiders

  test "spiders hunt in the dark, leap, climb, bite and ride skeletons", ctx do
    spots = land(ctx.blocks, 14, :rand.seed_s(:exsss, 131))
    {[here, golem], rest} = Enum.split(spots, 2)

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        type = if rem(n, 3) == 0, do: "minecraft:cave_spider", else: "minecraft:spider"
        mob(n, type, spot, finalize: :natural)
      end

    {hx, hy, hz} = here
    near = mob(20, "minecraft:spider", {hx + 3, hy, hz})
    cave = mob(21, "minecraft:cave_spider", {hx - 2, hy, hz + 1})
    collide = for t <- 0..239, do: if(rem(div(t, 7), 3) == 0, do: [0, 3, 12], else: [])

    observed =
      for {difficulty, level} <- [hard: 41, normal: 42, hard: 43, hard: 44, hard: 45] do
        scene =
          scene([player(0, here)],
            ticks: 160,
            bright: false,
            darken: 11,
            difficulty: difficulty,
            day: 2_000_000,
            statues: [mob(90, "minecraft:iron_golem", golem, no_ai: true)],
            acts: [{20, 4, :hurt}],
            collide: collide,
            post: true,
            level: level
          )

        compare(ctx, scene, entries ++ [near, cave])
      end

    # A skeleton jockey is one spawn in a hundred: many first ticks.
    spawned =
      for level <- 50..89 do
        scene =
          scene([], ticks: 1, bright: false, difficulty: :hard, loot: loot(), level: level)

        compare(ctx, scene, entries)
      end

    ticks = Enum.concat(observed)
    effects = effects(ticks)
    records = List.flatten(for {r, _, _, _} <- ticks, do: r)

    assert Enum.any?(
             effects(Enum.concat(spawned)),
             &match?({:spawn_body, "minecraft:skeleton", _}, &1)
           )

    assert Enum.any?(effects, &match?({:attack_extra, _, %{effect: _}}, &1))
    assert Enum.any?(records, &(&1.data[:climbing] == true))
    assert Enum.any?(records, &(&1.mob.living.effects != %{}))
    assert running?(ticks, "Valimc.AI.Goals.LeapAtTarget")
    assert running?(ticks, "Valimc.AI.Mobs.Spider.Attack")
  end

  test "spiders give up in the light", ctx do
    spots = land(ctx.blocks, 3, :rand.seed_s(:exsss, 132))
    [here | _] = spots
    {hx, hy, hz} = here
    hurt = for n <- 1..4, do: mob(n, "minecraft:spider", {hx + n, hy, hz - 1})
    acts = for i <- 0..3, do: {2, i, :hurt}

    scene =
      scene([player(0, here)], ticks: 400, bright: true, acts: acts, post: true, level: 47)

    compare(ctx, scene, hurt)
  end

  ## Endermen

  test "endermen stare back, teleport, freeze, take blocks and keep their anger", ctx do
    spots = land(ctx.blocks, 14, :rand.seed_s(:exsss, 141))
    {[here, far, mite], rest} = Enum.split(spots, 3)
    {hx, hy, hz} = here

    entries =
      for {spot, n} <- Enum.with_index(rest, 1),
          do: mob(n, "minecraft:enderman", spot, finalize: if(n < 4, do: :natural))

    # One stands where the first player looks, one close by where the
    # second looks; one carries a block. The first player walks away later.
    {fx, fy, fz} = far
    grass = Valimc.Protocol.Data.block("grass_block")
    stared = mob(20, "minecraft:enderman", {hx + 6, surface(ctx.blocks, hx + 6, hz), hz})
    close = mob(22, "minecraft:enderman", {hx, surface(ctx.blocks, hx, hz + 3), hz + 3})
    carrying = mob(21, "minecraft:enderman", {fx, fy, fz}, data: [carried: grass])
    p = staring(player(0, here), stared)
    q = staring(player(1, {hx, hy, hz - 1}), close)
    {px, py, pz} = p.position

    moves =
      for t <- 0..239 do
        dx = if t < 80, do: 0.0, else: (t - 80) * 0.3
        [{{px - dx, py, pz}, {0.0, 0.0, 0.0}}, {q.position, {0.0, 0.0, 0.0}}]
      end

    acts = [{5, 0, :shot}, {12, 1, :poked}, {30, 2, :hurt}, {40, 4, :poked}]

    for {bright, level} <- [{false, 51}, {true, 52}] do
      scene =
        scene([p, q],
          ticks: 240,
          moves: moves,
          bright: bright,
          darken: if(bright, do: 0, else: 11),
          statues: [mob(90, "minecraft:endermite", mite, no_ai: true)],
          acts: acts,
          post: true,
          level: level
        )

      observed = compare(ctx, scene, entries ++ [stared, carrying, close])
      effects = effects(observed)
      records = List.flatten(for {r, _, _, _} <- observed, do: r)
      assert Enum.any?(effects, &match?({:event, 46}, &1))
      assert Enum.any?(effects, &match?({:level_event, _, 2018, _}, &1))
      assert Enum.any?(records, &(&1.data.stared_at == true))
      assert running?(observed, "Valimc.AI.Mobs.Enderman.Freeze")
    end
  end

  # A player turned to look into a mob's eyes (an enderman's).
  defp staring(player, {_, %{entity: %{x: ex, y: ey, z: ez}}}) do
    {px, py, pz} = player.position
    dy = ey + 2.55 - (py + 1.62)
    flat = :math.sqrt((ex - px) * (ex - px) + (ez - pz) * (ez - pz))
    yaw = :math.atan2(-(ex - px), ez - pz) * 180.0 / :math.pi()
    %{player | yaw: yaw, pitch: -:math.atan2(dy, flat) * 180.0 / :math.pi()}
  end

  test "endermen pick blocks up and put them down while mobs may grief", ctx do
    spots = land(ctx.blocks, 12, :rand.seed_s(:exsss, 142))
    grass = Valimc.Protocol.Data.block("grass_block")

    entries =
      for {spot, n} <- Enum.with_index(spots, 1) do
        data = if rem(n, 2) == 0, do: [carried: grass], else: []
        mob(n, "minecraft:enderman", spot, data: data)
      end

    observed =
      for level <- 61..64 do
        scene = scene([], ticks: 400, bright: false, darken: 11, level: level)
        compare(ctx, scene, entries)
      end

    effects = effects(Enum.concat(observed))
    assert Enum.any?(effects, &match?({:take_block, _, _}, &1))
  end

  test "a carried block drops as mined with silk touch", ctx do
    {:ok, body} = Body.new("minecraft:enderman")
    holdable = Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:enderman_holdable"]

    for id <- holdable do
      state = Valimc.Data.Blocks.default_state(Valimc.Data.Blocks.name(id))
      body = %{body | data: %{body.data | carried: state}}
      record = entry_record(1, %{entity: %{uuid: uuid(1), x: 0.5, y: 64.0, z: 0.5}, body: body})
      expected = Valimc.AI.Mobs.Enderman.death_drops(body)
      assert {id, Native.mob_parity_death_drops(ctx.facts, record)} == {id, expected}
    end
  end

  ## Witches

  test "witches drink what they need, throw potions and resist magic", ctx do
    spots = land(ctx.blocks, 12, :rand.seed_s(:exsss, 151))
    pools = water(ctx.blocks, 1, :rand.seed_s(:exsss, 152))
    {[here, far], rest} = Enum.split(spots, 2)
    {hx, hy, hz} = here
    water = Valimc.Protocol.Data.block("water")

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        opts =
          cond do
            n == 1 -> [fire: 300]
            n == 2 -> [finalize: :natural]
            true -> []
          end

        mob(n, "minecraft:witch", spot, opts)
      end

    # One close by to throw at, one wet, one hurt, one far from its target.
    [{wx, wy, wz}] = pools
    near = mob(20, "minecraft:witch", {hx + 3, surface(ctx.blocks, hx + 3, hz), hz})

    wet =
      mob(21, "minecraft:witch", {wx, wy - 1, wz},
        motion: [water: 1.0, eye_water: true, eye: {true, water}]
      )

    hurt = put_in(elem(near, 1).body.mob.living.health.value, 6.0)
    hurt = {22, %{hurt | entity: %{hurt.entity | uuid: uuid(22), x: hurt.entity.x + 1.0}}}

    scene =
      scene([player(0, here), player(1, far)],
        ticks: 300,
        bright: false,
        acts: [{10, 3, :hurt}],
        post: true,
        level: 71
      )

    observed = compare(ctx, scene, entries ++ [near, wet, hurt])
    effects = effects(observed)
    records = List.flatten(for {r, _, _, _} <- observed, do: r)
    assert Enum.any?(effects, &match?({:throw_potion, _}, &1))
    assert Enum.any?(records, &(&1.data.drinking == true))
    assert running?(observed, "Valimc.AI.Goals.RangedAttack")

    drunk =
      for %{mob: %{equipment: %{mainhand: stack}}} <- records,
          contents = stack.components["minecraft:potion_contents"],
          into: MapSet.new(),
          do: contents.potion

    assert MapSet.size(drunk) >= 3
  end

  ## Cubes

  test "slimes and magma cubes hop, turn on their target, touch and float", ctx do
    spots = land(ctx.blocks, 12, :rand.seed_s(:exsss, 161))
    pools = water(ctx.blocks, 2, :rand.seed_s(:exsss, 162))
    {[here, golem], rest} = Enum.split(spots, 2)
    {hx, hy, hz} = here

    entries =
      for {spot, n} <- Enum.with_index(rest, 1) do
        type = if rem(n, 2) == 0, do: "minecraft:magma_cube", else: "minecraft:slime"
        mob(n, type, spot, finalize: :natural)
      end

    # Sized ones beside the player (a tiny slime too), and floating ones.
    sized = fn n, type, size, spot ->
      {n, e} = mob(n, type, spot)
      body = e.body

      {mob, data} =
        case type do
          "minecraft:slime" -> Valimc.AI.Mobs.Slime.set_size(body.mob, body.data, size)
          _ -> Valimc.AI.Mobs.MagmaCube.set_size(body.mob, body.data, size)
        end

      {n, %{e | body: %{body | mob: mob, data: data}}}
    end

    beside = [
      sized.(20, "minecraft:slime", 2, {hx + 1, hy, hz}),
      sized.(21, "minecraft:slime", 1, {hx - 1, hy, hz}),
      sized.(22, "minecraft:magma_cube", 1, {hx, hy, hz + 1})
    ]

    floating =
      for {{x, y, z}, n} <- Enum.with_index(pools, 23) do
        {n, e} = sized.(n, "minecraft:slime", 2, {x, y - 1, z})
        {n, put_in(e.body.mob.motion.water, 1.0)}
      end

    for {difficulty, level} <- [normal: 81, hard: 82] do
      scene =
        scene([player(0, here)],
          ticks: 200,
          bright: false,
          difficulty: difficulty,
          day: 2_000_000,
          statues: [mob(90, "minecraft:iron_golem", golem, no_ai: true)],
          post: true,
          level: level
        )

      observed = compare(ctx, scene, entries ++ beside ++ floating)
      effects = effects(observed)
      assert Enum.any?(effects, &match?({:touch, _, _, _}, &1))
      assert running?(observed, "Valimc.AI.Mobs.Cube.Attack")
      assert running?(observed, "Valimc.AI.Mobs.Cube.Float")
    end
  end

  test "a dead cube splits in halves", ctx do
    for {type, module} <- [
          {"minecraft:slime", Valimc.AI.Mobs.Slime},
          {"minecraft:magma_cube", Valimc.AI.Mobs.MagmaCube}
        ],
        size <- [1, 2, 4],
        seed <- 1..4 do
      {:ok, body} = Body.new(type)
      {mob, data} = module.set_size(body.mob, body.data, size)
      body = %{body | mob: mob, data: data, yaw: 30.0, custom_name: if(seed == 2, do: "Cube")}
      body = put_in(body.mob.ai, Valimc.AI.mind(type, uuid(seed), nil, body.data))
      body = put_in(body.mob.living.health.value, 0.0)

      record =
        entry_record(1, %{entity: %{uuid: uuid(seed), x: 3.5, y: 64.0, z: 2.5}, body: body})

      {:ok, restored} = Body.restore(record)
      uuids = for k <- 1..4, do: uuid(100 + k)
      native = Native.mob_parity_split(ctx.facts, record, uuids)

      elixir =
        for {{child, {x, y, z}}, id} <- Enum.zip(module.split(restored, {3.5, 64.0, 2.5}), uuids),
            do: entry_record(1, %{entity: %{uuid: id, x: x, y: y, z: z}, body: child})

      assert {type, size, seed, native} == {type, size, seed, elixir}
    end
  end

  ## Drowned

  test "drowned swim after targets, throw tridents, head for water and shore", ctx do
    spots = land(ctx.blocks, 8, :rand.seed_s(:exsss, 171))
    pools = water(ctx.blocks, 8, :rand.seed_s(:exsss, 172))
    {[here, golem], rest} = Enum.split(spots, 2)
    {[pool], deep} = Enum.split(pools, 1)
    water = Valimc.Protocol.Data.block("water")
    soaked = [water: 1.0, eye_water: true, eye: {true, water}]
    trident = Valimc.Protocol.ItemStack.new("trident")

    on_land =
      for {spot, n} <- Enum.with_index(rest, 1) do
        opts = [finalize: :natural, fire: if(n == 1, do: 100, else: 0)]
        opts = if n == 2, do: [{:equipment, [mainhand: trident]} | opts], else: opts
        mob(n, "minecraft:drowned", spot, opts)
      end

    swimming =
      for {{x, y, z}, n} <- Enum.with_index(deep, 20) do
        opts = [motion: soaked, finalize: :natural, data: [searching: rem(n, 2) == 0]]
        opts = if rem(n, 3) == 0, do: [{:equipment, [mainhand: trident]} | opts], else: opts
        mob(n, "minecraft:drowned", {x, min(y - 2, 58), z}, opts)
      end

    # A player in the water (a target worth swimming after) and one ashore.
    {px, py, pz} = pool
    wet = %{player(1, {px, py - 1, pz}) | position: {px + 0.5, py - 1.0, pz + 0.5}}

    for {bright, level} <- [{false, 91}, {true, 92}] do
      scene =
        scene([player(0, here), wet],
          ticks: 240,
          bright: bright,
          monsters_burn: bright,
          statues: [mob(90, "minecraft:iron_golem", golem, no_ai: true)],
          acts: [{6, 0, :hurt}],
          post: true,
          loot: loot(),
          level: level
        )

      observed = compare(ctx, scene, on_land ++ swimming)
      minds = minds(observed)
      assert Enum.any?(minds, &(is_tuple(&1) and elem(&1, 4) != nil))

      if bright do
        assert running?(observed, "Valimc.AI.Mobs.Drowned.GoToWater")
      else
        assert running?(observed, "Valimc.AI.Mobs.Drowned.SwimUp")
        assert Enum.any?(effects(observed), &match?({:throw_trident, _}, &1))
      end
    end
  end

  test "drowned spawn with tridents, rods, shells and nautilus riders", ctx do
    pools = water(ctx.blocks, 24, :rand.seed_s(:exsss, 173))

    entries =
      for {{x, y, z}, n} <- Enum.with_index(pools, 1),
          do: mob(n, "minecraft:drowned", {x, y - 1, z}, finalize: :natural)

    observed =
      for level <- 1..10 do
        scene = scene([], ticks: 1, bright: false, loot: loot(), level: 200 + level)
        compare(ctx, scene, entries)
      end

    records = List.flatten(for {r, _, _, _} <- Enum.concat(observed), do: r)
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :mainhand))
    assert Enum.any?(records, &Map.has_key?(&1.mob.equipment, :offhand))
  end

  ## Conversions

  defp convert(ctx, body, to, special) do
    record = entry_record(1, %{entity: %{uuid: uuid(1), x: 3.5, y: 64.0, z: 2.5}, body: body})
    {:ok, restored} = Body.restore(record)
    new = uuid(77)
    native = Native.mob_parity_convert(ctx.facts, record, new, to, special)
    elixir = Conversion.convert(restored, new, to, special)

    assert native ==
             entry_record(1, %{entity: %{uuid: new, x: 3.5, y: 64.0, z: 2.5}, body: elixir})
  end

  test "conversions keep what vanilla keeps and roll a zombie's attributes", ctx do
    {:ok, zombie} = Body.new("minecraft:zombie")
    baby = %{zombie | data: %{zombie.data | baby: true}}
    baby = put_in(baby.mob.living.fire_ticks, 40)
    baby = put_in(baby.mob.equipment, %{head: Valimc.Protocol.ItemStack.new("iron_helmet")})
    {:ok, husk} = Body.new("minecraft:husk")
    {:ok, skeleton} = Body.new("minecraft:skeleton")

    for special <- [0.0, 0.5, 1.0] do
      convert(ctx, zombie, "minecraft:husk", special)
      convert(ctx, baby, "minecraft:zombie_villager", special)
      convert(ctx, zombie, "minecraft:drowned", special)
      convert(ctx, baby, "minecraft:drowned", special)
      convert(ctx, husk, "minecraft:zombie", special)
      convert(ctx, skeleton, "minecraft:stray", special)
    end
  end
end
