defmodule Valimc.NativeMobRecordTest do
  @moduledoc """
  VMC-081d: a mob record read into the native model and written back is the
  term `Store.record/1` writes, for fresh, spawned and generated mobs of
  many families and for every saved option.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Valimc.Data.EffectTypes
  alias Valimc.Entity.{Body, Mob, MobFacts, Store}
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  setup_all do
    MobFacts.install!()
    {:ok, facts} = Native.mob_record_facts(MobFacts.record_facts())
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
