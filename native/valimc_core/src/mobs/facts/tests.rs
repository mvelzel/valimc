//! Facts parsing over small fixtures (the vanilla stages read the real
//! files).

use super::*;
use crate::worldgen::json::Json;

/// A minimal JSON reader for fixtures.
pub(crate) fn json(text: &str) -> Json {
    fn value(s: &[u8], i: &mut usize) -> Json {
        skip(s, i);
        match s[*i] {
            b'{' => {
                *i += 1;
                let mut fields = Vec::new();
                loop {
                    skip(s, i);
                    if s[*i] == b'}' {
                        *i += 1;
                        break;
                    }
                    let Json::String(k) = value(s, i) else {
                        panic!("key")
                    };
                    skip(s, i);
                    assert_eq!(s[*i], b':');
                    *i += 1;
                    fields.push((k, value(s, i)));
                    skip(s, i);
                    if s[*i] == b',' {
                        *i += 1;
                    }
                }
                fields.sort_by(|a, b| a.0.cmp(&b.0));
                Json::Object(fields)
            }
            b'[' => {
                *i += 1;
                let mut items = Vec::new();
                loop {
                    skip(s, i);
                    if s[*i] == b']' {
                        *i += 1;
                        break;
                    }
                    items.push(value(s, i));
                    skip(s, i);
                    if s[*i] == b',' {
                        *i += 1;
                    }
                }
                Json::Array(items)
            }
            b'"' => {
                let start = *i + 1;
                *i = start;
                while s[*i] != b'"' {
                    *i += 1;
                }
                *i += 1;
                Json::String(String::from_utf8(s[start..*i - 1].to_vec()).unwrap())
            }
            b't' => {
                *i += 4;
                Json::Bool(true)
            }
            b'f' => {
                *i += 5;
                Json::Bool(false)
            }
            b'n' => {
                *i += 4;
                Json::Null
            }
            _ => {
                let start = *i;
                while *i < s.len() && b"-+.eE0123456789".contains(&s[*i]) {
                    *i += 1;
                }
                Json::Number(std::str::from_utf8(&s[start..*i]).unwrap().parse().unwrap())
            }
        }
    }
    fn skip(s: &[u8], i: &mut usize) {
        while *i < s.len() && s[*i].is_ascii_whitespace() {
            *i += 1;
        }
    }
    value(text.as_bytes(), &mut 0)
}

