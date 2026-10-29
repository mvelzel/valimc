defmodule Valimc.NativeMobFactsTest do
  @moduledoc """
  The native mob facts (VMC-081d, `Valimc.AI.NativeFacts`) answer as the
  Elixir accessors they mirror, over the real generated files.
  """
  use ExUnit.Case, async: true
  alias Valimc.AI.{Facts, Villagers}
  alias Valimc.Data.{Blocks, EffectTypes, EntityTypes, HostileFacts}
  alias Valimc.Entity.Animal
  alias Valimc.Living.{Attributes, Weapons}
  alias Valimc.Native
  alias Valimc.Protocol.{CombatPackets, Data, DamageTypes, ItemTypes}

  setup_all do
    Valimc.AI.NativeFacts.install!()
  end

  defp fact(query), do: Native.mob_parity_fact(query)

  test "entity types, categories, attributes, effects and items" do
    for name <- EntityTypes.names() do
      t = EntityTypes.fetch(name)
      attributes = if t.attributes, do: Enum.sort(t.attributes), else: []

      assert fact({:entity, name}) ==
               {t.id, Atom.to_string(t.category), t.width * 1.0, t.height * 1.0,
                t.eye_height * 1.0, t.fire_immune, t.enemy, t.tracking_range, t.update_interval,
                EntityTypes.living?(name), attributes, t.loot_table},
             name

      assert (fact({:experience, name}) || 0) == Weapons.experience(name)
    end

    for {"minecraft:" <> tag, _} <- Data.tags()["minecraft:entity_type"],
        name <-
          ~w(minecraft:zombie minecraft:skeleton minecraft:cow minecraft:axolotl minecraft:piglin) do
      assert fact({:entity_tag, name, "minecraft:" <> tag}) == EntityTypes.tag?(name, tag)
    end

    for category <- ~w(ambient axolotls creature misc monster water_creature)a do
      c = EntityTypes.category(category)

      assert fact({:category, Atom.to_string(category)}) ==
               {c["max"], c["friendly"], c["persistent"], c["despawn_distance"],
                c["no_despawn_distance"]}
    end

    for name <- ~w(max_health movement_speed follow_range step_height safe_fall_distance) do
      a = Attributes.fetch(name)
      assert fact({:attribute, name}) == {a["id"], a["default"], a["min"], a["max"]}
    end

    for id <- 0..(EffectTypes.count() - 1),
        do: assert(fact({:effect, EffectTypes.name(id)}) == id)

    for id <- 0..(ItemTypes.count() - 1)//7 do
      assert fact({:item, ItemTypes.item(id)["name"]}) == id
    end
  end

  test "the block registry and tags" do
    for state <- 0..(Blocks.state_count() - 1)//13 do
      assert fact({:block, state}) == {Blocks.block_id(state), Blocks.properties(state)}
    end

    for {registry, tags} <- Data.tags(),
        registry in ~w(minecraft:item minecraft:block minecraft:damage_type minecraft:worldgen/biome),
        {tag, ids} <- Enum.take(tags, 25),
        id <- Enum.take(ids, 3) ++ [100_000] do
      assert fact({:tag, registry, tag, id}) == id in ids
    end

    for type <- Data.registries()["minecraft:damage_type"] do
      "minecraft:" <> name = type
      atom = String.to_atom(name)
      assert fact({:damage, type}) == DamageTypes.id(atom)

      for tag <- ~w(is_fire bypasses_armor is_projectile panic_causes)a do
        assert fact({:damage_tag, type, "minecraft:#{tag}"}) == DamageTypes.tag?(atom, tag)
      end
    end

    for {name, temperature, frozen, precipitation} <- Valimc.Worldgen.Facts.biome_climates() do
      assert fact({:climate, name}) == {temperature, frozen, precipitation}
    end
  end

  test "AI facts and sounds" do
    names = Facts.path_type_names()

    for type <- Facts.mobs() do
      m = Facts.mob(type)
      flags = fn list -> Enum.reduce(list, 0, &(&2 + flag(&1))) end
      goals = fn goals -> for {p, n, f} <- goals, do: {p, n, flags.(f)} end

      assert fact({:ai_mob, type}) ==
               {m.max_head_y_rot, m.max_head_x_rot, m.head_rot_speed, m.ambient_sound,
                m.ambient_interval, m.volume, m.monster, Enum.map(names, &m.malus[&1]),
                goals.(m.goals), goals.(m.targets)},
             type

      if m.ambient_sound,
        do: assert(fact({:sound, m.ambient_sound}) == Facts.sound_id(m.ambient_sound))
    end

    assert fact({:ai_mob, "minecraft:item"}) == nil

    for item <- ~w(minecraft:creeper_head minecraft:zombie_head minecraft:piglin_head
                   minecraft:skeleton_skull minecraft:diamond) do
      expected =
        case Facts.visibility(item) do
          nil -> nil
          v -> {v.visibility, Atom.to_string(v.slot), v.types}
        end

      assert fact({:visibility, item}) == expected
    end

    for face <- 0..5, do: assert(fact({:shulker_look, face}) == Facts.shulker_look(face))
    assert fact({:swing, false}) == Facts.swing_fields(:main_hand)
    assert fact({:swing, true}) == Facts.swing_fields(:off_hand)

    for type <- EntityTypes.names() do
      s = CombatPackets.mob_sounds(type)

      assert fact({:mob_sounds, type}) ==
               {s["hurt_sound"], s["death_sound"], s["sound_source"], s["animal"]}

      for sound <- [s["hurt_sound"], s["death_sound"]], sound != nil do
        assert fact({:sound, sound}) != nil
      end
    end

    for name <- ~w(minecraft:entity.creeper.primed minecraft:entity.cow.ambient
                   minecraft:entity.villager.work_farmer) do
      assert fact({:sound, name}) != nil
    end

    assert fact({:sound, "minecraft:entity.cow.ambient"}) ==
             Animal.sound_id("minecraft:entity.cow.ambient")

    assert fact({:sound, "minecraft:entity.creeper.primed"}) ==
             HostileFacts.sound_id("minecraft:entity.creeper.primed")
  end

  defp flag(:move), do: 1
  defp flag(:look), do: 2
  defp flag(:jump), do: 4
  defp flag(:target), do: 8

  test "hostile facts" do
    assert fact({:drop_chance}) == HostileFacts.drop_chance()

    for type <- EntityTypes.names() do
      assert fact({:baby, type}) == HostileFacts.baby(type)
      assert fact({:water_sensitive, type}) == HostileFacts.water_sensitive?(type)
    end

    for ticks <- -48_000..48_000//157,
        do: assert(fact({:monsters_burn, ticks}) == HostileFacts.monsters_burn?(ticks))

    for id <- 0..(ItemTypes.count() - 1)//3, item = ItemTypes.item(id)["name"] do
      expected =
        case HostileFacts.equippable(item) do
          nil -> nil
          {slot, types} -> {Atom.to_string(slot), types, HostileFacts.equip_sound(item)}
        end

      assert fact({:equippable, item}) == expected, item
    end

    for id <- 0..(EffectTypes.count() - 1), amplifier <- 0..6 do
      name = EffectTypes.name(id)

      expected =
        for {attribute, mid, amount, op} <- HostileFacts.effect_modifiers(name, amplifier),
            do: {attribute, mid, amount, op}

      assert fact({:effect_modifiers, name, amplifier}) == expected
    end

    for biome <- Data.registries()["minecraft:worldgen/biome"] do
      assert fact({:villager_type, biome}) == HostileFacts.villager_type(biome)
    end

    for slot <- ~w(head chest legs feet)a, material <- 0..5 do
      assert fact({:armour, Atom.to_string(slot), material}) ==
               HostileFacts.armour(slot, material)
    end
  end

  test "animal and village facts" do
    assert fact({:group_baby_chance}) == Animal.group_baby_chance()

    for type <- ~w(minecraft:dolphin minecraft:squid minecraft:glow_squid),
        do:
          assert(
            fact({:water_ageable, type}) ==
              {Animal.water_ageable(type).baby_chance, Animal.water_ageable(type).baby}
          )

    foods = for id <- 0..(ItemTypes.count() - 1)//5, do: id

    for type <- EntityTypes.names() do
      assert fact({:animal, type}) == Animal.animal?(type)
      assert fact({:monster, type}) == Animal.monster?(type)

      if Animal.animal?(type) do
        assert fact({:animal_baby, type}) == Animal.dimensions(%{type: type, data: %{age: -1}})

        for item <- [nil | foods],
            do: assert(fact({:food, type, item}) == Animal.food?(type, item))
      end
    end

    for {"minecraft:" <> _ = tag, _} <- Data.tags()["minecraft:worldgen/biome"],
        biome <- Data.registries()["minecraft:worldgen/biome"] do
      assert fact({:biome_in, biome, tag}) == Animal.biome_in?(biome, tag)
    end

    for name <- Villagers.professions() do
      p = Villagers.profession(name)
      assert fact({:profession, name}) == {p.id, p.held, p.acquirable, p.secondary, p.work_sound}
    end

    for ticks <- -24_000..48_000//211, baby <- [false, true] do
      assert fact({:scheduled, ticks, baby}) == Atom.to_string(Villagers.scheduled(ticks, baby))
    end

    for biome <- Data.registries()["minecraft:worldgen/biome"] ++ ["minecraft:nowhere"] do
      assert fact({:type_of_biome, biome}) == Villagers.type_of_biome(biome)
    end
  end
end
