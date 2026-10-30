defmodule Valimc.NativeMobDragonTest do
  @moduledoc """
  The native ender dragon (VMC-081d, `valimc_core::mobs::boss::dragon`)
  against `Valimc.AI.Dragon.Actor` and `Valimc.Entity.Dragon`: one dragon
  ticking over generated terrain on both sides as its owner ticks it (the
  tick's outside actions, its living timers, `Actor.environment/3` and
  `Actor.tick/3`), with players moving, mobs beside it and crystals
  standing or destroyed. Every tick its record (the brain's phases, flight,
  path, crystal and death clock included), its position, its events, its
  effects and the outside actions' events are equal.
  """
  use ExUnit.Case, async: true

  alias Valimc.AI.Dragon.{Actor, Flight, Phases}
  alias Valimc.AI.World
  alias Valimc.Data.Float32
  alias Valimc.Entity.{Body, Combat}
  alias Valimc.Native
  alias Valimc.NativeMobScene, as: Scene

  @moduletag timeout: 600_000
  @zoom_seed -4_172_144_997_902_289_642
  @dragon "minecraft:ender_dragon"

  setup_all do
    Scene.setup()
  end

  test "the dragon is native" do
    assert {:ok, types} = Native.mob_kinds()
    assert @dragon in types
  end

  ## The scene

  # The arena's columns: the terrain's surface inside the generated chunks,
  # else 60.
  defp heights(blocks) do
    columns =
      for {x, _, z, _} <- Valimc.AI.Dragon.Facts.graph(), do: {x, z}

    for {x, z} <- Enum.uniq([{0, 0} | columns]) do
      h = if x in 0..47 and z in 0..47, do: Scene.surface(blocks, x, z), else: 60
      {x, z, h}
    end
  end

  defp player(n, {x, y, z}, opts \\ []) do
    %{
      uuid: Scene.uuid(1000 + n),
      id: 1000 + n,
      position: {x + 0.3, y * 1.0, z + 0.7},
      mode: Keyword.get(opts, :mode, :survival),
      alive: true,
      invulnerable: false
    }
  end

  defp target(n, {x, y, z}, opts \\ []) do
    %{
      uuid: Scene.uuid(2000 + n),
      position: {x + 0.5, y * 1.0, z + 0.5},
      width: Float32.round(0.6),
      height: Float32.round(1.95),
      recent: Keyword.get(opts, :recent, false)
    }
  end

  defp crystal(n, {x, y, z}) do
    {x, y, z} = {x + 0.5, y * 1.0, z + 0.5}

    %{
      uuid: Scene.uuid(4000 + n),
      entity_id: 4000 + n,
      position: {x, y, z},
      bbox: {x - 1.0, y, z - 1.0, x + 1.0, y + 2.0, z + 1.0}
    }
  end

  # A dragon at `at`: options `:phase`, `:yaw`, `:health`, `:crystal` (the
  # crystal it heals from), `:no_ai`, `:death_time`.
  defp dragon(n, {x, y, z}, opts) do
    {:ok, body} = Body.new(@dragon)
    yaw = Keyword.get(opts, :yaw, 0.0)
    phase = Keyword.get(opts, :phase, 0)

    brain =
      case Keyword.get(opts, :crystal) do
        nil ->
          nil

        crystal ->
          %Actor{
            phases: %Phases{phase: phase, flight: %Flight{position: {x, y, z}, yaw: yaw}},
            crystal: crystal
          }
      end

    data = %{
      body.data
      | phase: phase,
        brain: brain,
        death_time: Keyword.get(opts, :death_time, 0)
    }

    body = %{body | yaw: yaw, head_yaw: yaw, data: data}
    body = %{body | mob: %{body.mob | no_ai: Keyword.get(opts, :no_ai, false)}}
    body = put_in(body.mob.living.health.value, Keyword.get(opts, :health, 200) * 1.0)
    {n, %{entity: %{uuid: Scene.uuid(n), x: x, y: y, z: z}, body: body, revision: 1}}
  end

  # Options: `:ticks`, `:time`, `:players`, `:moves` (each tick's player
  # positions), `:mobs`, `:crystals`, `:alive` (the fight's crystal count),
  # `:counts` (`{tick, count}`), `:previous_kill`, `:griefing`, `:drops`,
  # `:acts` (`{tick, act}`: `{:crystal, uuid, player index | nil}`, `{:hit,
  # part | nil, amount, source, player index | nil, direct type | nil}`,
  # `{:phase, n}`, `{:health, v}`, `{:no_ai, flag}`).
  defp scene(ctx, {id, entry}, opts) do
    heights = heights(ctx.blocks)
    {_, _, h} = Enum.find(heights, &match?({0, 0, _}, &1))

    %{
      dragon: Scene.entry_record(id, entry),
      id: id,
      ticks: Keyword.get(opts, :ticks, 200),
      time: Keyword.get(opts, :time, 1000),
      players: Keyword.get(opts, :players, []),
      moves: Keyword.get(opts, :moves, []),
      mobs: Keyword.get(opts, :mobs, []),
      crystals: Keyword.get(opts, :crystals, []),
      alive: Keyword.get(opts, :alive),
      counts: Keyword.get(opts, :counts, []),
      heights: heights,
      podium: {0, h, 0},
      previous_kill: Keyword.get(opts, :previous_kill, true),
      mob_griefing: Keyword.get(opts, :griefing, true),
      mob_drops: Keyword.get(opts, :drops, true),
      max_y: 319,
      acts: Keyword.get(opts, :acts, [])
    }
  end

  ## The Elixir side

  defp sensed_player(p) do
    {x, y, z} = p.position

    %{
      kind: :player,
      uuid: p.uuid,
      id: p.id,
      x: x,
      y: y,
      z: z,
      eye: Float32.round(1.62),
      width: Float32.round(0.6),
      height: Float32.round(1.8),
      mode: p.mode,
      alive: p.alive,
      invulnerable: p.invulnerable
    }
  end

  defp sensed_mob(m) do
    {x, y, z} = m.position

    %{
      kind: :mob,
      uuid: m.uuid,
      x: x,
      y: y,
      z: z,
      width: m.width,
      height: m.height,
      recent_mob_hurt: m.recent
    }
  end

  defp world(ctx, scene, players, crystals, alive, t) do
    heights = scene.heights

    height = fn x, z ->
      case Enum.find(heights, fn {hx, hz, _} -> hx == x and hz == z end) do
        {_, _, h} -> h
        nil -> 0
      end
    end

    mobs = Enum.map(scene.mobs, &sensed_mob/1)

    %World{
      read: &Scene.read(ctx.blocks, &1),
      players: Enum.map(players, &sensed_player/1),
      mobs: mobs,
      time: scene.time + t,
      max_y: scene.max_y,
      mob_griefing: scene.mob_griefing,
      mob_drops: scene.mob_drops,
      dragon: %{
        height: height,
        podium: scene.podium,
        crystals: alive,
        crystal_bodies:
          for(c <- crystals, do: %{uuid: c.uuid, position: c.position, box: c.bbox}),
        targets: mobs,
        previous_kill: scene.previous_kill,
        flame_uuid: <<9000 + t::64, 0::64>>
      }
    }
  end

  defp attacker(p),
    do: %{uuid: p.uuid, entity_id: p.id, player: true, type: "minecraft:player", mainhand: nil}

  defp act({:crystal, uuid, who}, {body, entity}, state, world) do
    crystal = Enum.find(state.crystals, &(&1.uuid == uuid))
    crystals = Enum.reject(state.crystals, &(&1.uuid == uuid))
    world = %{world | dragon: %{world.dragon | crystal_bodies: crystal_rows(crystals)}}

    player =
      if who do
        p = Enum.at(state.players, who)

        %{
          id: p.id,
          position: p.position,
          height: Float32.round(1.8),
          eligible: p.alive and p.mode not in [:creative, :spectator] and not p.invulnerable,
          attacker: attacker(p)
        }
      end

    direct = %{
      uuid: crystal.uuid,
      entity_id: crystal.entity_id,
      player: false,
      type: "minecraft:end_crystal",
      position: crystal.position
    }

    env = Actor.environment(body, entity, world)
    {body, events} = Actor.crystal_destroyed(body, entity, uuid, direct, player, env)
    {body, events, %{state | crystals: crystals}}
  end

  defp act({:hit, part, amount, source, who, direct}, {body, entity}, state, _world) do
    p = who && Enum.at(state.players, who)
    attacker = p && attacker(p)

    direct =
      if direct,
        do: %{
          uuid: :binary.copy(<<7>>, 16),
          entity_id: 5000,
          player: false,
          type: direct,
          mainhand: nil
        },
        else: attacker

    hit = %{
      source: Valimc.Living.DamageSource.new(String.to_atom(source)),
      amount: amount * 1.0,
      attacker: attacker,
      direct: direct,
      position: if(p, do: p.position, else: {0.5, 64.0, 0.5})
    }

    hit = if part, do: Map.put(hit, :dragon_part, part), else: hit
    {body, events, _} = Combat.hit_body(body, entity, hit)
    {body, events, state}
  end

  defp act({:phase, n}, {body, _}, state, _world),
    do: {put_in(body.data.phase, n), [], state}

  defp act({:health, v}, {body, _}, state, _world),
    do: {put_in(body.mob.living.health.value, v * 1.0), [], state}

  defp act({:no_ai, flag}, {body, _}, state, _world),
    do: {put_in(body.mob.no_ai, flag), [], state}

  defp crystal_rows(crystals),
    do: for(c <- crystals, do: %{uuid: c.uuid, position: c.position, box: c.bbox})

  defp seedless(events) do
    Enum.map(events, fn
      {:sound, id, source, volume, pitch, _seed} -> {:sound, id, source, volume, pitch, 0}
      e -> e
    end)
  end

  defp elixir(ctx, scene) do
    {:ok, body} = Body.restore(scene.dragon)
    %{x: x, y: y, z: z, uuid: uuid} = scene.dragon
    entity = %{uuid: uuid, entity_id: scene.id, x: x, y: y, z: z}

    state = %{
      players: scene.players,
      crystals: scene.crystals,
      alive: scene.alive
    }

    {ticks, _} =
      Enum.map_reduce(0..(scene.ticks - 1), {body, entity, state}, fn t, {body, entity, state} ->
        players =
          case Enum.at(scene.moves, t) do
            nil ->
              state.players

            moved ->
              Enum.zip_with(state.players, moved, fn p, at -> %{p | position: at} end)
          end

        alive =
          Enum.reduce(scene.counts, state.alive, fn
            {^t, count}, _ -> count
            _, alive -> alive
          end)

        state = %{state | players: players, alive: alive}

        {body, act_events, state} =
          for {^t, a} <- scene.acts, reduce: {body, [], state} do
            {body, events, state} ->
              world = world(ctx, scene, state.players, state.crystals, state.alive, t)
              {body, more, state} = act(a, {body, entity}, state, world)
              {body, events ++ more, state}
          end

        {body, _, _} = Body.tick(body)
        world = world(ctx, scene, state.players, state.crystals, state.alive, t)
        env = Actor.environment(body, entity, world)
        {body, {x, y, z} = position, events, effects} = Actor.tick(body, entity, env)
        entity = %{entity | x: x, y: y, z: z}
        record = Scene.entry_record(scene.id, %{entity: entity, body: body})

        {{record, position, events, effects, seedless(act_events)}, {body, entity, state}}
      end)

    ticks
  end

  defp native(ctx, scene) do
    Native.mob_parity_dragon(ctx.blocks.ref, @zoom_seed, ctx.facts, scene)
  end

  # Both sides' ticks equal; the Elixir's.
  defp compare(ctx, scene) do
    expected = elixir(ctx, scene)
    actual = native(ctx, scene)
    assert length(actual) == scene.ticks

    for {{e, n}, t} <- Enum.with_index(Enum.zip(expected, actual)) do
      {er, ep, ee, ef, ea} = e
      {nr, np, ne, nf, na} = n
      assert {t, :act_events, na} == {t, :act_events, ea}
      assert {t, :events, ne} == {t, :events, ee}
      assert {t, :effects, nf} == {t, :effects, ef}
      assert {t, :position, np} == {t, :position, ep}
      assert {t, :record, nr} == {t, :record, er}
    end

    expected
  end

  defp phases(ticks), do: MapSet.new(ticks, fn {r, _, _, _, _} -> r.data.phase end)

  defp effect_kinds(ticks) do
    for {_, _, _, effects, _} <- ticks, e <- effects, into: MapSet.new() do
      if is_tuple(e), do: elem(e, 0), else: e
    end
  end

  defp event_kinds(ticks),
    do: for({_, _, events, _, _} <- ticks, e <- events, into: MapSet.new(), do: elem(e, 0))

  defp health(%{value: value}), do: value
  defp health(value), do: value

  defp surface(ctx, x, z), do: Scene.surface(ctx.blocks, x, z)

  ## Scenes

  test "holding, strafing and fireballs at two players while crystals stand", ctx do
    players = [
      player(0, {20, surface(ctx, 20, 30), 30}),
      player(1, {35, surface(ctx, 35, 12), 12})
    ]

    moves =
      for t <- 0..599 do
        for {p, i} <- Enum.with_index(players) do
          {x, y, z} = p.position
          {x + :math.sin(t / 40 + i) * 3.0, y, z + :math.cos(t / 40 + i) * 3.0}
        end
      end

    scene =
      scene(ctx, dragon(1, {40.5, 95.0, 20.5}, phase: 0, yaw: 30.0),
        ticks: 600,
        players: players,
        moves: moves,
        alive: 6
      )

    ticks = compare(ctx, scene)
    assert MapSet.subset?(MapSet.new([0, 1]), phases(ticks))
    assert MapSet.subset?(MapSet.new([:fireball, :level_event]), effect_kinds(ticks))
    assert :sound in event_kinds(ticks)
  end

  test "approach, landing, perching, breath, attack and takeoff with no crystals", ctx do
    players = [
      player(0, {4, surface(ctx, 4, 6), 6}),
      player(1, {9, surface(ctx, 9, 2), 2})
    ]

    scene =
      scene(ctx, dragon(2, {30.5, 90.0, 30.5}, phase: 2, yaw: 135.0),
        ticks: 900,
        players: players,
        alive: 0,
        acts: [{700, {:phase, 4}}]
      )

    ticks = compare(ctx, scene)
    assert MapSet.subset?(MapSet.new([2, 3, 4, 5, 6, 7]), phases(ticks))
    kinds = effect_kinds(ticks)
    assert :dragon_flame in kinds and :dragon_end_flame in kinds
  end

  test "scanning with no one near charges a distant player, then holds", ctx do
    {x, z} = {44, 44}

    scene =
      scene(ctx, dragon(3, {0.5, surface(ctx, 0, 0) * 1.0, 0.5}, phase: 6),
        ticks: 500,
        players: [player(0, {x, surface(ctx, x, z) + 30, z})],
        alive: 0
      )

    ticks = compare(ctx, scene)
    assert MapSet.subset?(MapSet.new([6, 8, 0]), phases(ticks))
  end

  test "an empty arena scans out into a takeoff, and hovering waits", ctx do
    takeoff =
      scene(ctx, dragon(4, {0.5, surface(ctx, 0, 0) * 1.0, 0.5}, phase: 6), ticks: 220, alive: 4)

    assert 4 in phases(compare(ctx, takeoff))

    hover =
      scene(ctx, dragon(5, {12.5, 85.0, 8.5}, phase: 10, yaw: -45.0),
        ticks: 60,
        acts: [{20, {:no_ai, true}}, {40, {:no_ai, false}}]
      )

    assert phases(compare(ctx, hover)) == MapSet.new([10])
  end

  test "it heals from its crystal, which explodes into its head and turns it on the player",
       ctx do
    players = [player(0, {10, surface(ctx, 10, 10), 10}), player(1, {30, 80, 5}, mode: :creative)]
    crystals = [crystal(1, {18, 80, 18}), crystal(2, {44, 85, 2}), crystal(3, {-30, 85, -30})]

    scene =
      scene(ctx, dragon(6, {24.5, 92.0, 24.5}, phase: 0, health: 150),
        ticks: 320,
        players: players,
        crystals: crystals,
        alive: 3,
        counts: [{150, 2}, {250, 1}],
        acts: [
          {150, {:crystal, Scene.uuid(4001), 0}},
          {151, {:crystal, Scene.uuid(4002), 0}},
          {250, {:crystal, Scene.uuid(4003), nil}}
        ]
      )

    ticks = compare(ctx, scene)
    healed = for {r, _, _, _, _} <- ticks, do: health(r.mob.living.health)
    assert Enum.max(Enum.take(healed, 150)) > 150.0
    assert :scan_crystals in effect_kinds(ticks)
    # The first crystal turns it on the player; the second, the one it
    # heals from by then, explodes into its head.
    assert elem(Enum.at(ticks, 150), 0).data.phase == 1
    assert [{:damage, :explosion, 1000, 4002, nil} | _] = elem(Enum.at(ticks, 151), 4)
  end

  test "its parts take hits as vanilla's do, sitting and in flight", ctx do
    players = [player(0, {6, surface(ctx, 6, 6), 6})]

    hits =
      [
        {5, {:hit, 0, 8.0, "player_attack", 0, nil}},
        {16, {:hit, 2, 8.0, "player_attack", 0, nil}},
        {27, {:hit, 6, 3.0, "player_attack", 0, nil}},
        {38, {:hit, nil, 12.0, "player_attack", 0, nil}},
        {49, {:hit, 1, 6.0, "arrow", 0, "minecraft:arrow"}},
        {60, {:hit, 3, 6.0, "in_fire", nil, nil}},
        {71, {:hit, 0, 6.0, "generic", nil, nil}},
        {82, {:hit, 0, 0.005, "player_attack", 0, nil}},
        {93, {:hit, 0, 9.0, "explosion", nil, nil}},
        # Sitting: arrows ignite, its damage counts toward a takeoff.
        {110, {:phase, 6}},
        {112, {:hit, 0, 6.0, "arrow", 0, "minecraft:arrow"}},
        {124, {:hit, 0, 20.0, "player_attack", 0, nil}},
        {136, {:hit, 0, 20.0, "player_attack", 0, nil}},
        {148, {:hit, 0, 20.0, "player_attack", 0, nil}}
      ]

    scene =
      scene(ctx, dragon(7, {14.5, 88.0, 14.5}, phase: 0, yaw: 60.0),
        ticks: 180,
        players: players,
        alive: 2,
        acts: hits
      )

    ticks = compare(ctx, scene)
    assert 4 in phases(ticks)
    assert Enum.any?(ticks, fn {_, _, _, _, a} -> a != [] end)
  end

  test "a killing blow leaves it dying through the whole death sequence", ctx do
    players = [player(0, {6, surface(ctx, 6, 6), 6})]

    scene =
      scene(ctx, dragon(8, {10.5, 90.0, 10.5}, phase: 0, health: 10),
        ticks: 330,
        players: players,
        alive: 0,
        previous_kill: false,
        acts: [{3, {:hit, 0, 50.0, "player_attack", 0, nil}}]
      )

    ticks = compare(ctx, scene)
    assert 9 in phases(ticks)
    kinds = effect_kinds(ticks)
    assert :dragon_xp in kinds and :dragon_killed in kinds and :discard in kinds
    assert :global_event in kinds and :particles in event_kinds(ticks)

    xp =
      ticks
      |> Enum.take_while(fn {_, _, _, effects, _} -> :discard not in effects end)
      |> Enum.concat([Enum.find(ticks, fn {_, _, _, effects, _} -> :discard in effects end)])
      |> Enum.flat_map(fn {_, _, _, effects, _} -> for {:dragon_xp, n, _} <- effects, do: n end)
      |> Enum.sum()

    assert xp == 10 * 960 + 2400
  end

  test "a dying dragon on a repeat kill, and one dead without drops, end with their bursts",
       ctx do
    scene =
      scene(ctx, dragon(9, {-8.5, 85.0, 12.5}, phase: 9, health: 0, death_time: 140), ticks: 60)

    ticks = compare(ctx, scene)
    {_, _, _, last, _} = List.last(ticks)
    assert :dragon_killed in last and :discard in last
    assert {:dragon_xp, 100, List.last(ticks) |> elem(1)} in last

    drops =
      scene(ctx, dragon(10, {-8.5, 85.0, 12.5}, health: 0, death_time: 190),
        ticks: 10,
        drops: false
      )

    refute :dragon_xp in effect_kinds(compare(ctx, drops))
  end

  test "it breaks through terrain with griefing, and hits a wall without", ctx do
    {x, z} = {20, 20}
    y = surface(ctx, x, z) - 4

    for griefing <- [true, false] do
      scene =
        scene(ctx, dragon(11, {x + 0.5, y * 1.0, z + 0.5}, phase: 0, yaw: 90.0),
          ticks: 80,
          griefing: griefing,
          alive: 3
        )

      kinds = effect_kinds(compare(ctx, scene))
      assert :dragon_break in kinds == griefing
    end
  end

  test "its wings push and its head bites players and mobs beside it", ctx do
    at = {16.5, 86.0, 16.5}

    players = [
      player(0, {16, 84, 12}),
      player(1, {20, 86, 16}),
      player(2, {12, 86, 17}, mode: :spectator)
    ]

    mobs = [
      target(0, {13, 86, 16}),
      target(1, {19, 85, 18}, recent: true),
      target(2, {16, 87, 10})
    ]

    moves =
      for t <- 0..119 do
        for p <- players do
          {px, py, pz} = p.position
          {px + :math.sin(t / 9) * 2.0, py, pz + :math.cos(t / 11) * 2.0}
        end
      end

    for phase <- [0, 6] do
      scene =
        scene(ctx, dragon(12, at, phase: phase),
          ticks: 120,
          players: players,
          moves: moves,
          mobs: mobs,
          alive: 0
        )

      assert :dragon_contact in effect_kinds(compare(ctx, scene))
    end
  end
end