/// A small but complete installer map.
pub(crate) fn fixture() -> MobFacts {
    let text = r#"{
      "registries": {
        "minecraft:damage_type": ["minecraft:fall", "minecraft:in_fire"],
        "minecraft:worldgen/biome": ["minecraft:desert", "minecraft:plains"]
      },
      "tags": {
        "minecraft:entity_type": {"minecraft:undead": [1]},
        "minecraft:worldgen/biome": {"minecraft:is_hot": [0]},
        "minecraft:item": {"minecraft:cow_food": [2]},
        "minecraft:damage_type": {"minecraft:is_fire": [1]}
      },
      "entities": {
        "types": {
          "minecraft:cow": {"id": 0, "category": "creature", "width": 0.9, "height": 1.4,
            "eye_height": 1.3, "fire_immune": false, "summonable": true, "saved": true,
            "peaceful": true, "spawn_far": false, "enemy": false, "tracking_range": 10,
            "update_interval": 3, "track_deltas": true, "description": "entity.minecraft.cow",
            "loot_table": "minecraft:entities/cow", "spawn_placement": "on_ground",
            "spawn_heightmap": "MOTION_BLOCKING_NO_LEAVES",
            "attributes": {"minecraft:max_health": 10.0, "minecraft:movement_speed": 0.20000000298023224}},
          "minecraft:zombie": {"id": 1, "category": "monster", "width": 0.6, "height": 1.95,
            "eye_height": 1.74, "fire_immune": false, "summonable": true, "saved": true,
            "peaceful": false, "spawn_far": false, "enemy": true, "tracking_range": 8,
            "update_interval": 3, "track_deltas": true, "description": "entity.minecraft.zombie",
            "loot_table": null, "attributes": {"minecraft:max_health": 20.0}},
          "minecraft:arrow": {"id": 2, "category": "misc", "width": 0.5, "height": 0.5,
            "eye_height": 0.13, "fire_immune": false, "summonable": true, "saved": true,
            "peaceful": true, "spawn_far": true, "enemy": false, "tracking_range": 4,
            "update_interval": 20, "track_deltas": false, "description": "entity.minecraft.arrow",
            "loot_table": null}
        },
        "categories": {"monster": {"max": 70, "friendly": false, "persistent": false,
          "despawn_distance": 128, "no_despawn_distance": 32}},
        "fields": {"health": {"index": 9, "serializer": 3}}
      },
      "attributes": {
        "minecraft:max_health": {"id": 1, "default": 20.0, "min": 1.0, "max": 1024.0, "syncable": true},
        "minecraft:movement_speed": {"id": 0, "default": 0.7, "min": 0.0, "max": 1024.0, "syncable": true}
      },
      "effects": ["minecraft:speed", "minecraft:fire_resistance"],
      "items": {
        "minecraft:air": {"id": 0, "max_stack_size": 64},
        "minecraft:zombie_head": {"id": 1, "max_stack_size": 64},
        "minecraft:wheat": {"id": 2, "max_stack_size": 64},
        "minecraft:iron_helmet": {"id": 3, "max_stack_size": 1},
        "minecraft:allium": {"id": 4, "max_stack_size": 64}
      },
      "blocks": {
        "state_count": 5, "classes": ["AirBlock", "CropBlock"],
        "properties": [["age", ["0", "1", "2", "3"]]],
        "blocks": [["air", 0, 0, 0, []], ["wheat", 1, 1, 1, [0]]]
      },
      "climates": [["minecraft:desert", 2.0, false, false], ["minecraft:plains", 0.8, false, true]],
      "structure_tags": {"minecraft:cats_spawn_in": ["minecraft:swamp_hut"]},
      "ai": {
        "path_types": [{"name": "blocked", "malus": -1.0}, {"name": "open", "malus": 0.0},
                       {"name": "water", "malus": 8.0}],
        "mobs": {"minecraft:zombie": {"max_head_y_rot": 75, "max_head_x_rot": 40,
          "head_rot_speed": 10, "ambient_sound": "minecraft:entity.zombie.ambient",
          "ambient_sound_interval": 80, "sound_volume": 1.0, "monster": true,
          "malus": {"water": -1.0},
          "goals": [[8, "LookAtPlayerGoal", ["look"]], [3, "ZombieAttackGoal", ["move", "look"]]],
          "targets": [[1, "HurtByTargetGoal", ["target"]]]}},
        "mob_visibility": {"minecraft:zombie_head": {"visibility": 0.5, "slot": "head",
          "types": ["minecraft:zombie"]}},
        "sounds": {"minecraft:entity.zombie.ambient": 7},
        "shulker_look": [[0, 0, 1065353216, 1065353216, 0, 0]],
        "swing_fields": "000106"
      },
      "combat": {
        "mobs": {"minecraft:zombie": {"hurt_sound": "minecraft:entity.zombie.hurt",
          "death_sound": "minecraft:entity.zombie.death", "sound_source": 5, "animal": false}},
        "sounds": {"minecraft:entity.zombie.hurt": 8, "minecraft:entity.zombie.ambient": 7},
        "sound_sources": {"neutral": 6, "hostile": 5},
        "particles": {"minecraft:sweep_attack": 77},
        "damage_types": {"minecraft:fall": {"message_id": "fall", "scaling": "never"},
          "minecraft:in_fire": {"message_id": "inFire", "scaling": "always"}},
        "experience": {"minecraft:zombie": 5},
        "items": {"minecraft:iron_helmet": {"minecraft:attribute_modifiers": [
          {"type": "minecraft:max_health", "id": "minecraft:armor.helmet", "amount": 2.0,
           "operation": "add_value", "slot": "head"}]}}
      },
      "hostile": {
        "armour": {"head": ["minecraft:iron_helmet"]},
        "drop_chance": 1034818683,
        "spawn_enchanting": {"min_cost": 5, "max_cost_span": 17, "tag": "minecraft:on_mob_spawn_equipment"},
        "babies": {"minecraft:zombie": [1056629064, 1065017672, 1061578342]},
        "equippable": {"minecraft:zombie_head": ["head", null, "minecraft:item.armor.equip_generic"]},
        "effect_modifiers": {"minecraft:speed": [["minecraft:movement_speed", "minecraft:effect.speed",
          "add_multiplied_total", ["3fc99999a0000000", "3fd99999a0000000", "3fe3333338000000", "3fe99999a0000000"]]]},
        "sounds": {"minecraft:entity.creeper.primed": 481},
        "water_sensitive": ["minecraft:zombie"],
        "monsters_burn": {"period": 24000, "keyframes": [{"ticks": 12542, "value": false},
          {"ticks": 23460, "value": true}]},
        "villager_types": {"minecraft:desert": "minecraft:desert"},
        "default_villager_type": "minecraft:plains",
        "villager_type_ids": ["minecraft:desert", "minecraft:plains"],
        "professions": ["minecraft:none"]
      },
      "animal": {
        "spawn_group_baby_chance": 1028443341,
        "water_ageable": {},
        "animals": {"minecraft:cow": {"adult": [1063675494, 1068708659, 1067869798],
          "baby": [1055286886, 1060320051, 1060152279], "food": ["minecraft:wheat"]}},
        "monsters": ["minecraft:zombie"],
        "stew_flowers": {"minecraft:allium": [["minecraft:fire_resistance", 60]]},
        "variants": {"minecraft:cat_variant": [{"name": "minecraft:black",
          "selectors": [{"priority": 1, "structures": "minecraft:cats_spawn_in"},
                        {"priority": 0, "biomes": null}, {"priority": 2, "moon": [0.9, null]}]}]},
        "sound_variants": {"minecraft:cow_sound_variant": {"minecraft:classic":
          {"ambient": "minecraft:entity.cow.ambient"}}},
        "sounds": {"minecraft:entity.cow.ambient": 9}
      },
      "village": {
        "poi_types": {"minecraft:farmer": {"states": [3], "max_tickets": 1, "valid_range": 1,
          "tags": ["minecraft:acquirable_job_site"]}},
        "professions": [{"name": "minecraft:farmer", "id": 1, "held": ["minecraft:farmer"],
          "acquirable": ["minecraft:farmer"], "secondary_poi": [], "requested_items": [],
          "work_sound": "minecraft:entity.villager.work_farmer"},
          {"name": "minecraft:none", "id": 0, "held": [], "acquirable": [], "secondary_poi": [],
          "requested_items": [], "work_sound": null}],
        "villager_types": [{"name": "minecraft:desert", "id": 0}],
        "villager_type_by_biome": {"minecraft:desert": "minecraft:desert"},
        "schedules": {"minecraft:overworld": {"adult": [[0, "rest"], [2000, "work"]],
          "baby": [[0, "rest"], [3000, "play"]]}},
        "sounds": {"minecraft:entity.villager.work_farmer": 10}
      }
    }"#;
    MobFacts::parse(&json(text)).unwrap()
}

