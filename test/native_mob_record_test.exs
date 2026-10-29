defmodule Valimc.NativeMobRecordTest do
  @moduledoc """
  VMC-081d: a mob record read into the native model and written back is the
  term Elixir writes (`Store.record/1`), for fresh, spawned, generated and
  ticked mobs of many families and for every saved option.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Valimc.AI
  alias Valimc.Data.{Blocks, EffectTypes, EntityTypes, Float32}
  alias Valimc.Entity.{Body, Mob, MobTicks, Store}
  alias Valimc.Living.Attributes
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  setup_all do
    types =
      for name <- EntityTypes.names(), EntityTypes.living?(name) do
        {:ok, body} = Body.generated(name, nil, false)

        {name, true, Mob.base(name, %{}, "minecraft:max_health") * 1.0, Map.keys(body.data)}
      end

    {:ok, facts} =
      Native.mob_record_facts(%{
        effect_count: EffectTypes.count(),
        absorption_effect: EffectTypes.id("absorption"),
        max_absorption: Attributes.max_absorption() * 1.0,
        types: types
      })

    %{facts: facts}
  end

  @types ~w(cow sheep pig chicken rabbit zombie husk drowned skeleton creeper spider
            villager axolotl dolphin squid glow_squid cod salmon pufferfish slime
            magma_cube ghast enderman witch phantom bat turtle strider cat mooshroom
            iron_golem piglin hoglin guardian shulker wandering_trader endermite)

  test "fresh, spawned and generated mobs", %{facts: facts} do
    for name <- @types, type = "minecraft:" <> name do
      {:ok, fresh} = Body.new(type)
      {:ok, spawned} = Body.spawned(type, :natural)
      {:ok, generated} = Body.generated(type, nil, true)

      for body <- [fresh, spawned, generated], do: assert_round_trip(facts, body)
    end
  end

  test "every saved option", %{facts: facts} do
    {:ok, zombie} = Body.spawned("minecraft:zombie", :spawner)
    speed = EffectTypes.id("speed")
    absorption = EffectTypes.id("absorption")
    sword = %ItemStack{item_id: ItemTypes.id("minecraft:iron_sword"), count: 1}
    helmet = %ItemStack{item_id: ItemTypes.id("minecraft:iron_helmet"), count: 1}

    mob =
      zombie.mob
      |> Mob.add_effect(speed, {600, 1, false, true, true})
      |> Mob.add_effect(absorption, {-1, 0, true, false, true})
      |> then(fn mob ->
        effects = Map.update!(mob.living.effects, speed, &(&1 ++ [{100, 0, false, true, true}]))
        %{mob | living: %{mob.living | effects: effects, absorption: 4.0}}
      end)

    mob = %{
      mob
      | equipment: %{mainhand: sword, head: helmet},
        drop_chances: %{mainhand: 2.0, head: 0.25},
        attributes:
          Map.merge(mob.attributes, %{
            "minecraft:max_health" => %{base: 30.0, modifiers: []},
            "minecraft:follow_range" => %{
              base: nil,
              modifiers: [{"minecraft:random_spawn_bonus", 0.0123, 1}]
            }
          }),
        ai: %{
          random: 0xFFFF_FFFF_FFFF,
          memories: %{home: {:global_pos, "minecraft:overworld", {1, 2, 3}}, ref: make_ref()}
        },
        no_ai: true,
        hurt_by_player: <<9::128>>,
        player_memory: 50,
        persistent: true,
        left_handed: true,
        can_pick_up_loot: true,
        leash: %{holder: {:player, <<5::128>>}, id: 12, momentum: 0.5, restored: false},
        home: {{1, 64, -3}, 16},
        using: {:off_hand, 7},
        living: %{
          mob.living
          | fire_ticks: 120,
            air_supply: -5,
            freezing: %{mob.living.freezing | frozen_ticks: 40},
            health: %{mob.living.health | value: 13.5, hurt_ticks: 4, death_ticks: 0}
        }
    }

    body = %{
      Body.name(%{zombie | mob: mob}, %{"text" => "Bob", "color" => "red"})
      | yaw: -0.0,
        pitch: 12.300000190734863,
        head_yaw: 359.5,
        velocity: {1.0e-7, -0.0784000015258789, -0.0},
        on_ground: true,
        no_gravity: true,
        preserved: "{Tags:[\"x\"]}",
        portal_cooldown: 300,
        data: %{zombie.data | baby: true, in_water: 12}
    }

    assert_round_trip(facts, body, 3)

    knot =
      put_in(body.mob.leash, %{
        holder: {:knot, {4, 70, -8}},
        id: nil,
        momentum: 0.0,
        restored: true
      })

    assert_round_trip(facts, knot)

    # A dying, burning mob without memory.
    dying =
      update_in(body.mob, fn mob ->
        %{
          mob
          | hurt_by_player: nil,
            player_memory: 0,
            finalize: nil,
            living: %{mob.living | health: %{mob.living.health | value: 0.0, death_ticks: 7}}
        }
      end)

    assert_round_trip(facts, dying)
  end

  test "motion states", %{facts: facts} do
    {:ok, rabbit} = Body.new("minecraft:rabbit")

    motions = [
      %{
        rabbit.mob.motion
        | hop:
            Map.merge(rabbit.mob.motion.hop, %{
              started: true,
              jumped: false,
              nav_speed: nil,
              path_up: true
            })
      },
      %{
        rabbit.mob.motion
        | control: {:strafe, 0.5, -0.5, 1.0},
          set: {0.1, true},
          impulse: [{0.0, 0.1, 0.0}, {0.2, 0.0, 0.0}]
      },
      %{
        rabbit.mob.motion
        | hop: nil,
          control: {:jumping, 1.2},
          set: {0.1, false, {nil, 0.0, 0.5}},
          travel: {:fish, true},
          pre_move: 90.0
      },
      %{
        rabbit.mob.motion
        | hop: nil,
          set: :hold,
          float: %{wanted: {1.0, 2.0, 3.0}, duration: 5},
          eye: {true, 86},
          support: 9,
          eye_water: true
      }
    ]

    for motion <- motions, do: assert_round_trip(facts, put_in(rabbit.mob.motion, motion))
  end

  test "the ocean mobs' former data migrates", %{facts: facts} do
    for {type, data} <- [
          {"minecraft:dolphin", %{got_fish: true, moistness: 1200, treasure: nil}},
          {"minecraft:squid", %{age: 3}},
          {"minecraft:glow_squid", %{age: 0, dark: 40}}
        ] do
      {:ok, body} = Body.new(type)
      record = %{record(body, 0) | data: data}
      {:ok, restored} = Body.restore(record)
      assert_native(facts, record, record(restored, 0))
    end
  end

  test "records Elixir refuses are refused", %{facts: facts} do
    {:ok, cow} = Body.new("minecraft:cow")
    good = record(cow, 0)

    bad = [
      %{good | data: Map.delete(good.data, :age)},
      %{good | velocity: {0, 0, 0}},
      %{good | type: "minecraft:nothing"},
      Map.put(good, :portal_cooldown, 40_000),
      put_in(good.mob.player_memory, 101),
      put_in(good.mob.living.health.value, 1.1),
      put_in(good.mob.living.effects, %{999 => [{1, 0, false, true, true}]}),
      put_in(good.mob.motion.no_jump_delay, 11),
      put_in(good.mob.ai, %{random: 1 <<< 48}),
      Map.put(good, :mob, nil)
    ]

    for record <- bad do
      # Elixir refuses it, or crashes on it (an invalid effect map).
      assert (try do
                Body.restore(record)
              rescue
                MatchError -> {:error, :invalid_body}
              end) == {:error, :invalid_body}

      assert {:error, {:invalid, _}} = Native.mob_record_roundtrip(facts, record)
    end
  end

  test "ticked mobs on land and in water", %{facts: facts} do
    air = Blocks.default_state("air")
    grass = Blocks.default_state("grass_block")
    water = Blocks.default_state("water")

    scene =
      for x <- -16..16, z <- -16..16, into: %{} do
        if x in 4..12 and z in 4..12,
          do: {{x, 60, z}, grass},
          else: {{x, 63, z}, grass}
      end

    scene =
      for x <- 4..12, y <- 61..63, z <- 4..12, into: scene, do: {{x, y, z}, water}

    packed =
      for x <- -16..16, y <- 56..80, z <- -16..16, into: <<>> do
        <<x::signed-32, y::signed-32, z::signed-32, Map.get(scene, {x, y, z}, air)::16>>
      end

    view = {:states, packed}

    land = ~w(cow sheep pig chicken rabbit zombie skeleton creeper spider villager slime
              enderman witch iron_golem cat)
    wet = ~w(axolotl dolphin squid cod salmon pufferfish turtle)

    entries =
      for {name, i} <- Enum.with_index(land ++ wet), type = "minecraft:" <> name do
        {:ok, body} = Body.spawned(type, :natural)
        uuid = <<i + 1::64, 77::64>>
        aquatic = name in wet
        x = if aquatic, do: 5.5 + rem(i, 6), else: -12.5 + rem(i, 8) * 3
        z = if aquatic, do: 5.5 + div(i - length(land), 6), else: -12.5 + div(i, 8) * 3
        y = if aquatic, do: 61.5, else: 64.0
        {i + 1, %{entity: %{uuid: uuid, x: x, y: y, z: z}, body: body, revision: 1}}
      end

    # A survival player holding wheat: animals follow, hostiles hunt.
    player = %{
      kind: :player,
      uuid: <<1::64, 99::64>>,
      id: 1000,
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      eye: Float32.round(1.62),
      width: Float32.round(0.6),
      height: Float32.round(1.8),
      mode: :survival,
      invulnerable: false,
      alive: true,
      crouching: false,
      invisible: false,
      armor_cover: 0.0,
      equipment: %{mainhand: ItemTypes.id("minecraft:wheat"), offhand: nil}
    }

    Enum.reduce(1..200, {entries, AI.Random.new(7)}, fn tick, {entries, level} ->
      world = %AI.World{
        read: &Map.get(scene, &1, air),
        search: fn request ->
          [result] = AI.Paths.find(view, [request])
          result
        end,
        players: [player],
        random: level,
        difficulty: :normal,
        time: 1000 + tick,
        biome: fn _ -> "minecraft:plains" end,
        knots: %{}
      }

      {steps, world} = MobTicks.steps(view, entries, world, nil)
      steps = Map.new(steps, &{&1.id, &1})

      # A creeper that blew up leaves.
      entries =
        for {id, e} <- entries, Map.has_key?(steps, id) do
          {x, y, z} = steps[id].position
          {id, %{e | body: steps[id].body, entity: %{e.entity | x: x, y: y, z: z}}}
        end

      for {_, e} <- entries do
        assert_round_trip(
          facts,
          e.body,
          rem(tick, 3),
          {e.entity.x, e.entity.y, e.entity.z},
          e.entity.uuid
        )
      end

      {entries, world.random}
    end)
    |> then(fn {entries, _} ->
      # They thought and moved.
      assert Enum.all?(entries, fn {_, e} -> match?(%AI.Mind{}, e.body.mob.ai) end)
      assert Enum.any?(entries, fn {_, e} -> e.body.mob.motion.control != :wait end)
    end)
  end

  defp record(body, hops, position \\ {0.5, 64.0, -2.5}, uuid \\ <<1::128>>) do
    {x, y, z} = position

    Store.record(%{
      kind: :mob,
      entity: %{entity_id: 1, uuid: uuid, x: x, y: y, z: z},
      body: body,
      hops: hops
    })
  end

  defp assert_round_trip(
         facts,
         body,
         hops \\ 0,
         position \\ {0.5, 64.0, -2.5},
         uuid \\ <<1::128>>
       ) do
    record = record(body, hops, position, uuid)
    # What Elixir writes after restoring its own record.
    {:ok, restored} = Body.restore(record)
    assert record(restored, hops, position, uuid) == record
    assert_native(facts, record, record)
  end

  defp assert_native(facts, record, expected) do
    assert {:ok, native} = Native.mob_record_roundtrip(facts, record)
    assert native === expected

    assert :erlang.term_to_binary(native, [:deterministic]) ==
             :erlang.term_to_binary(expected, [:deterministic])
  end
end
