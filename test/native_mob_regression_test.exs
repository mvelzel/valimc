defmodule Valimc.NativeMobRegressionTest do
  @moduledoc """
  What no vanilla stage replays of the native mobs (VMC-081d), through the
  production NIFs on a fresh mob in an oracle section: a player's items on
  a mob (food, milk, stew, dye, the golden dandelion, leads, fire on a
  creeper), the hurts endermen and ghasts refuse, death drops (a carried
  block, drop chances under Looting), conversions, a dead cube's split and
  status effects ticking on a mob. Expected values are vanilla's where they
  are stated; a digest pins the current native output where a whole record
  is compared.
  """
  use ExUnit.Case, async: true

  alias Valimc.Data.{Blocks, EffectTypes, JavaRandom}
  alias Valimc.Entity.{Body, MobFacts, MobTicks, NativeMobs, Store}
  alias Valimc.Living.DamageSource
  alias Valimc.Native
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  setup_all do
    MobFacts.install!()
    :ok
  end

  @player <<9::128>>
  # The player using an item: `{uuid, position, entity id, width, height}`.
  @holder {@player, {2.5, 64.0, 0.5}, 70, 0.6000000238418579, 1.7999999523162842}

  defp mob(type, fun \\ & &1) do
    {:ok, body} = Body.new(type)
    fun.(%{body | mob: %{body.mob | ai: %{random: JavaRandom.new(7)}}})
  end

  # An oracle section holding `body` as mob 1 at {0.5, 64.0, 0.5}.
  defp section(body) do
    ref = Native.mob_section_oracle_new()
    record = Store.body_record(body, <<1::128>>, {0.5, 64.0, 0.5})
    {:ok, [_]} = Native.mob_section_insert(ref, [{1, record}], false)
    ref
  end

  defp record(ref), do: hd(Native.mob_section_records(ref, [1]))

  defp body(ref) do
    {:ok, body} = Body.restore(record(ref))
    body
  end

  # `item` used on the mob: `{outcome, body after}`.
  defp use_item(ref, item, opts \\ []) do
    stack = item && ItemStack.new(item)
    holder = Keyword.get(opts, :holder, @holder)
    infinite = Keyword.get(opts, :infinite, false)
    {:ok, {outcome, _, _}} = Native.mob_section_interact(ref, 1, stack, holder, infinite, [])
    {outcome, body(ref)}
  end

  defp use_on(body, item, opts \\ []), do: use_item(section(body), item, opts)

  defp id(name), do: ItemTypes.id(name)

  test "food: love once, a baby's growth by a tenth, each animal's own" do
    cow = mob("minecraft:cow")
    ref = section(cow)

    assert {{:done, {:use, 1}, true, [event: 18], nil, [], nil, [], false}, fed} =
             use_item(ref, "minecraft:wheat")

    assert fed.data.in_love == 600 and fed.data.love_cause == @player
    assert {:pass, _} = use_item(ref, "minecraft:wheat")
    assert {:pass, _} = use_on(%{cow | data: %{cow.data | age: 3000}}, "minecraft:wheat")
    assert {:pass, _} = use_on(cow, "minecraft:carrot")

    # 24,000 ticks left: a tenth of 1,200 s is 120 s.
    calf = %{cow | data: %{cow.data | age: -24_000}}
    assert {{:done, {:use, 1}, false, [], _, _, _, _, _}, grown} = use_on(calf, "minecraft:wheat")
    assert {grown.data.age, grown.data.forced_age} == {-21_600, 2400}

    # A pig eats out loud; an axolotl leaves the water bucket.
    assert {{:done, _, _, [{:event, 18}, {:sound, _, "neutral", 1.0, _}], _, _, _, _, _}, _} =
             use_on(mob("minecraft:pig"), "minecraft:carrot")

    water = id("minecraft:water_bucket")
    axolotl = mob("minecraft:axolotl")

    assert {{:done, {:fill, %{item_id: ^water}}, true, _, _, _, _, _, _}, loved} =
             use_on(axolotl, "minecraft:tropical_fish_bucket")

    assert loved.data.in_love == 600
    assert {:pass, _} = use_on(axolotl, "minecraft:tropical_fish")
  end

  test "milk, stew, dye and the golden dandelion" do
    milk = id("minecraft:milk_bucket")
    cow = mob("minecraft:cow")

    assert {{:done, {:fill, %{item_id: ^milk}}, false, [], {_, "player", 1.0, 1.0, :player}, [],
             nil, [], false}, _} = use_on(cow, "minecraft:bucket")

    assert {:pass, _} = use_on(%{cow | data: %{cow.data | age: -5}}, "minecraft:bucket")

    stew = id("minecraft:mushroom_stew")
    moo = mob("minecraft:mooshroom")

    assert {{:done, {:fill, %{item_id: ^stew}}, _, _, _, _, _, _, _}, _} =
             use_on(moo, "minecraft:bowl")

    # A brown one eats a flower for its stew's effects, once until milked.
    ref = section(%{moo | data: %{moo.data | type: "brown"}})
    assert {{:done, {:use, 1}, _, _, _, _, _, _, _}, fed} = use_item(ref, "minecraft:poppy")
    assert fed.data.stew == [{"minecraft:night_vision", 100}]
    assert {{:done, :keep, _, _, _, _, _, _, _}, _} = use_item(ref, "minecraft:dandelion")

    assert {{:done, {:fill, suspicious}, _, _, _, _, _, _, _}, milked} =
             use_item(ref, "minecraft:bowl")

    assert suspicious.components["minecraft:suspicious_stew_effects"] ==
             [{"minecraft:night_vision", 100}]

    assert milked.data.stew == nil

    # Dye colours a sheep that is not shorn, unless it is that colour.
    sheep = mob("minecraft:sheep")
    ref = section(sheep)

    assert {{:done, {:use, 1}, false, [], {_, "player", _, _, :animal}, _, _, _, _}, dyed} =
             use_item(ref, "minecraft:blue_dye")

    assert dyed.data.color == 11
    assert {:pass, _} = use_item(ref, "minecraft:blue_dye")

    assert {:pass, _} =
             use_on(%{sheep | data: %{sheep.data | sheared: true}}, "minecraft:red_dye")

    # A golden dandelion locks a baby's age back to a newborn's.
    lamb = %{sheep | data: %{sheep.data | age: -100}}

    assert {{:done, {:use, 1}, _, [{:sound_block, _, "player", 1.0, 1.0}], _, _, _, _, _}, locked} =
             use_on(lamb, "minecraft:golden_dandelion")

    assert locked.data.age_locked and locked.data.age == -24_000 and locked.mob.persistent
    assert {:pass, _} = use_on(sheep, "minecraft:golden_dandelion")
  end

  test "leads tie, untie, snip and move from knots" do
    cow = mob("minecraft:cow")

    assert {{:done, {:use, 1}, true, [{:sound, _, "neutral", 1.0, 1.0}], _, _, _, _, _}, tied} =
             use_on(cow, "minecraft:lead")

    assert tied.mob.leash.holder == {:player, @player}

    # Too far, or a mob that takes no lead: nothing.
    far = put_elem(@holder, 1, {13.5, 64.0, 0.5})
    assert {:pass, _} = use_on(cow, "minecraft:lead", holder: far)
    assert {:pass, _} = use_on(mob("minecraft:zombie"), "minecraft:lead")

    # Its holder unties it with any hand, the lead an item; in creative none.
    lead = id("minecraft:lead")

    held =
      put_in(cow.mob.leash, %{holder: {:player, @player}, id: 70, momentum: 0.0, restored: false})

    for {infinite, drops} <- [{false, 1}, {true, 0}] do
      ref = section(held)
      :ok = Native.mob_section_oracle_prepare(ref, 1, 0.0, 70)
      {{:done, :keep, _, _, _, dropped, _, _, _}, untied} = use_item(ref, nil, infinite: infinite)
      assert untied.mob.leash == nil and length(dropped) == drops
      assert Enum.all?(dropped, &match?({%{item_id: ^lead}, _, nil}, &1))
    end

    # Shears on a leashed sheep snip the lead, not its wool.
    sheep = mob("minecraft:sheep")
    ref = section(%{sheep | mob: %{sheep.mob | leash: held.mob.leash}})
    :ok = Native.mob_section_oracle_prepare(ref, 1, 0.0, 70)

    assert {{:done, {:wear, 1}, _, _, _, [_], _, _, _}, snipped} =
             use_item(ref, "minecraft:shears")

    assert snipped.mob.leash == nil and not snipped.data.sheared

    # Tied to a knot, a lead in hand takes it, the knot's lead an item.
    knot = %{holder: {:knot, {3, 64, 0}}, id: 9, momentum: 0.0, restored: false}
    ref = section(put_in(cow.mob.leash, knot))
    :ok = Native.mob_section_oracle_prepare(ref, 1, 0.0, 9)

    assert {{:done, _, _, _, _, [_], _, [{3, 64, 0}], _}, retied} =
             use_item(ref, "minecraft:lead")

    assert retied.mob.leash.holder == {:player, @player}
  end

  test "flint and steel or a fire charge lights a creeper" do
    creeper = mob("minecraft:creeper")

    assert {{:done, {:wear, 1}, true, _, _, _, _, _, _}, lit} =
             use_on(creeper, "minecraft:flint_and_steel")

    assert lit.data.ignited

    assert {{:done, {:use, 1}, true, _, _, _, _, _, _}, lit} =
             use_on(creeper, "minecraft:fire_charge")

    assert lit.data.ignited
    assert {:pass, unlit} = use_on(creeper, "minecraft:stick")
    refute unlit.data.ignited
  end

  @attacker %{uuid: @player, entity_id: 9, player: true, type: "minecraft:player", mainhand: nil}

  defp hurt(ref, hit) do
    {:ok, {{hurt, _full, died, _before, health}, _, _}} = Native.mob_section_hurt(ref, 1, hit)
    {hurt, died, health}
  end

  defp projectile(source, type, owner, amount),
    do: %{
      source: DamageSource.new(source),
      amount: amount,
      attacker: owner,
      direct: %{uuid: <<5::128>>, entity_id: 5, player: false, type: type, mainhand: nil}
    }

  test "an enderman turns projectiles away; a ghast dies to a fireball a player sent back" do
    ref = section(mob("minecraft:enderman"))

    assert hurt(ref, projectile(:arrow, "minecraft:arrow", @attacker, 5.0)) ==
             {false, false, 40.0}

    assert hurt(ref, %{source: DamageSource.new(:drown), amount: 1.0}) == {true, false, 39.0}

    ghast = mob("minecraft:ghast")
    fireball = &projectile(:fireball, "minecraft:fireball", &1, 6.0)
    assert hurt(section(ghast), fireball.(@attacker)) == {true, true, 0.0}
    other = %{@attacker | uuid: <<2::128>>, player: false, type: "minecraft:ghast"}
    assert hurt(section(ghast), fireball.(other)) == {false, false, 10.0}
  end

  test "deaths: a carried block as mined with Silk Touch; equipment by drop chance and Looting" do
    grass = Blocks.default_state("grass_block")
    ref = section(mob("minecraft:enderman", &%{&1 | data: %{&1.data | carried: grass}}))
    assert {:ok, {true, _, _}} = Native.mob_section_kill(ref, 1)
    [{1, death, {0.5, 64.0, 0.5}}] = Native.mob_section_deaths(ref, [1])
    grass_item = id("minecraft:grass_block")
    assert [%{item_id: ^grass_item, count: 1}] = death.equipment

    # A kept sword (chance 2) drops unworn; the helmet's 0.085 and Looting
    # III's 0.03 drop it worn from the mob's random; then no slot is left to
    # add experience.
    sword = %{
      ItemStack.new("minecraft:iron_sword")
      | components: %{"minecraft:enchantments" => %{"minecraft:sharpness" => 2}}
    }

    helmet = ItemStack.new("minecraft:golden_helmet")

    zombie =
      mob("minecraft:zombie", fn body ->
        %{
          body
          | mob: %{
              body.mob
              | equipment: %{mainhand: sword, head: helmet},
                drop_chances: %{mainhand: 2.0}
            }
        }
      end)

    looting = %{
      ItemStack.new("minecraft:diamond_sword")
      | components: %{"minecraft:enchantments" => %{"minecraft:looting" => 3}}
    }

    killer = %{@attacker | mainhand: looting}
    ref = section(zombie)

    hit = %{
      source: DamageSource.new(:player_attack),
      amount: 100.0,
      attacker: killer,
      direct: killer
    }

    assert hurt(ref, hit) == {true, true, 0.0}
    [{1, death, _}] = Native.mob_section_deaths(ref, [1])

    assert %{
             experience: 5,
             loot_table: "minecraft:entities/zombie",
             loot: %{killed_by_player: true}
           } = death

    golden = id("minecraft:golden_helmet")

    assert [^sword, %{item_id: ^golden, components: %{"minecraft:damage" => 58}}] =
             death.equipment
  end

  test "conversions keep what vanilla keeps" do
    zombie = mob("minecraft:zombie")
    helmet = ItemStack.new("minecraft:iron_helmet")

    baby =
      %{zombie | data: %{zombie.data | baby: true}, custom_name: "Bob"}
      |> put_in([Access.key(:mob), Access.key(:equipment)], %{head: helmet})
      |> put_in([Access.key(:mob), Access.key(:living), Access.key(:fire_ticks)], 40)

    conversions =
      for {from, to} <- [
            {zombie, "minecraft:husk"},
            {baby, "minecraft:zombie_villager"},
            {zombie, "minecraft:drowned"},
            {baby, "minecraft:drowned"},
            {mob("minecraft:husk"), "minecraft:zombie"},
            {mob("minecraft:skeleton"), "minecraft:stray"}
          ],
          special <- [0.0, 0.5, 1.0] do
        {:ok, record} = Native.mob_section_convert(section(from), 1, <<3::128>>, to, special)
        assert record.type == to and record.uuid == <<3::128>>
        record
      end

    # A baby stays one, named and armoured.
    drowned = Enum.find(conversions, &(&1.type == "minecraft:drowned" and &1.data.baby))
    assert drowned.custom_name == "Bob" and drowned.mob.equipment == %{head: helmet}

    # Pins the current native records.
    assert :erlang.phash2(conversions) == 103_330_153
  end

  test "a dead cube splits into its halves" do
    splits =
      for {type, size, halves} <- [
            {"minecraft:slime", 4, 3},
            {"minecraft:magma_cube", 2, 3},
            {"minecraft:slime", 1, 0}
          ] do
        body = mob(type, &%{&1 | data: %{&1.data | size: size}, custom_name: "Cube"})
        body = put_in(body.mob.living.health.value, 0.0)
        split = Native.mob_section_split(section(body), 1)
        assert length(split) == halves

        for {record, _} <- split do
          assert record.data.size == div(size, 2) and record.custom_name == "Cube"
          assert record.mob.living.health.value == div(size, 2) * div(size, 2) * 1.0
        end

        split
      end

    # A living cube does not split.
    assert Native.mob_section_split(section(mob("minecraft:slime")), 1) == []
    # Pins the current native halves (their places from the cube's random).
    assert :erlang.phash2(splits) == 5_370_229
  end

  @level %{
    time: 0,
    day: 0,
    difficulty: :normal,
    darken: 0,
    bright: false,
    monsters_burn: false,
    halloween: false,
    mob_griefing: true,
    mob_drops: true,
    entity_drops: true,
    universal_anger: false,
    goals: false,
    min_y: -64,
    max_y: 319,
    sea_level: 63,
    border: nil,
    knots: [],
    wet: false,
    zoom_seed: 0,
    tops: nil,
    no_chunks: true
  }

  test "status effects tick on a mob: poison's hits and regeneration's heals" do
    stone = Blocks.default_state("stone")

    view =
      {:states,
       for x <- -4..4, y <- 60..68, z <- -4..4, into: <<>> do
         <<x::signed-32, y::signed-32, z::signed-32, if(y < 64, do: stone, else: 0)::16>>
       end}

    cow = mob("minecraft:cow", &%{&1 | on_ground: true, mob: %{&1.mob | no_ai: true}})
    ref = section(cow)
    native = %NativeMobs{ref: ref}
    poison = EffectTypes.id("poison")
    regeneration = EffectTypes.id("regeneration")
    {:ok, _} = Native.mob_section_effect(ref, 1, {:add, poison, {80, 1, false, true, true}})
    {:ok, _} = Native.mob_section_effect(ref, 1, {:add, regeneration, {60, 1, false, true, true}})
    {_, row, _, _} = NativeMobs.body(native, 1)
    entry = %{entity: %{uuid: <<1::128>>, x: 0.5, y: 64.0, z: 0.5}, body: row, native: ref}
    env = %{region: nil, level: @level, players: [], items: [], random: 0}

    # Each tick its turn, then its timers (its owner's age pass).
    trace =
      Enum.map_reduce(1..100, {entry, env}, fn _, {entry, env} ->
        {[step], env} = MobTicks.native_steps(view, [{1, entry}], native, env)
        [{1, _, _, _, _}] = Native.mob_section_age(ref, [{1, 1}], true)
        living = record(ref).mob.living
        {{living.health.value, living.effects}, {%{entry | body: step.body}, env}}
      end)
      |> elem(0)

    # Poison II hurts at each twelfth tick left of 80 (tick 9, 21, ... 69),
    # regeneration II heals at 50 and 25 left of 60 (ticks 11 and 36).
    health = Enum.map(trace, &elem(&1, 0))
    assert Enum.at(health, 8) == 9.0 and Enum.at(health, 10) == 10.0
    assert Enum.at(health, 35) == 9.0
    assert List.last(trace) == {6.0, %{}}
  end
end