#[test]
fn registries_resolve_names_both_ways() {
    let f = fixture();
    let zombie = f.entities.fetch("zombie").unwrap();
    assert_eq!((zombie.id, zombie.width, zombie.eye_height), (1, 0.6, 1.74));
    assert!(zombie.living() && !f.entities.get(2).unwrap().living());
    assert_eq!(
        f.entities.get(0).unwrap().attribute("movement_speed"),
        Some(0.20000000298023224)
    );
    assert!(f.entity_tag(1, "undead") && !f.entity_tag(0, "minecraft:undead"));
    assert_eq!(f.attributes.fetch("max_health").unwrap().id, 1);
    assert_eq!(f.effects.id("fire_resistance"), Some(1));
    assert_eq!(f.items.id("minecraft:wheat"), Some(2));
    assert_eq!(f.items.max_stack[3], 1);
    assert_eq!(f.blocks.block_id(3), Some(1));
    assert_eq!(f.blocks.property(3, "age"), Some("2"));
    assert_eq!(f.blocks.state("wheat", &[("age", "3")]), Some(4));
    assert_eq!(f.blocks.default_state("minecraft:wheat"), Some(1));
    assert!(f.blocks.is(2, "wheat"));
    assert!(f.biome_in(Some(0), "is_hot") && !f.biome_in(None, "is_hot"));
    assert!(f.damage_tag(1, "is_fire"));
    assert_eq!(f.damage_types.id("in_fire"), Some(1));
    assert!(f.climates[1].precipitation && !f.climates[0].precipitation);
}

