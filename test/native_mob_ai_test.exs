defmodule Valimc.NativeMobAITest do
  @moduledoc """
  The native mob AI (VMC-081d, `valimc_core::mobs::ai`) against
  `Valimc.AI` over generated terrain held in a region's store: a mob's
  goals, navigation and look control tick by tick (its target and goal
  selectors, the goals' draws, the path search and its following, the
  controls), random walk targets, and single look, body rotation and
  smooth swimming steps. Both sides start from the same mob and its random;
  every observation, the random state included, must be equal.
  """
  use ExUnit.Case, async: true

  alias Valimc.AI.{
    Goals,
    Look,
    Mind,
    Navigation,
    RandomPos,
    Selector,
    Self,
    SmoothSwimming,
    World
  }

  alias Valimc.Native
  alias Valimc.Worldgen.Generator

  @seed 20_261_029
  @zoom_seed -4_172_144_997_902_289_642
  @chunks for cx <- 0..2, cz <- 0..2, do: {cx, cz}

  setup_all do
    Valimc.AI.NativeFacts.install!()
    Valimc.AI.Paths.install!()
    images = Valimc.World.Blocks.lit_images(Generator.columns({:vanilla, @seed}, @chunks), true)
    size = Valimc.Data.Grid.region_size()
    absent = for cx <- 0..(size - 1), cz <- 0..(size - 1), {cx, cz} not in @chunks, do: {cx, cz}
    {:ok, blocks} = Valimc.World.Blocks.new({0, 0}, %{}, images, MapSet.new(absent))
    handles = Valimc.World.Blocks.snapshots(blocks, for(c <- @chunks, do: {c, nil}), 1)
    view = {:rows, Enum.reject(handles, &is_nil/1), Valimc.Protocol.Data.block("air")}
    %{blocks: blocks, view: view}
  end

  ## The Elixir side

  defp world(blocks, view, players, mobs, time, difficulty) do
    read = fn {x, y, z} ->
      case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
        {:ok, <<state::16>>} -> state
        _ -> nil
      end
    end

    %World{
      read: read,
      light: &Valimc.World.Blocks.light(blocks, &1),
      biome: &Valimc.World.Blocks.biome(blocks, @zoom_seed, &1),
      search: fn request ->
        [result] = Valimc.AI.Paths.find(view, [request])
        result
      end,
      players: players,
      mobs: mobs,
      by_type: Enum.group_by(mobs, & &1.type),
      index: Map.new(mobs, &{&1.uuid, &1}),
      spatial: Valimc.AI.Spatial.new(mobs),
      time: time,
      difficulty: difficulty,
      random: Valimc.AI.Random.new(7)
    }
  end

  defp sensed_player(p) do
    %{
      kind: :player,
      uuid: p.uuid,
      id: p.id,
      x: elem(p.position, 0),
      y: elem(p.position, 1),
      z: elem(p.position, 2),
      yaw: p.yaw,
      pitch: p.pitch,
      eye: 1.62,
      width: 0.6,
      height: 1.8,
      mode: p.mode,
      invulnerable: p.mode == :creative,
      alive: true,
      crouching: false,
      swimming: false,
      invisible: false,
      armor_cover: 0.0,
      movement: {0.0, 0.0, 0.0},
      velocity: {0.0, 0.0, 0.0},
      health: 20.0,
      effects: MapSet.new(),
      equipment: if(p.mainhand, do: %{mainhand: p.mainhand}, else: %{})
    }
  end

  defp sensed_mob(uuid, id, type, {x, y, z}, {w, h, e}) do
    %{
      kind: :mob,
      uuid: uuid,
      id: id,
      type: type,
      x: x,
      y: y,
      z: z,
      yaw: 0.0,
      pitch: 0.0,
      eye: e,
      width: w,
      height: h,
      box: nil,
      alive: true,
      recent_mob_hurt: false,
      baby: false,
      huntable: true,
      target: nil,
      in_love: 0,
      age: 0,
      data: %{},
      own: nil,
      in_water: false,
      invulnerable: false,
      killed_by: nil,
      panicking: false,
      memories: nil,
      sleeping: nil,
      path_step: nil
    }
  end

  defp goal({:float}), do: {Goals.Float, %{}}
  defp goal({:panic, s}), do: {Goals.Panic, Goals.Panic.new(s)}

  defp goal({:stroll, s, water_avoiding, interval}),
    do:
      {Goals.RandomStroll,
       Goals.RandomStroll.new(s, water_avoiding: water_avoiding, interval: interval)}

  defp goal({:look_at_player, d, p}), do: {Goals.LookAtPlayer, Goals.LookAtPlayer.new(d, p)}
  defp goal({:look_around}), do: {Goals.RandomLookAround, Goals.RandomLookAround.new()}

  defp goal({:melee, s, unseen, arms}),
    do: {Goals.MeleeAttack, Goals.MeleeAttack.new(s, unseen, raise_arms: arms)}

  defp goal({:nat_player, must_see, interval}),
    do:
      {Goals.NearestAttackableTarget,
       Goals.NearestAttackableTarget.new(:player, nil, must_see, interval: interval)}

  defp goal({:nat_mob, types, must_see}),
    do: {Goals.NearestAttackableTarget, Goals.NearestAttackableTarget.new(:mob, types, must_see)}

  defp goal({:hurt_by, alert, types}),
    do: {Goals.HurtByTarget, Goals.HurtByTarget.new(alert: alert, alert_types: types)}

  defp goal({:restriction, s}),
    do: {Goals.MoveTowardsRestriction, Goals.MoveTowardsRestriction.new(s)}

  defp goal({:towards_target, s, within}),
    do: {Goals.MoveTowardsTarget, Goals.MoveTowardsTarget.new(s, within)}

  defp goal({:tempt, s, item, scare}),
    do: {Goals.Tempt, Goals.Tempt.new(s, &(&1 == item), scare)}

  defp goal({:avoid_players, d, w, s}),
    do: {Goals.AvoidEntity, Goals.AvoidEntity.new(&(&1.kind == :player), d, w, s)}

  defp goal({:restrict_sun}), do: {Goals.RestrictSun, Goals.RestrictSun.new()}
  defp goal({:flee_sun, s}), do: {Goals.FleeSun, Goals.FleeSun.new(s)}
  defp goal({:leap, yd}), do: {Goals.LeapAtTarget, Goals.LeapAtTarget.new(yd)}
  defp goal({:breath_air}), do: {Goals.BreathAir, Goals.BreathAir.new()}
  defp goal({:try_find_liquid}), do: {Goals.TryFindLiquid, Goals.TryFindLiquid.new()}
  defp goal({:climb_powder_snow}), do: {Goals.ClimbPowderSnow, %{}}
  defp goal({:ocelot_attack}), do: {Goals.OcelotAttack, Goals.OcelotAttack.new()}

  defp selector(specs) do
    specs
    |> Enum.map(fn {priority, flags, spec} ->
      {module, state} = goal(spec)
      Selector.goal(priority, module, flags, state)
    end)
    |> List.to_tuple()
  end

  defp self_of(m, world) do
    mob = Valimc.Entity.Mob.new(m.kind)
    living = mob.living

    mob = %{
      mob
      | living: %{
          living
          | health: %{living.health | value: m.health},
            fire_ticks: m.fire_ticks,
            air_supply: m.air
        },
        motion: %{mob.motion | water: m.water},
        home: m.home
    }

    navigation = Navigation.new(m.navigation, breaching: m.breaching, climber: m.climber)

    navigation =
      if Enum.any?(m.goals, &match?({_, _, {:float}}, &1)) and m.navigation in [:ground, :fly],
        do: %{navigation | can_float: true},
        else: navigation

    {x, y, z} = m.position
    {w, h, e} = m.dimensions

    %Self{
      id: m.id,
      uuid: m.uuid,
      type: m.kind,
      x: x,
      y: y,
      z: z,
      yaw: m.yaw,
      pitch: m.pitch,
      head: m.head,
      on_ground: m.on_ground,
      velocity: {0.0, 0.0, 0.0},
      mob: mob,
      mind: %Mind{
        random: m.random,
        goals: selector(m.goals),
        targets: selector(m.targets),
        navigation: navigation,
        body_yaw: m.body_yaw
      },
      facts: Valimc.AI.Facts.mob(m.kind),
      width: w,
      height: h,
      eye: e,
      world: world,
      data: %{}
    }
  end

  # The AI step the native parity runs: tick, idle time and sight, the
  # selectors (a full update on alternate ticks by id), navigation, the look
  # control, a scripted move toward the wanted position and the body control.
  defp step(%Self{} = self, step) do
    self = Self.mind(self, &%{&1 | tick: &1.tick + 1})
    self = Self.mind(self, &%{&1 | no_action: &1.no_action + 1, sight: %{}})
    tick = self.mind.tick

    self =
      if rem(tick + self.id, 2) != 0 and tick > 1 do
        self |> Selector.tick_running(:targets, false) |> Selector.tick_running(:goals, false)
      else
        self |> Selector.tick(:targets) |> Selector.tick(:goals)
      end

    self = self |> Navigation.tick() |> Look.tick()
    {x, z} = {self.x, self.z}

    self =
      case self.mob.motion.control do
        {:move_to, {tx, _, tz}, _} ->
          {dx, dz} = {tx - x, tz - z}
          l = :math.sqrt(dx * dx + dz * dz)

          if l > 0.0 do
            s = min(l, step)
            %{self | x: x + dx / l * s, z: z + dz / l * s}
          else
            self
          end

        _ ->
          self
      end

    Look.body(self, {x, z})
  end

  defp look(nil), do: nil
  defp look(l), do: {l.x, l.y, l.z, l.y_max, l.x_max, l.cooldown}

  defp path(%{path: %{nodes: nodes, index: index}, speed: speed}),
    do: {index, Tuple.to_list(nodes), speed}

  defp path(_nav), do: nil

  defp effect({:sound, id, _source, volume, pitch, _seed}), do: {:sound, id, volume, pitch}
  defp effect({:sound_at, id, _source, at, volume, pitch}), do: {:sound_at, id, at, volume, pitch}
  defp effect({:shoot, %{target: t, power: p, pitch: pitch}}), do: {:shoot, t, p, pitch}
  defp effect({:swing, _} = e), do: e
  defp effect({:attack, _} = e), do: e
  defp effect({:alert, _, _} = e), do: e
  defp effect({:event, _} = e), do: e
  defp effect(_), do: {:other}

  defp running(self, which), do: for(m <- Selector.running(self, which), do: inspect(m))

  defp observe(%Self{mind: mind} = self) do
    {mind.random, {self.x, self.y, self.z}, {self.yaw, self.pitch, self.head, mind.body_yaw},
     look(mind.look), self.mob.motion.control, path(mind.navigation), mind.target,
     mind.aggressive, mind.jump, running(self, :goals), running(self, :targets),
     self.effects |> Enum.reverse() |> Enum.map(&effect/1)}
  end

  defp think(blocks, view, scene) do
    m = scene.mob
    players = Enum.map(scene.players, &sensed_player/1)
    me = sensed_mob(m.uuid, m.id, m.kind, m.position, m.dimensions)

    others =
      for o <- scene.others, do: sensed_mob(o.uuid, o.id, o.kind, o.position, o.dimensions)

    world = world(blocks, view, players, [me | others], scene.time, scene.difficulty)
    self = self_of(m, world)

    {observations, _} =
      Enum.map_reduce(0..(scene.ticks - 1), self, fn i, self ->
        self = %{self | world: %{self.world | time: scene.time + i}}

        self =
          case scene.hurt do
            {^i, who, type} ->
              type = type |> String.replace_prefix("minecraft:", "") |> String.to_atom()
              %{self | mind: Valimc.AI.hurt(self.mind, {:player, who}, type)}

            _ ->
              self
          end

        self = step(self, scene.step)
        observation = observe(self)
        world = World.resense(self.world, self.uuid, &%{&1 | x: self.x, y: self.y, z: self.z})
        {observation, %{self | effects: [], world: world, mind: %{self.mind | jump: false}}}
      end)

    observations
  end

  ## Scenes

  defp uuid(n), do: <<n::64, n * 7919::64>>

  defp surface(blocks, x, z) do
    world = world(blocks, nil, [], [], 0, :normal)
    World.motion_blocking(world, x, z)
  end

  # Land columns: the block below the surface is no fluid.
  defp land(blocks, count, rand) do
    world = world(blocks, nil, [], [], 0, :normal)

    Stream.unfold(rand, fn rand ->
      {x, rand} = :rand.uniform_s(24, rand)
      {z, rand} = :rand.uniform_s(24, rand)
      {{x + 11, z + 11}, rand}
    end)
    |> Stream.map(fn {x, z} -> {x, surface(blocks, x, z), z} end)
    |> Stream.filter(fn {x, y, z} -> World.fluid(world, {x, y - 1, z}) == :empty end)
    |> Enum.take(count)
    |> then(&{&1, :done})
  end

  defp mob(n, kind, {x, y, z}, goals, targets, opts \\ []) do
    %{
      uuid: uuid(n),
      id: n,
      kind: kind,
      position: {x + 0.5, y * 1.0, z + 0.5},
      yaw: Keyword.get(opts, :yaw, 0.0),
      pitch: 0.0,
      head: Keyword.get(opts, :yaw, 0.0),
      body_yaw: Keyword.get(opts, :yaw, 0.0),
      on_ground: true,
      health: Keyword.get(opts, :health, 20.0),
      fire_ticks: 0,
      air: Keyword.get(opts, :air, 300),
      water: Keyword.get(opts, :water, 0.0),
      random: Valimc.AI.Random.new(uuid(n)),
      dimensions: Keyword.get(opts, :dimensions, {0.6, 1.95, 1.74}),
      navigation: Keyword.get(opts, :navigation, :ground),
      breaching: false,
      climber: Keyword.get(opts, :climber, false),
      home: Keyword.get(opts, :home),
      goals: goals,
      targets: targets
    }
  end

  defp player(n, {x, y, z}, opts \\ []) do
    %{
      uuid: uuid(1000 + n),
      id: 1000 + n,
      position: {x + 0.3, y * 1.0, z + 0.7},
      yaw: 12.5,
      pitch: -3.0,
      mode: Keyword.get(opts, :mode, :survival),
      mainhand: Keyword.get(opts, :mainhand)
    }
  end

  @zombie [
    {0, [:move], {:float}},
    {2, [:move, :look], {:melee, 1.0, false, true}},
    {5, [:move], {:restriction, 1.0}},
    {7, [:move], {:stroll, 1.0, true, 120}},
    {8, [:look], {:look_at_player, 8.0, 0.02}},
    {8, [:move, :look], {:look_around}}
  ]
  @zombie_targets [
    {1, [:target], {:hurt_by, true, ["minecraft:zombie"]}},
    {2, [:target], {:nat_player, true, 10}},
    {3, [:target], {:nat_mob, ["minecraft:iron_golem"], true}}
  ]

  defp compare(blocks, view, scene) do
    expected = think(blocks, view, scene)
    native = Native.mob_parity_ai_think(blocks.ref, @zoom_seed, scene)
    assert length(native) == scene.ticks

    for {{e, n}, i} <- Enum.with_index(Enum.zip(expected, native)),
        do: assert({i, n} == {i, e})

    expected
  end

  test "a zombie hunts a player, strolls and looks around", %{blocks: blocks, view: view} do
    {spots, _} = land(blocks, 12, :rand.seed_s(:exsss, 81))

    for {at, k} <- Enum.with_index(Enum.chunk_every(spots, 2)) do
      [here, there] = at
      zombie = mob(k + 1, "minecraft:zombie", here, @zombie, @zombie_targets, yaw: 30.0 * k)

      scene = %{
        mob: zombie,
        others: [],
        players: [player(k, there)],
        time: 1000 + k,
        ticks: 120,
        step: 0.2,
        difficulty: :normal,
        hurt: nil
      }

      compare(blocks, view, scene)
    end
    |> List.flatten()
    |> then(fn observed ->
      assert Enum.any?(observed, &(elem(&1, 6) != nil))
      assert Enum.any?(observed, &(elem(&1, 5) != nil))
      assert Enum.any?(observed, &match?({:move_to, _, _}, elem(&1, 4)))
      assert Enum.any?(observed, &("Valimc.AI.Goals.RandomLookAround" in elem(&1, 9)))
      assert Enum.any?(observed, &Enum.any?(elem(&1, 11), fn e -> match?({:attack, _}, e) end))
    end)
  end

  test "a hurt zombie turns on its attacker and alerts others", %{blocks: blocks, view: view} do
    {[here, there, other], _} = land(blocks, 3, :rand.seed_s(:exsss, 82))
    zombie = mob(7, "minecraft:zombie", here, @zombie, @zombie_targets)
    {ox, oy, oz} = other

    friend = %{
      uuid: uuid(8),
      id: 8,
      kind: "minecraft:zombie",
      position: {ox + 0.5, oy * 1.0, oz + 0.5},
      dimensions: {0.6, 1.95, 1.74}
    }

    hurter = player(3, there)

    scene = %{
      mob: zombie,
      others: [friend],
      players: [hurter],
      time: 5000,
      ticks: 60,
      step: 0.25,
      difficulty: :normal,
      hurt: {3, hurter.uuid, "minecraft:player_attack"}
    }

    observed = compare(blocks, view, scene)
    assert Enum.any?(observed, &("Valimc.AI.Goals.HurtByTarget" in elem(&1, 10)))
    assert Enum.any?(observed, &Enum.any?(elem(&1, 11), fn e -> match?({:alert, _, _}, e) end))
  end

  test "a cow panics, follows food and strolls", %{blocks: blocks, view: view} do
    {spots, _} = land(blocks, 8, :rand.seed_s(:exsss, 83))
    wheat = Valimc.Protocol.ItemTypes.id("minecraft:wheat")

    goals = [
      {0, [:move], {:float}},
      {1, [:move], {:panic, 2.0}},
      {3, [:move, :look], {:tempt, 1.25, wheat, false}},
      {5, [:move], {:stroll, 1.0, true, 10}},
      {6, [:look], {:look_at_player, 6.0, 0.02}},
      {7, [:move, :look], {:look_around}}
    ]

    for {[here, there], k} <- Enum.with_index(Enum.chunk_every(spots, 2)) do
      cow =
        mob(20 + k, "minecraft:cow", here, goals, [], dimensions: {0.9, 1.4, 1.3}, yaw: -45.0)

      holding = if rem(k, 2) == 0, do: wheat

      scene = %{
        mob: cow,
        others: [],
        players: [player(k, there, mainhand: holding)],
        time: 200 + k,
        ticks: 100,
        step: 0.15,
        difficulty: :easy,
        hurt: if(k == 3, do: {5, uuid(1000 + k), "minecraft:player_attack"})
      }

      compare(blocks, view, scene)
    end
    |> List.flatten()
    |> then(fn observed ->
      assert Enum.any?(observed, &("Valimc.AI.Goals.Tempt" in elem(&1, 9)))
      assert Enum.any?(observed, &("Valimc.AI.Goals.Panic" in elem(&1, 9)))
      assert Enum.any?(observed, &("Valimc.AI.Goals.RandomStroll" in elem(&1, 9)))
    end)
  end

  test "a skittish mob avoids players and leaps at targets", %{blocks: blocks, view: view} do
    {[here, there], _} = land(blocks, 2, :rand.seed_s(:exsss, 84))
    {hx, hy, hz} = here

    third =
      Enum.find_value(for(dx <- 2..4, dz <- -3..3, do: {dx, dz}), fn {dx, dz} ->
        if surface(blocks, hx + dx, hz + dz) == hy, do: {hx + dx, hy, hz + dz}
      end)

    goals = [
      {1, [:move], {:avoid_players, 8.0, 1.0, 1.2}},
      {3, [:jump, :move], {:leap, 0.4}},
      {4, [:move, :look], {:melee, 1.0, true, false}},
      {6, [:move], {:towards_target, 0.9, 32.0}},
      {7, [:move], {:stroll, 0.8, false, 60}}
    ]

    spider =
      mob(40, "minecraft:spider", here, goals, [{2, [:target], {:nat_player, false, 2}}],
        dimensions: {1.4, 0.9, 0.65},
        climber: true
      )

    scene = %{
      mob: spider,
      others: [],
      players: [player(1, there), player(2, third)],
      time: 9000,
      ticks: 80,
      step: 0.3,
      difficulty: :hard,
      hurt: nil
    }

    observed = compare(blocks, view, scene)
    assert Enum.any?(observed, &("Valimc.AI.Goals.AvoidEntity" in elem(&1, 9)))
  end

  test "random walk targets draw as the Elixir's", %{blocks: blocks, view: view} do
    {spots, _} = land(blocks, 10, :rand.seed_s(:exsss, 85))

    cases =
      for {spot, k} <- Enum.with_index(spots),
          {op, args} <- [
            {:default, {10, 7}},
            {:land, {10, 7}},
            {:land, {15, 7}},
            {:away, {16, 7, {16.0, 70.0, 16.0}}},
            {:towards, {16, 7, {30.5, 64.0, 2.5}, Valimc.Data.Float32.round(:math.pi() / 2)}},
            {:land_away, {16, 7, {20.0, 70.0, 30.0}}},
            {:land_towards, {12, 7, {1.0, 70.0, 40.0}}},
            {:swimmable, {10, 7}},
            {:swim_target, {0, 0}}
          ] do
        home = if rem(k, 3) == 0, do: {{20, 70, 20}, 6}
        {op, mob(60 + k, "minecraft:zombie", spot, [], [], home: home), args}
      end

    native = Native.mob_parity_ai_random(blocks.ref, @zoom_seed, cases)
    world = world(blocks, view, [], [], 0, :normal)

    expected =
      for {op, m, args} <- cases do
        self = self_of(m, world)

        {pos, self} =
          case {op, args} do
            {:default, {h, v}} -> RandomPos.default(self, h, v)
            {:land, {h, v}} -> RandomPos.land(self, h, v)
            {:away, {h, v, from}} -> RandomPos.default_away(self, h, v, from)
            {:towards, {h, v, to, r}} -> RandomPos.default_towards(self, h, v, to, r)
            {:land_away, {h, v, from}} -> RandomPos.land_away(self, h, v, from)
            {:land_towards, {h, v, to}} -> RandomPos.land_towards(self, h, v, to)
            {:swimmable, {h, v}} -> RandomPos.swimmable(self, h, v)
            {:swim_target, _} -> RandomPos.swim_target(self)
          end

        {pos, self.mind.random}
      end

    for {{e, n}, c} <- Enum.zip(Enum.zip(expected, native), cases), do: assert({c, n} == {c, e})
    assert Enum.count(expected, &(elem(&1, 0) != nil)) > length(cases) / 4
  end

  test "look, body and smooth swimming controls step as the Elixir's", %{
    blocks: blocks,
    view: view
  } do
    rand = :rand.seed_s(:exsss, 86)
    {[spot], _} = land(blocks, 1, rand)
    world = world(blocks, view, [], [], 0, :normal)
    f = &Valimc.Data.Float32.round/1

    {cases, _} =
      Enum.map_reduce(1..160, rand, fn k, rand ->
        {a, rand} = :rand.uniform_real_s(rand)
        {b, rand} = :rand.uniform_real_s(rand)
        {c, rand} = :rand.uniform_real_s(rand)
        {x, y, z} = spot
        yaw = f.(a * 720.0 - 360.0)

        m =
          mob(200 + k, "minecraft:zombie", spot, [], [],
            yaw: yaw,
            water: if(rem(k, 3) == 0, do: 0.5, else: 0.0)
          )

        m = %{m | pitch: f.(b * 60.0 - 30.0), head: f.(c * 360.0 - 180.0)}

        look =
          if rem(k, 4) != 0,
            do: {x + a * 20 - 10, y + b * 6 - 2, z + c * 20 - 10, 10.0 + k, 40.0, rem(k, 3)}

        navigating = rem(k, 5) < 3

        case rem(k, 4) do
          0 ->
            {{:look, m, {look, navigating}}, rand}

          1 ->
            {{:body, m, {x + 0.5 - a * 0.001, z + 0.5 + b * 0.5, f.(c * 90.0), rem(k, 25)}}, rand}

          2 ->
            wanted = if rem(k, 7) != 0, do: {x + a * 8, y + b * 4 - 2, z - c * 8}
            args = {10.0 + k, 10.0, 0.02, 0.1, rem(k, 2) == 0, wanted, 1.0 + a, navigating}
            {{:swim_move, m, args}, rand}

          3 ->
            {{:swim_look, m, {look, navigating, 10.0 + rem(k, 30)}}, rand}
        end
      end)

    native = Native.mob_parity_ai_controls(blocks.ref, @zoom_seed, cases)

    expected =
      for {op, m, args} <- cases do
        self = self_of(m, world)
        nav_path = %{nodes: {{0, 0, 0}}, types: {0}, index: 0, target: {0, 0, 0}, reached: false}

        navigating = fn self, on ->
          Self.mind(self, &%{&1 | navigation: %{&1.navigation | path: if(on, do: nav_path)}})
        end

        to_look = fn
          nil -> nil
          {x, y, z, ym, xm, cd} -> %{x: x, y: y, z: z, y_max: ym, x_max: xm, cooldown: cd}
        end

        self =
          case op do
            :look ->
              {l, on} = args
              self |> Self.mind(&%{&1 | look: to_look.(l)}) |> navigating.(on) |> Look.tick()

            :body ->
              {xo, zo, head, time} = args

              self
              |> Self.mind(&%{&1 | stable_head: head, stable_time: time})
              |> Look.body({xo, zo})

            :swim_move ->
              {mx, my, iw, out, gravity, wanted, speed, on} = args
              self = if wanted, do: Self.move_to(self, wanted, speed), else: self
              self = navigating.(self, on)

              SmoothSwimming.move(self, %{
                max_x: mx,
                max_y: my,
                in_water: iw,
                out: out,
                gravity: gravity
              })

            :swim_look ->
              {l, on, max} = args

              self
              |> Self.mind(&%{&1 | look: to_look.(l)})
              |> navigating.(on)
              |> SmoothSwimming.look(max)
          end

        set =
          case self.mob.motion.set do
            {speed, _, {a, b, c}} -> {speed, a, b, c}
            _ -> nil
          end

        {self.yaw, self.pitch, self.head, self.mind.body_yaw, self.mind.stable_head,
         self.mind.stable_time, look(self.mind.look), set}
      end

    for {{e, n}, c} <- Enum.zip(Enum.zip(expected, native), cases), do: assert({c, n} == {c, e})
  end
end
