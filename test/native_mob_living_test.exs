defmodule Valimc.NativeMobLivingTest do
  @moduledoc """
  VMC-081d: the native living rules (`valimc_core::mobs::{living, combat,
  vitals}`) against the Elixir on the same mob bodies: hurts with knockback,
  cooldowns, armour, effects, absorption and deaths with drops and
  experience (`Entity.Combat`), `/kill`, the body's timers, entity data,
  dimensions and attributes (`Body`, `Mob`), effect ticking over seeded
  effect sets, the base tick's burning and effects, the post-move air,
  landings and contacts (`MobVitals`), the sun and rain (`AI.Daylight`) and
  a mob's melee hit (`Combat.mob_hit/3`). Each case restores the Elixir
  body's store record natively, runs the same operation on both and
  compares the records written, the events (sound seeds aside) and the
  results.

  Native draws come from the mob's random where the Elixir has a mind (every
  body here has one), so they match draw for draw; the Elixir's `:rand`
  fallbacks for mobs without a mind are not exercised.
  """
  use ExUnit.Case, async: true

  alias Valimc.AI
  alias Valimc.Data.{Blocks, EffectTypes, EntityTypes, Float32}
  alias Valimc.Entity.{Body, Combat, Mob, MobVitals, Store}
  alias Valimc.Living.{Attributes, DamageSource, Effects, Melee}
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @uuid <<0x5E, 0x11, 0xA7, 0x09, 1::96>>
  @position {64.5, 64.0, 61.5}
  @player %{
    uuid: <<2::128>>,
    entity_id: 9,
    player: true,
    type: "minecraft:player",
    mainhand: nil
  }

  setup_all do
    Valimc.Entity.NativeLiving.install!()

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

  # ---------------------------------------------------------------- helpers

  defp mob(type, fun \\ & &1) do
    {:ok, body} = Body.new("minecraft:" <> type)
    mind = AI.mind(body.type, @uuid, nil, body.data)
    fun.(%{body | mob: %{body.mob | ai: mind}})
  end

  defp put_mob(body, fun), do: %{body | mob: fun.(body.mob)}
  defp put_living(body, fun), do: put_mob(body, &%{&1 | living: fun.(&1.living)})

  defp stack(name, enchantments \\ %{}) do
    components =
      if enchantments == %{}, do: %{}, else: %{"minecraft:enchantments" => enchantments}

    %ItemStack{item_id: ItemTypes.id(name), count: 1, components: components}
  end

  defp record(body) do
    {x, y, z} = @position

    Store.record(%{
      kind: :mob,
      entity: %{entity_id: 1, uuid: @uuid, x: x, y: y, z: z},
      body: body,
      hops: 0
    })
  end

  defp entity do
    {x, y, z} = @position
    %{uuid: @uuid, entity_id: 1, x: x, y: y, z: z}
  end

  defp hit(source, amount, extra \\ %{}),
    do: Map.merge(%{source: DamageSource.new(source), amount: amount}, extra)

  defp seedless(events) do
    Enum.map(events, fn
      {:sound, id, source, volume, pitch, _seed} -> {:sound, id, source, volume, pitch, 0}
      event -> event
    end)
  end

  defp death(nil), do: nil

  defp death(%{loot: %{source: %{tags: tags} = source} = loot} = death),
    do: %{death | loot: %{loot | source: %{source | tags: Enum.sort(tags)}}}

  defp death(death), do: death

  defp same(native, elixir, label) do
    if native !== elixir do
      flunk(
        "#{label}\nnative: #{inspect(native, pretty: true, limit: :infinity)}" <>
          "\nelixir: #{inspect(elixir, pretty: true, limit: :infinity)}"
      )
    end
  end

  # Runs `op` on both sides and compares. Both start from what the record
  # keeps (the Elixir body restored, with its mind); `fix` turns the Elixir's
  # result into what the native rules give where the Elixir draws `:rand`.
  defp check(facts, body, op, fix \\ fn body -> body end) do
    {:ok, restored} = Body.restore(record(body))
    body = %{restored | mob: %{restored.mob | ai: body.mob.ai}}
    {native_record, native_events, extra} = Native.mob_parity_living(facts, record(body), op)
    {elixir_body, elixir_events, result} = elixir(body, op)
    elixir_body = fix.(elixir_body)
    label = "#{body.type} #{inspect(op, limit: 6)}"
    same(native_events, seedless(elixir_events), label <> " events")
    same(extra.result, result, label <> " result")
    same(death(extra.death), death(elixir_body.mob.death), label <> " death")
    same(extra.hurt_by, elixir_body.mob.hurt_by, label <> " hurt_by")
    same(native_record, record(elixir_body), label <> " record")
    elixir_body
  end

  # ------------------------------------------------------ the Elixir side

  defp elixir(body, {:seq, ops}) do
    Enum.reduce(ops, {body, [], []}, fn op, {body, events, results} ->
      {body, more, result} = elixir(body, op)
      {body, events ++ more, results ++ [result]}
    end)
  end

  defp elixir(body, {:hurt, hits}) do
    Enum.reduce(hits, {body, [], []}, fn hit, {body, events, outcomes} ->
      {change, outcome} = Combat.resolve(%{kind: :mob, body: body, entity: entity()}, hit)

      {body, more} =
        case change do
          :keep -> {body, []}
          {:body, next, more} -> {next, more}
        end

      outcome = Map.take(outcome, [:hurt, :full, :died, :previous, :health])
      {body, events ++ more, outcomes ++ [outcome]}
    end)
  end

  defp elixir(body, {:hurt_mob, pairs}) do
    Enum.reduce(pairs, {body, [], []}, fn {source, amount}, {body, events, hurts} ->
      {mob, more, hurt} = Combat.hurt_mob(body.type, body.mob, source, amount, body.data)
      {%{body | mob: mob}, events ++ more, hurts ++ [hurt]}
    end)
  end

  defp elixir(body, {:hit_body, hit}) do
    {body, events, hurt} = Combat.hit_body(body, entity(), hit)
    {body, events, hurt}
  end

  defp elixir(body, {:kill}) do
    case Body.kill(body) do
      {:dying, body, events} -> {Combat.died(body, %{}), events, true}
      :ignored -> {body, [], false}
    end
  end

  defp elixir(body, {:knockback, power, direction}) do
    {:ok, store, {_, id, _}} =
      Store.create_record(Store.new(), {0, 0}, Store.body_record(body, @uuid, @position))

    {:ok, store} = Combat.knockback(store, id, power, direction)
    {%{body | velocity: store.entries[id].body.velocity}, [], nil}
  end

  defp elixir(body, {:mob_hit, target}) do
    {:ok, store, {_, id, _}} =
      Store.create_record(Store.new(), {0, 0}, Store.body_record(body, @uuid, @position))

    result =
      case Combat.mob_hit(store, id, target) do
        {:ok, hit} -> %{hit | source: DamageSource.type(hit.source)}
        {:error, _} -> nil
      end

    {body, [], {id, result}}
  end

  defp elixir(body, {:base_tick, n}) do
    Enum.reduce(1..n//1, {body, [], nil}, fn _, {body, events, nil} ->
      {body, more} = MobVitals.base_tick(body.type, body)
      {body, events ++ more, nil}
    end)
  end

  defp elixir(body, {:apply, moves}) do
    Enum.reduce(moves, {body, [], nil}, fn move, {body, events, nil} ->
      ticked = %{
        eye_water: move.eye_water,
        eye_state: move.eye_state,
        landing: move.landing,
        fire_contacts: %{steps: move.steps, immediate: move.immediate},
        water: move.water
      }

      {body, more} = MobVitals.apply(body.type, body, ticked)
      {body, events ++ more, nil}
    end)
  end

  defp elixir(body, {:daylight, position, sky}) do
    world = %AI.World{
      monsters_burn: sky.monsters_burn,
      light: if(sky.light, do: fn _ -> sky.light end),
      darken: sky.darken,
      rain: fn _, _ -> sky.rain end
    }

    {body, events} = AI.Daylight.tick(body, position, world)
    {body, events, nil}
  end

  defp elixir(body, {:tick, n}) do
    Enum.reduce(1..n//1, {body, [], []}, fn _, {body, events, done} ->
      {body, more, d} = Body.tick(body)
      {body, events ++ more, done ++ [d]}
    end)
  end

  defp elixir(body, {:values}) do
    values = body |> Body.values() |> Enum.take(10)
    {body, [], values}
  end

  defp elixir(body, {:dimensions}) do
    {body, [], {Body.dimensions(body), Body.box(body, @position)}}
  end

  defp elixir(body, {:add_effect, id, rung}),
    do: {put_mob(body, &Mob.add_effect(&1, id, rung)), [], nil}

  defp elixir(body, {:refresh_effect, id, rung}) do
    {:ok, effects, changed} = Effects.add(body.mob.living.effects, id, [rung])
    {put_living(body, &%{&1 | effects: effects}), [], changed}
  end

  defp elixir(body, {:effects_tick, n}) do
    effects =
      Enum.reduce(1..n//1, body.mob.living.effects, fn _, effects ->
        {:ok, next, _} = Effects.tick(effects)
        next
      end)

    {put_living(body, &%{&1 | effects: effects}), [], nil}
  end

  defp elixir(body, {:value, name}) do
    {body, [],
     {Mob.value(body.type, body.mob, name) * 1.0,
      Mob.base(body.type, body.mob.attributes, name) * 1.0}}
  end

  defp elixir(body, {:difficulty, difficulty, total, inhabited}) do
    at = Valimc.Living.LocalDifficulty.at(difficulty, total, inhabited)
    {body, [], {at.effective, Valimc.Living.LocalDifficulty.special(at)}}
  end

  defp elixir(body, {:explosion, radius, center, position, seen, resistance}) do
    alias Valimc.Living.Explosions
    distance = Explosions.distance(radius, center, position)

    knockback =
      distance && Explosions.knockback(center, position, distance, seen, resistance)

    {body, [],
     {Explosions.reach(radius, center), distance,
      Explosions.damage(radius, center, position, seen), knockback}}
  end

  defp elixir(body, {:synced}), do: {body, [], Mob.synced(body.type, body.mob.attributes)}

  # ------------------------------------------------------------------ cases

  @hostiles ~w(zombie husk skeleton stray creeper spider cave_spider blaze wither_skeleton
               zombified_piglin)
  @animals ~w(cow pig sheep chicken)

  defp player_hit(amount, yaw \\ 30.0, extra \\ %{}) do
    hit(
      :player_attack,
      amount,
      Map.merge(
        %{
          attacker: @player,
          direct: @player,
          position: {2.0, 64.0, 1.0},
          extra_knockback: {0.4000000059604645, Melee.facing(yaw)}
        },
        extra
      )
    )
  end

  test "hurts: knockback, cooldown, sounds and a player kill", %{facts: facts} do
    for type <- @hostiles ++ @animals do
      body = mob(type, &%{&1 | on_ground: true, velocity: {0.01, -0.0784, 0.02}})

      check(
        facts,
        body,
        {:hurt,
         [
           player_hit(5.0),
           player_hit(3.0),
           player_hit(8.0, 170.0),
           hit(:mob_attack, 2.5, %{
             attacker: %{@player | player: false, type: "minecraft:zombie", uuid: <<3::128>>}
           }),
           player_hit(40.0, -45.0),
           player_hit(1.0)
         ]}
      )
    end
  end

  test "hurts: sources, immunities, armour, effects and absorption", %{facts: facts} do
    helmet = stack("minecraft:iron_helmet", %{"minecraft:protection" => 3})
    chest = stack("minecraft:diamond_chestplate", %{"minecraft:fire_protection" => 4})
    boots = stack("minecraft:iron_boots", %{"minecraft:frost_walker" => 2})
    resistance = EffectTypes.id("resistance")
    fire_resistance = EffectTypes.id("fire_resistance")

    hits = [
      [hit(:in_fire, 1.0)],
      [hit(:on_fire, 1.0), hit(:lava, 4.0)],
      [hit(:fall, 6.0)],
      [hit(:magic, 3.0), hit(:wither, 1.0)],
      [hit(:freeze, 1.0)],
      [hit(:falling_anvil, 9.0)],
      [hit(:hot_floor, 1.0)],
      [hit(:explosion, 15.5)],
      [hit(:drown, 2.0)],
      [hit(:generic, 0.0)],
      [hit(:arrow, 6.0, %{direction: {0.3, -0.9}, attacker: @player, direct: @player})],
      [player_hit(7.0, 0.0, %{lift: 0.4})],
      [hit(:fireball, 6.0, %{bypass_immunity: true})]
    ]

    for type <- ~w(zombie skeleton blaze stray wither_skeleton spider),
        dressed <- [false, true],
        effects <- [
          %{},
          %{resistance => [{200, 1, false, true, true}]},
          %{fire_resistance => [{80, 0, false, true, true}]}
        ],
        absorption <- [0.0, 4.0],
        hits <- hits do
      body =
        mob(type, fn body ->
          body
          |> put_mob(fn mob ->
            equipment = if dressed, do: %{head: helmet, chest: chest, feet: boots}, else: %{}
            %{mob | equipment: equipment}
          end)
          |> put_living(&%{&1 | effects: effects, absorption: absorption})
        end)

      hits = Enum.map(hits, &Map.put_new(&1, :position, {63.0, 64.0, 60.0}))
      check(facts, body, {:hurt, hits})
    end
  end

  test "deaths: equipment by drop chance, looting, experience and loot facts", %{facts: facts} do
    sword = stack("minecraft:iron_sword", %{"minecraft:sharpness" => 2})
    looting = %{@player | mainhand: stack("minecraft:diamond_sword", %{"minecraft:looting" => 3})}
    helmet = stack("minecraft:golden_helmet")
    vanishing = stack("minecraft:iron_boots", %{"minecraft:vanishing_curse" => 1})

    for type <- ~w(zombie husk skeleton zombified_piglin cow sheep pig chicken),
        chances <- [%{}, %{mainhand: 2.0}, %{head: 1.0, mainhand: 0.0}],
        attacker <- [@player, looting, nil],
        baby <- [false, true],
        seed <- 1..3 do
      body =
        mob(type, fn body ->
          data =
            cond do
              baby and Map.has_key?(body.data, :baby) -> %{body.data | baby: true}
              baby and Map.has_key?(body.data, :age) -> %{body.data | age: -24_000}
              true -> body.data
            end

          random = AI.Random.new(<<seed::64, 0::64>>)

          %{body | data: data, on_ground: true}
          |> put_mob(fn mob ->
            %{
              mob
              | equipment: %{mainhand: sword, head: helmet, feet: vanishing},
                drop_chances: chances,
                ai: %{mob.ai | random: random}
            }
          end)
          |> put_living(&%{&1 | fire_ticks: if(seed == 2, do: 30, else: 0)})
        end)

      hits =
        if attacker,
          do: [player_hit(100.0, 0.0, %{attacker: attacker, direct: attacker})],
          else: [hit(:on_fire, 100.0)]

      check(facts, body, {:hurt, hits}, &reward_draws/1)
    end
  end

  # `Combat.reward/1` draws `:rand` for each worn or held item it would not
  # keep unworn; the native rules draw `1 + int(3)` from the mob's random in
  # vanilla's slot order (`Mob.getBaseExperienceReward`).
  defp reward_draws(%Body{mob: %Mob{death: %{experience: xp} = death} = mob} = body)
       when xp > 0 do
    reward = Valimc.Living.Weapons.experience(body.type)
    animal = Valimc.Protocol.CombatPackets.mob_sounds(body.type)["animal"]

    slots =
      for slot <- [:mainhand, :offhand, :feet, :legs, :chest, :head],
          Map.has_key?(mob.equipment, slot),
          Mob.drop_chance(mob, slot) <= 1.0,
          do: slot

    if reward > 0 and not animal and slots != [] do
      base = if match?(%{baby: true}, body.data), do: trunc(reward * 2.5), else: reward

      {xp, random} =
        Enum.reduce(slots, {base, mob.ai.random}, fn _, {xp, random} ->
          {n, random} = AI.Random.int(random, 3)
          {xp + 1 + n, random}
        end)

      %{body | mob: %{mob | death: %{death | experience: xp}, ai: %{mob.ai | random: random}}}
    else
      body
    end
  end

  defp reward_draws(body), do: body

  test "kill, timers through the death animation and entity data", %{facts: facts} do
    for type <- @hostiles ++ @animals do
      body = mob(type, &put_mob(&1, fn mob -> %{mob | player_memory: 3} end))
      dead = check(facts, body, {:kill})
      check(facts, body, {:seq, [{:kill}, {:kill}, {:tick, 22}, {:values}]})
      check(facts, dead, {:values})
      check(facts, body, {:dimensions})

      shown =
        body
        |> Map.merge(%{custom_name: {:compound, %{"text" => {:string, "Bob"}}}, no_gravity: true})
        |> put_mob(&%{&1 | no_ai: true, left_handed: true, using: {:off_hand, 3}})
        |> put_living(&%{&1 | fire_ticks: 9, air_supply: 120})

      check(facts, shown, {:seq, [{:values}, {:tick, 2}, {:values}]})
    end

    baby = mob("zombie", &%{&1 | data: %{&1.data | baby: true}})
    check(facts, baby, {:dimensions})
  end

  test "attributes: equipment and effect modifiers, overrides and synced", %{facts: facts} do
    speed = EffectTypes.id("speed")
    sword = stack("minecraft:netherite_sword")
    chest = stack("minecraft:netherite_chestplate")

    for type <- ~w(zombie spider cave_spider skeleton cow) do
      body =
        mob(type, fn body ->
          put_mob(body, fn mob ->
            %{
              mob
              | equipment: %{mainhand: sword, chest: chest},
                attributes: %{
                  "minecraft:follow_range" => %{
                    base: nil,
                    modifiers: [{"minecraft:random_spawn_bonus", 0.0123, 1}]
                  },
                  "minecraft:armor" => %{base: 4.0, modifiers: [{"minecraft:x", 2, 0}]}
                }
            }
          end)
        end)

      ops =
        for name <- ~w(armor armor_toughness attack_damage knockback_resistance movement_speed
                       follow_range max_health burning_time),
            do: {:value, "minecraft:" <> name}

      check(
        facts,
        body,
        {:seq,
         ops ++
           [
             {:synced},
             {:add_effect, speed, {600, 1, false, true, true}},
             {:value, "minecraft:movement_speed"},
             {:add_effect, speed, {600, 7, false, true, true}},
             {:synced}
           ]}
      )
    end
  end

  test "effect ticking over seeded effect sets", %{facts: facts} do
    ids =
      Enum.map(
        ~w(speed slowness regeneration poison wither absorption resistance
                      fire_resistance water_breathing instant_health),
        &EffectTypes.id/1
      )

    for seed <- 1..40 do
      :rand.seed(:exsss, {seed, seed * 7, seed * 13})

      refreshes =
        for _ <- 1..:rand.uniform(12) do
          ticks = Enum.random([-1, 0, 1, 2, 5, 20, 40, 80, 600])

          {:refresh_effect, Enum.random(ids),
           {ticks, Enum.random([0, 0, 1, 2, 4, 31, 33]), Enum.random([true, false]),
            Enum.random([true, false]), Enum.random([true, false])}}
        end

      ops =
        Enum.intersperse(refreshes, {:effects_tick, :rand.uniform(30)}) ++
          [{:effects_tick, 100}]

      body = mob("zombie")
      check(facts, body, {:seq, ops})

      # The base tick's periodic effects and instant health over the same set.
      hurt = put_living(body, &%{&1 | health: %{&1.health | value: 9.0}})
      check(facts, hurt, {:seq, Enum.take(ops, 6) ++ [{:base_tick, 120}]})
    end
  end

  test "base tick: burning a second at a time, in and out of lava", %{facts: facts} do
    for type <- ~w(zombie blaze cow skeleton),
        fire <- [1, 20, 41, 100],
        lava <- [0.0, 0.4] do
      body =
        mob(type, fn body ->
          body
          |> put_living(&%{&1 | fire_ticks: fire})
          |> put_mob(&%{&1 | motion: %{&1.motion | lava: lava}})
        end)

      check(facts, body, {:seq, List.duplicate({:seq, [{:base_tick, 1}, {:tick, 1}]}, 60)})
    end
  end

  test "post-move vitals: air, landings, contacts and wet", %{facts: facts} do
    water = Blocks.default_state("water")
    bubbles = Blocks.default_state("bubble_column")
    stone = Blocks.default_state("stone")
    hay = Blocks.default_state("hay_block")

    dripstone =
      Blocks.state("pointed_dripstone", %{"thickness" => "tip", "vertical_direction" => "up"})

    jump = EffectTypes.id("jump_boost")
    breathing = EffectTypes.id("water_breathing")

    move = fn fields ->
      Map.merge(
        %{eye_water: false, eye_state: 0, landing: nil, steps: [], immediate: [], water: false},
        fields
      )
    end

    under = move.(%{eye_water: true, eye_state: water, water: true})

    for type <- ~w(zombie skeleton cow blaze chicken spider) do
      body = mob(type)
      ticks = List.duplicate({:seq, [{:apply, [under]}, {:tick, 1}]}, 340)
      check(facts, body, {:seq, ticks})

      check(
        facts,
        put_living(body, &%{&1 | effects: %{breathing => [{100, 0, false, true, true}]}}),
        {:apply, List.duplicate(under, 30) ++ [move.(%{})]}
      )

      check(
        facts,
        body,
        {:apply, List.duplicate(move.(%{eye_water: true, eye_state: bubbles}), 5)}
      )

      for state <- [stone, hay, dripstone], distance <- [2.5, 3.0, 4.2, 9.75, 30.0] do
        check(facts, body, {:apply, [move.(%{landing: {state, distance}})]})

        check(
          facts,
          put_living(body, &%{&1 | effects: %{jump => [{100, 1, false, true, true}]}}),
          {:apply, [move.(%{landing: {state, distance}})]}
        )
      end

      contacts = [
        [move.(%{steps: [[:fire]]})],
        [move.(%{steps: [[:soul_fire, :fire], [:lava, :lava]]})],
        [move.(%{steps: [[:lava]]}), move.(%{steps: [[:water]]})],
        [move.(%{steps: [[:fire], [:powder_snow]]})],
        [move.(%{immediate: [{:cactus, 1.0}, {:hot_floor, 1.0}], steps: [[:fire]]})],
        [move.(%{immediate: [{:sweet_berry_bush, 1.0}, {:campfire, 2.0}]})],
        [move.(%{water: true}), move.(%{water: true})]
      ]

      for steps <- contacts, fire <- [0, 30, -5] do
        burning =
          put_living(body, fn living ->
            %{living | fire_ticks: fire, freezing: %{living.freezing | frozen_ticks: 40}}
          end)

        check(facts, burning, {:apply, steps})
      end
    end
  end

  test "hurt_mob and hit_body: the vitals' and melee's hurt paths", %{facts: facts} do
    for type <- @hostiles ++ @animals do
      body = mob(type, &%{&1 | velocity: {0.1, 0.0, -0.1}, on_ground: true})

      check(
        facts,
        body,
        {:hurt_mob, [{:on_fire, 1.0}, {:drown, 2.0}, {:lava, 4.0}, {:magic, 30.0}]}
      )

      zombie = %{@player | player: false, type: "minecraft:zombie", uuid: <<4::128>>}

      check(
        facts,
        body,
        {:seq,
         [
           {:hit_body,
            hit(:mob_attack, 3.0, %{attacker: zombie, direct: zombie, position: {1.0, 64.0, -2.0}})},
           {:hit_body,
            hit(:mob_attack, 2.0, %{
              attacker: zombie,
              direct: zombie,
              position: {64.0, 65.0, 62.0}
            })},
           {:knockback, 0.5, {0.3, 0.7}}
         ]}
      )
    end
  end

  test "daylight: the sun on undead, helmets and rain", %{facts: facts} do
    helmet = stack("minecraft:leather_helmet")
    worn = %{helmet | components: %{"minecraft:damage" => 54}}

    for type <- ~w(zombie skeleton stray husk cow),
        head <- [nil, helmet, worn],
        light <- [{15, 0}, {12, 4}, {7, 0}, nil],
        rain <- [false, true],
        fire <- [0, 30] do
      body =
        mob(type, fn body ->
          body
          |> put_mob(&%{&1 | equipment: if(head, do: %{head: head}, else: %{})})
          |> put_living(&%{&1 | fire_ticks: fire})
        end)

      sky = %{monsters_burn: true, light: light, darken: 0, rain: rain, seed: 7}
      ops = List.duplicate({:daylight, @position, sky}, 40)
      check(facts, body, {:seq, ops})
    end
  end

  test "mob_hit: a mob's melee hit after its weapon's enchantments", %{facts: facts} do
    swords = [
      nil,
      stack("minecraft:iron_sword"),
      stack("minecraft:diamond_sword", %{"minecraft:sharpness" => 3, "minecraft:knockback" => 2}),
      stack("minecraft:iron_sword", %{"minecraft:smite" => 4}),
      stack("minecraft:diamond_spear")
    ]

    for type <- ~w(zombie husk wither_skeleton zombified_piglin),
        weapon <- swords,
        target <- ~w(minecraft:player minecraft:zombie minecraft:cow),
        yaw <- [0.0, 123.4] do
      body =
        mob(type, fn body ->
          %{body | yaw: yaw}
          |> put_mob(&%{&1 | equipment: if(weapon, do: %{mainhand: weapon}, else: %{})})
        end)

      {_, _, {id, elixir}} = elixir(body, {:mob_hit, target})

      {_, _, %{result: native}} =
        Native.mob_parity_living(facts, record(body), {:mob_hit, target, id})

      assert native === Map.take(elixir, Map.keys(native)), "#{type} #{inspect(weapon)} #{target}"
      assert native.source === elixir.source
      assert native.amount === elixir.amount
      assert native.extra_knockback === elixir.extra_knockback
    end
  end

  test "Float32 and the zombie combat cases' shape", %{facts: facts} do
    # `check_combat.exs`: a 100-health zombie in iron or netherite, hit by a
    # player's sword with knockback, then the zombie's own hit on a player.
    for armour <- [nil, "minecraft:iron_chestplate", "minecraft:netherite_chestplate"],
        amount <- [1.0, 6.0, 9.5, Float32.round(13.7)],
        ground <- [true, false] do
      body =
        mob("zombie", fn body ->
          {:ok, health} = Valimc.Living.Health.restore(nil, 100.0)

          %{body | on_ground: ground, yaw: 0.0}
          |> put_mob(fn mob ->
            %{
              mob
              | living: %{mob.living | health: health},
                attributes: %{"minecraft:max_health" => %{base: 100.0, modifiers: []}},
                equipment: if(armour, do: %{chest: stack(armour)}, else: %{})
            }
          end)
        end)

      check(facts, body, {:hurt, [player_hit(amount, 77.0), player_hit(amount + 2.0, 77.0)]})
    end
  end

  test "local difficulty and explosions", %{facts: facts} do
    difficulties =
      for difficulty <- [:peaceful, :easy, :normal, :hard],
          total <- [0, 72_000, 500_000, 1_512_000, 30_000_000],
          inhabited <- [0, 1_000_000, 3_600_000, 9_000_000],
          do: {:difficulty, difficulty, total, inhabited}

    explosions =
      for radius <- [1.0, 3.0, 4.0, 6.0],
          position <- [
            {64.5, 64.0, 61.5},
            {66.25, 65.5, 60.0},
            {70.0, 64.0, 61.5},
            {64.5, 64.0, 61.5000001}
          ],
          seen <- [0.0, 0.25, 1.0],
          do: {:explosion, radius, {64.5, 64.0, 61.5}, position, seen, 0.5}

    check(facts, mob("zombie"), {:seq, difficulties ++ explosions})
  end
end