#[test]
fn sound_tables_merge() {
    let f = fixture();
    for (name, id) in [
        ("minecraft:entity.zombie.ambient", 7),
        ("minecraft:entity.creeper.primed", 481),
        ("minecraft:entity.cow.ambient", 9),
        ("minecraft:entity.villager.work_farmer", 10),
    ] {
        assert_eq!(f.sounds.id(name), Some(id));
    }
    assert_eq!(f.sounds.source("hostile"), Some(5));
    let mut j = json(r#"{"sounds": {"a": 1}, "sound_sources": {}, "particles": {}}"#);
    let other = json(r#"{"a": 2}"#);
    assert!(Sounds::parse(&j, &[("ai", &other)]).is_err());
    j = json(r#"{"sounds": {"a": 2}, "sound_sources": {}, "particles": {}}"#);
    assert!(Sounds::parse(&j, &[("ai", &other)]).is_ok());
}

#[test]
fn ai_facts_merge_malus_and_flags() {
    let f = fixture();
    let zombie = f.ai.mob(1).unwrap();
    assert_eq!(zombie.malus, vec![-1.0, 0.0, -1.0]);
    assert_eq!(zombie.goals[1].flags, ai::MOVE | ai::LOOK);
    assert_eq!(zombie.targets[0].flags, ai::TARGET);
    let hidden = &f.ai.visibility[&1];
    assert_eq!((hidden.visibility, hidden.slot), (0.5, Slot::Head));
    assert_eq!(hidden.types, vec![1]);
    assert_eq!(f.ai.shulker_look[0][2], 1.0);
    assert_eq!(f.ai.swing_fields(true), vec![1, 1, 6]);
}

#[test]
fn family_facts_decode_as_the_elixir_does() {
    let f = fixture();
    assert_eq!(f.combat.mob_sounds(1).source, 5);
    assert_eq!(f.combat.mob_sounds(0), &f.combat.unmodelled);
    assert_eq!(f.combat.unmodelled.source, 6);
    assert_eq!(f.combat.items[&3][0].attribute, 1);
    assert_eq!(f.hostile.drop_chance, 0.085);
    assert_eq!(f.hostile.babies[&1][0], f32::from_bits(1056629064));
    assert!(f.hostile.monsters_burn(23_500) && !f.hostile.monsters_burn(12_600));
    assert!(f.hostile.monsters_burn(-100));
    let m = f.hostile.effect_modifiers(0, 1);
    assert_eq!(m[0].2, f64::from_bits(0x3fd99999a0000000));
    assert_eq!(
        f.hostile.effect_modifiers(0, 5)[0].2,
        f64::from_bits(0x3fc99999a0000000) * 6.0
    );
    assert_eq!(
        f.hostile.villager_type("minecraft:jungle"),
        "minecraft:plains"
    );
    assert!(f.animal.food(0, Some(2)) && !f.animal.food(0, None) && !f.animal.food(1, Some(2)));
    assert!(f.animal.monster(1));
    assert_eq!(f.animal.stew_flowers["minecraft:allium"], vec![(1, 60)]);
    let cat = &f.animal.variants["minecraft:cat_variant"][0];
    assert!(
        matches!(&cat.selectors[0].1, Some(families::Condition::Structures(s)) if s.contains("minecraft:swamp_hut"))
    );
    assert_eq!(cat.selectors[1].1, None);
    assert_eq!(
        cat.selectors[2].1,
        Some(families::Condition::Moon(Some(0.9), None))
    );
    assert_eq!(f.village.professions[0].name, "minecraft:none");
    assert_eq!(f.village.scheduled(2500, false), "work");
    assert_eq!(f.village.scheduled(-1, true), "play");
    assert_eq!(f.village.profession_for("minecraft:farmer").unwrap().id, 1);
}
