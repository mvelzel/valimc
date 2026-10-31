//! The living rules, combat and vitals over a small facts fixture (the
//! vanilla stages check them on the real facts).

use super::super::combat::{self, Attacker, Event, Hit, NoFamilies, NoMind, Rules, SoundRef};
use super::super::facts::tests::json;
use super::super::facts::MobFacts;
use super::super::model::{Effects, Health, NativeMob, Rung, Slot};
use super::super::random::LegacyRandom;
use super::super::term::{Map, Value};
use super::super::vitals::{self, Moved, Sky};
use super::burning::Operation;
use super::mob::Type;
use super::*;
use crate::physics::player::contacts::{Contact, Touched};

const DAMAGE: [&str; 17] = [
    "on_fire",
    "in_fire",
    "lava",
    "drown",
    "magic",
    "indirect_magic",
    "wither",
    "mob_attack",
    "generic_kill",
    "hot_floor",
    "campfire",
    "cactus",
    "sweet_berry_bush",
    "player_attack",
    "fall",
    "freeze",
    "falling_anvil",
];

const EFFECTS: [&str; 18] = [
    "speed",
    "slowness",
    "regeneration",
    "poison",
    "wither",
    "hunger",
    "instant_health",
    "instant_damage",
    "saturation",
    "resistance",
    "fire_resistance",
    "water_breathing",
    "conduit_power",
    "breath_of_the_nautilus",
    "jump_boost",
    "slow_falling",
    "levitation",
    "absorption",
];

/// `(name, id, default, min, max)`.
const ATTRIBUTES: [(&str, i32, f64, f64, f64); 11] = [
    ("movement_speed", 0, 0.7, 0.0, 1024.0),
    ("max_health", 1, 20.0, 1.0, 1024.0),
    ("armor", 2, 0.0, 0.0, 30.0),
    ("armor_toughness", 3, 0.0, 0.0, 20.0),
    ("knockback_resistance", 4, 0.0, 0.0, 1.0),
    ("burning_time", 5, 1.0, 0.0, 1024.0),
    ("oxygen_bonus", 6, 0.0, 0.0, 1024.0),
    ("safe_fall_distance", 7, 3.0, -1024.0, 1024.0),
    ("fall_damage_multiplier", 8, 1.0, 0.0, 100.0),
    ("attack_damage", 9, 2.0, 0.0, 2048.0),
    ("attack_knockback", 10, 0.0, 0.0, 5.0),
];

fn quoted(names: impl Iterator<Item = String>) -> String {
    names
        .map(|n| format!("\"{n}\""))
        .collect::<Vec<_>>()
        .join(",")
}

fn ids(names: &[&str]) -> String {
    names
        .iter()
        .map(|n| DAMAGE.iter().position(|d| d == n).unwrap().to_string())
        .collect::<Vec<_>>()
        .join(",")
}

/// Mob facts: a zombie (water sensitive, in daylight burning), a cow and a
/// fire-immune blaze; iron armour and a sword.
fn mob_facts() -> MobFacts {
    let damage_registry = quoted(DAMAGE.iter().map(|d| format!("minecraft:{d}")));
    let damage_rows = DAMAGE
        .iter()
        .map(|d| format!("\"minecraft:{d}\": {{\"message_id\": \"{d}\", \"scaling\": \"never\"}}"))
        .collect::<Vec<_>>()
        .join(",");
    let effects = quoted(EFFECTS.iter().map(|e| format!("minecraft:{e}")));
    let attributes = ATTRIBUTES
        .iter()
        .map(|(n, id, d, lo, hi)| {
            format!(
                "\"minecraft:{n}\": {{\"id\": {id}, \"default\": {d:?}, \"min\": {lo:?}, \"max\": {hi:?}, \"syncable\": true}}"
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let entity = |name: &str, id: i32, fire: bool, health: f64, armor: f64| {
        format!(
            "\"minecraft:{name}\": {{\"id\": {id}, \"category\": \"monster\", \"width\": 0.6, \"height\": 1.95,
              \"eye_height\": 1.74, \"fire_immune\": {fire}, \"summonable\": true, \"saved\": true,
              \"peaceful\": false, \"spawn_far\": false, \"enemy\": true, \"tracking_range\": 8,
              \"update_interval\": 3, \"track_deltas\": true, \"description\": \"entity.minecraft.{name}\",
              \"loot_table\": \"minecraft:entities/{name}\",
              \"attributes\": {{\"minecraft:max_health\": {health:?}, \"minecraft:armor\": {armor:?},
                \"minecraft:attack_damage\": 3.0}}}}"
        )
    };
    let text = format!(
        r#"{{
      "registries": {{
        "minecraft:damage_type": [{damage_registry}],
        "minecraft:worldgen/biome": ["minecraft:plains"]
      }},
      "tags": {{
        "minecraft:entity_type": {{"minecraft:burn_in_daylight": [0], "minecraft:fall_damage_immune": [2]}},
        "minecraft:worldgen/biome": {{}},
        "minecraft:item": {{"minecraft:enchantable/armor": [3]}},
        "minecraft:damage_type": {{
          "minecraft:is_fire": [{fire}],
          "minecraft:bypasses_armor": [{bypass}],
          "minecraft:is_fall": [{fall}],
          "minecraft:is_freezing": [{freeze}],
          "minecraft:damages_helmet": [{anvil}],
          "minecraft:no_knockback": [{no_knockback}],
          "minecraft:bypasses_invulnerability": [{kill}]
        }}
      }},
      "entities": {{
        "types": {{ {zombie}, {cow}, {blaze} }},
        "categories": {{}},
        "fields": {{}}
      }},
      "attributes": {{ {attributes} }},
      "effects": [{effects}],
      "items": {{
        "minecraft:air": {{"id": 0, "max_stack_size": 64}},
        "minecraft:iron_sword": {{"id": 1, "max_stack_size": 1}},
        "minecraft:iron_chestplate": {{"id": 2, "max_stack_size": 1}},
        "minecraft:iron_helmet": {{"id": 3, "max_stack_size": 1}}
      }},
      "blocks": {{
        "state_count": 3, "classes": ["AirBlock", "Block"], "properties": [],
        "blocks": [["air", 0, 0, 0, []], ["stone", 1, 1, 1, []], ["bubble_column", 2, 2, 1, []]]
      }},
      "climates": [["minecraft:plains", 0.8, false, true]],
      "structure_tags": {{}},
      "ai": {{
        "path_types": [{{"name": "blocked", "malus": -1.0}}],
        "mobs": {{"minecraft:zombie": {{"max_head_y_rot": 75, "max_head_x_rot": 40,
          "head_rot_speed": 10, "ambient_sound": "minecraft:entity.zombie.ambient",
          "ambient_sound_interval": 80, "sound_volume": 1.0, "monster": true,
          "malus": {{}}, "goals": [], "targets": []}}}},
        "mob_visibility": {{}},
        "sounds": {{"minecraft:entity.generic.extinguish_fire": 3}},
        "shulker_look": [[0, 0, 1065353216, 1065353216, 0, 0]],
        "swing_fields": "000106"
      }},
      "combat": {{
        "mobs": {{"minecraft:zombie": {{"hurt_sound": "minecraft:entity.zombie.hurt",
          "death_sound": "minecraft:entity.zombie.death", "sound_source": 5, "animal": false}},
          "minecraft:cow": {{"hurt_sound": null, "death_sound": null, "sound_source": 6, "animal": true}}}},
        "sounds": {{"minecraft:entity.zombie.hurt": 8}},
        "sound_sources": {{"neutral": 6, "hostile": 5}},
        "particles": {{}},
        "damage_types": {{ {damage_rows} }},
        "experience": {{"minecraft:zombie": 5}},
        "items": {{
          "minecraft:iron_sword": {{"minecraft:attribute_modifiers": [
            {{"type": "minecraft:attack_damage", "id": "minecraft:base_attack_damage", "amount": 5.0,
             "operation": "add_value", "slot": "mainhand"}}]}},
          "minecraft:iron_chestplate": {{"minecraft:attribute_modifiers": [
            {{"type": "minecraft:armor", "id": "minecraft:armor.chestplate", "amount": 6.0,
             "operation": "add_value", "slot": "chest"}}]}}
        }}
      }},
      "hostile": {{
        "armour": {{}}, "drop_chance": 1034818683,
        "spawn_enchanting": {{"min_cost": 5, "max_cost_span": 17, "tag": "x"}},
        "babies": {{}}, "equippable": {{}},
        "effect_modifiers": {{"minecraft:speed": [["minecraft:movement_speed", "minecraft:effect.speed",
          "add_multiplied_total", ["3fc99999a0000000"]]]}},
        "sounds": {{}}, "water_sensitive": ["minecraft:blaze"],
        "monsters_burn": {{"period": 24000, "keyframes": [{{"ticks": 0, "value": true}}]}},
        "villager_types": {{}}, "default_villager_type": "minecraft:plains",
        "villager_type_ids": [], "professions": []
      }},
      "animal": {{
        "spawn_group_baby_chance": 1028443341, "water_ageable": {{}}, "animals": {{}},
        "monsters": [], "stew_flowers": {{}}, "variants": {{}}, "sound_variants": {{}}, "sounds": {{}}
      }},
      "village": {{
        "poi_types": {{}}, "professions": [], "villager_types": [], "villager_type_by_biome": {{}},
        "schedules": {{"minecraft:overworld": {{"adult": [], "baby": []}}}}, "sounds": {{}}
      }}
    }}"#,
        fire = ids(&["on_fire", "in_fire", "lava", "hot_floor", "campfire"]),
        bypass = ids(&[
            "on_fire",
            "drown",
            "magic",
            "indirect_magic",
            "wither",
            "generic_kill",
            "freeze"
        ]),
        fall = ids(&["fall"]),
        freeze = ids(&["freeze"]),
        anvil = ids(&["falling_anvil"]),
        no_knockback = ids(&["drown", "on_fire"]),
        kill = ids(&["generic_kill"]),
        zombie = entity("zombie", 0, false, 20.0, 2.0),
        cow = entity("cow", 1, false, 10.0, 0.0),
        blaze = entity("blaze", 2, true, 20.0, 6.0),
    );
    MobFacts::parse(&json(&text)).unwrap()
}

fn living_facts(mob: &MobFacts) -> LivingFacts {
    let text = r##"{
      "enchantments": {
        "minecraft:protection": {"slots": ["armor"], "effects": {"minecraft:damage_protection": [
          {"effect": {"type": "minecraft:add", "value": {"type": "minecraft:linear", "base": 1.0,
            "per_level_above_first": 1.0}}}]}},
        "minecraft:knockback": {"slots": ["mainhand"], "effects": {"minecraft:knockback": [
          {"effect": {"type": "minecraft:add", "value": {"type": "minecraft:linear", "base": 1.0,
            "per_level_above_first": 1.0}}}]}},
        "minecraft:unbreaking": {"slots": ["any"], "effects": {"minecraft:item_damage": [
          {"effect": {"type": "minecraft:remove_binomial", "chance": {"type": "minecraft:fraction",
            "numerator": {"type": "minecraft:linear", "base": 2.0, "per_level_above_first": 2.0},
            "denominator": {"type": "minecraft:linear", "base": 10.0, "per_level_above_first": 5.0}}},
           "requirements": {"type": "minecraft:match_tool", "predicate": {"items": "#minecraft:enchantable/armor"}}}]}}
      },
      "items": {
        "minecraft:iron_sword": {"id": 1, "max_damage": 250},
        "minecraft:iron_chestplate": {"id": 2, "max_damage": 240},
        "minecraft:iron_helmet": {"id": 3, "max_damage": 165}
      },
      "damage_defaults": [1, 2, 3],
      "combat_items": {
        "minecraft:iron_sword": {"minecraft:attribute_modifiers": [
          {"type": "minecraft:attack_damage", "id": "minecraft:base_attack_damage", "amount": 5.0,
           "operation": "add_value", "slot": "mainhand"}]},
        "minecraft:iron_chestplate": {"minecraft:attribute_modifiers": [
          {"type": "minecraft:armor", "id": "minecraft:armor.chestplate", "amount": 6.0,
           "operation": "add_value", "slot": "chest"}]}
      },
      "landing": {"state_count": 3, "states": "000001",
        "palette": [[{"distance_scale": 1.0, "distance_offset": 0.0, "multiplier": 1.0, "source": "fall"},
                     {"distance_scale": 1.0, "distance_offset": 0.0, "multiplier": 1.0, "source": "fall"}],
                    [null, null]]},
      "water_breathers": ["minecraft:zombie"]
    }"##;
    LivingFacts::parse(&json(text), mob).unwrap()
}

struct Fixture {
    mob: MobFacts,
    living: LivingFacts,
}

impl Fixture {
    fn new() -> Fixture {
        let mob = mob_facts();
        let living = living_facts(&mob);
        Fixture { mob, living }
    }

    fn rules(&self) -> Rules<'_> {
        Rules {
            facts: &self.mob,
            living: &self.living,
            families: &NoFamilies,
            mind: &NoMind,
        }
    }

    fn ty(&self, name: &str) -> Type<'_> {
        Type::of(&self.mob, name).unwrap()
    }

    fn mob(&self, name: &str) -> NativeMob {
        let rules = self.rules();
        NativeMob {
            uuid: [7; 16],
            position: [0.5, 64.0, 0.5],
            hops: 0,
            body: body::fresh(&rules, self.ty(name)),
        }
    }

    fn damage(&self, name: &str) -> u16 {
        self.mob.damage_types.id(name).unwrap()
    }
}

fn stack(id: i64) -> Value {
    Value::Map(Map::from_atoms([
        (
            "__struct__",
            Value::atom("Elixir.Valimc.Protocol.ItemStack"),
        ),
        ("item_id", Value::Int(id)),
        ("count", Value::Int(1)),
        ("components", Value::Map(Map::new())),
    ]))
}

fn player() -> Attacker {
    Attacker {
        uuid: [2; 16],
        entity_id: 9,
        player: true,
        entity_type: "minecraft:player".into(),
        mainhand: None,
    }
}

fn rung(ticks: i32, amplifier: u8) -> Rung {
    Rung {
        ticks,
        amplifier,
        ambient: false,
        particles: true,
        icon: true,
    }
}

#[test]
fn hurt_window_selects_full_partial_and_refused_hits() {
    let h = Health {
        value: 20.0,
        maximum: 20.0,
        hurt_ticks: 0,
        death_ticks: 0,
        cooldown: 0,
        last_hurt: 0.0,
    };
    let (h, full) = health::hurt_window(&h, 5.0, false);
    assert!(full.accepted && full.notify && full.damage == 5.0);
    assert_eq!((h.cooldown, h.hurt_ticks), (20, 10));
    // Within the cooldown only the excess over the last hurt lands.
    let (h, partial) = health::hurt_window(&h, 7.0, false);
    assert!(partial.accepted && !partial.notify && partial.damage == 2.0);
    let (_, refused) = health::hurt_window(&h, 6.0, false);
    assert!(!refused.accepted);
    let (_, bypass) = health::hurt_window(&h, 1.0, true);
    assert!(bypass.notify);
    assert_eq!(health::spend_absorption(4.0, 6.0), (0.0, 2.0));
    assert_eq!(health::spend_absorption(4.0, 1.5), (2.5, 0.0));
    let mut dead = Health { value: 0.0, ..h };
    health::heal(&mut dead, 4.0);
    assert_eq!(dead.value, 0.0);
    let mut over = h;
    health::set(&mut over, 99.0);
    assert_eq!(over.value, 20.0);
}

#[test]
fn effects_merge_tick_and_request() {
    // A stronger, shorter dose keeps the weaker one suppressed under it.
    let (merged, notify) = effects::merge(&[rung(100, 0)], rung(40, 1));
    assert!(notify);
    assert_eq!(
        merged
            .iter()
            .map(|r| (r.ticks, r.amplifier))
            .collect::<Vec<_>>(),
        [(40, 1), (100, 0)]
    );
    // A weaker, longer dose waits beneath.
    let (merged, notify) = effects::merge(&[rung(40, 1)], rung(100, 0));
    assert!(!notify);
    assert_eq!(merged.len(), 2);
    // Ticking runs it down and promotes the suppressed rung.
    let mut instance = merged;
    for _ in 0..39 {
        assert_eq!(effects::tick_instance(&mut instance), (true, false));
    }
    assert_eq!(effects::tick_instance(&mut instance), (true, true));
    assert_eq!((instance[0].ticks, instance[0].amplifier), (60, 0));

    let f = Fixture::new();
    let e = &f.living.effects;
    assert_eq!(
        effects::instant(&f.living, e.instant_health, 0),
        effects::Action::Heal(4.0)
    );
    assert_eq!(
        effects::instant(&f.living, e.instant_damage, 1),
        effects::Action::Hurt(f.damage("indirect_magic"), 12.0)
    );
    // Shifts mask the distance as the JVM does.
    assert_eq!(
        effects::instant(&f.living, e.instant_health, 33),
        effects::Action::Heal(8.0)
    );
    let h = Health {
        value: 10.0,
        maximum: 20.0,
        hurt_ticks: 0,
        death_ticks: 0,
        cooldown: 0,
        last_hurt: 0.0,
    };
    let regen = |ticks| effects::periodic(&f.living, e.regeneration, &[rung(ticks, 0)], 0, &h);
    assert_eq!(regen(100), effects::Action::Heal(1.0));
    assert_eq!(regen(99), effects::Action::None);
    let poison = effects::periodic(&f.living, e.poison, &[rung(48, 1)], 0, &h);
    assert_eq!(poison, effects::Action::Hurt(f.damage("magic"), 1.0));
    // An infinite one runs on the mob's age.
    let wither = |age| effects::periodic(&f.living, e.wither, &[rung(-1, 0)], age, &h);
    assert_eq!(wither(80), effects::Action::Hurt(f.damage("wither"), 1.0));
    assert_eq!(wither(81), effects::Action::None);

    let mut set = Effects::default();
    effects::add(&mut set, e.speed, rung(2, 0));
    effects::add(&mut set, e.poison, rung(-1, 0));
    effects::tick(&mut set);
    effects::tick(&mut set);
    assert_eq!(set.0.len(), 1);
}

#[test]
fn armour_resistance_and_protection() {
    assert_eq!(
        damage::armor_absorb(10.0, 2.0, 0.0),
        f(10.0 * f(1.0 - f(f(0.4) / 25.0)))
    );
    assert_eq!(
        damage::armor_absorb(4.0, 20.0, 8.0),
        f(4.0 * f(1.0 - f(f(20.0 - 1.0) / 25.0)))
    );
    let fx = Fixture::new();
    let mut effects = Effects::default();
    effects::add(&mut effects, fx.living.effects.resistance, rung(100, 0));
    let player = fx.damage("player_attack");
    assert_eq!(damage::resistance(&fx.living, 10.0, player, &effects), 8.0);
    effects::add(&mut effects, fx.living.effects.resistance, rung(100, 4));
    assert_eq!(damage::resistance(&fx.living, 10.0, player, &effects), 0.0);
    let mut equipment = super::super::model::Equipment::default();
    let mut chest = stack(2);
    items::put_component(
        &mut chest,
        "minecraft:enchantments",
        Value::Map(
            Map::from_pairs(vec![(
                Value::Binary(b"minecraft:protection".to_vec()),
                Value::Int(4),
            )])
            .unwrap(),
        ),
    );
    equipment.set(Slot::Chest, Some(chest));
    assert_eq!(
        enchantments::protection(&fx.living, &fx.mob, &equipment, player),
        4.0
    );
    let protected = damage::protect(
        &fx.living,
        &fx.mob,
        &equipment,
        player,
        10.0,
        &Effects::default(),
        (0.0, 0.0),
    );
    assert_eq!(protected, f(10.0 * f(1.0 - f(4.0 / 25.0))));
}

#[test]
fn burning_counts_down_ignites_and_plans_contacts() {
    assert_eq!(burning::tick(40, false, false), (39, 1.0));
    assert_eq!(burning::tick(39, false, false), (38, 0.0));
    assert_eq!(burning::tick(40, false, true), (39, 0.0));
    assert_eq!(burning::tick(40, true, false), (0, 0.0));
    assert_eq!(burning::tick(-3, false, false), (-3, 0.0));
    assert_eq!(burning::entity_fire(0, false, 1.0), 160);
    assert_eq!(burning::entity_fire(-5, false, 1.0), -4);
    assert_eq!(burning::entity_fire(200, false, 1.0), 200);
    assert_eq!(burning::entity_fire(0, false, 0.5), 80);
    assert_eq!(burning::lava(0, false, 1.0), 300);
    assert_eq!(burning::settle(0, 30, false), 0);
    assert_eq!(burning::settle(30, 0, true), 30);
    let plan = burning::plan(&[vec![Contact::SoulFire, Contact::Lava, Contact::Water]]);
    assert_eq!(
        plan,
        [
            Operation::ClearFreeze,
            Operation::FireIgnite,
            Operation::InFire(2.0),
            Operation::LavaIgnite,
            Operation::LavaHurt,
            Operation::Extinguish
        ]
    );
}

#[test]
fn air_falls_knockback_difficulty_and_explosions() {
    assert_eq!(
        air::tick(0, true, 0.0, air::Policy::None, || 0.0),
        (-1, 0.0)
    );
    assert_eq!(
        air::tick(-19, true, 0.0, air::Policy::None, || 0.0),
        (0, 2.0)
    );
    assert_eq!(air::tick(5, true, 0.0, air::Policy::Hold, || 0.0), (5, 0.0));
    assert_eq!(
        air::tick(298, false, 0.0, air::Policy::None, || 0.0),
        (300, 0.0)
    );
    // Respiration keeps the air on a draw past 1 / (bonus + 1), drawn only then.
    assert_eq!(
        air::tick(10, true, 1.0, air::Policy::None, || 0.75),
        (10, 0.0)
    );
    assert_eq!(
        air::tick(10, true, 0.0, air::Policy::None, || panic!("no draw")),
        (9, 0.0)
    );

    assert_eq!(fall::calculate(3.0, 1.0, 3.0, 1.0), 0);
    assert_eq!(fall::calculate(10.0, 1.0, 3.0, 1.0), 7);
    assert_eq!(fall::calculate(10.0, 0.2, 3.0, 1.0), 1);
    assert_eq!(fall::calculate(2.0, 1.0, 3.0, 1.0), -1);

    let v = melee::knockback([0.2, -0.0784, 0.0], true, 0.4, [1.0, 0.0], 0.0);
    assert_eq!(v, [0.1 - 0.4, 0.4f64.min(-0.0392 + 0.4), 0.0]);
    assert_eq!(
        melee::knockback([0.2, 0.0, 0.0], true, 0.4, [1.0, 0.0], 1.0),
        [0.2, 0.0, 0.0]
    );
    let [x, z] = melee::facing(90.0);
    assert!((x - 1.0).abs() < 1e-6 && z.abs() < 1e-3);

    use super::super::level::Difficulty;
    let d = difficulty::LocalDifficulty::at(Difficulty::Hard, 3_600_000, 3_600_000);
    assert!(d.effective > 4.0 && d.special() == 1.0);
    assert_eq!(
        difficulty::LocalDifficulty::at(Difficulty::Peaceful, 0, 0).effective,
        0.0
    );
    assert_eq!(
        difficulty::LocalDifficulty::at(Difficulty::Normal, 0, 0).effective,
        1.5
    );

    assert_eq!(explosions::distance(4.0, [0.0; 3], [9.0, 0.0, 0.0]), None);
    assert_eq!(explosions::damage(4.0, [0.0; 3], [0.0; 3], 1.0), 57.0);
    assert_eq!(
        explosions::knockback([0.0; 3], [2.0, 0.0, 0.0], 0.5, 1.0, 0.0),
        [0.5, 0.0, 0.0]
    );
}

#[test]
fn hurt_knocks_back_sounds_and_respects_the_cooldown() {
    let fx = Fixture::new();
    let rules = fx.rules();
    let mut zombie = fx.mob("minecraft:zombie");
    zombie.body.on_ground = true;
    let mut hit = Hit::new(fx.damage("player_attack"), 5.0);
    hit.attacker = Some(player());
    hit.direct = Some(player());
    hit.position = Some([2.5, 64.0, 0.5]);
    let (events, r) = combat::resolve(&rules, &mut zombie, &hit);
    assert!(r.hurt && r.full && !r.died);
    // Armour 2 takes a little off: 5 * (1 - 0.4 / 25).
    assert_eq!(r.health, f(20.0 - f(5.0 * f(1.0 - f(f(0.4) / 25.0)))));
    assert_eq!(events.len(), 2);
    assert!(matches!(
        events[0],
        Event::Damage {
            cause: Some(9),
            direct: Some(9),
            ..
        }
    ));
    let mut expected = LegacyRandom::from_uuid(&[7; 16]);
    let pitch = expected.voice_pitch(1.0) as f64;
    assert_eq!(
        events[1],
        Event::Sound {
            sound: SoundRef::Name("minecraft:entity.zombie.hurt".into()),
            source: 5,
            volume: 1.0,
            pitch
        }
    );
    // Knocked away from the attacker (along -x), lifted off the ground.
    assert!(zombie.body.velocity[0] < 0.0 && zombie.body.velocity[1] > 0.0);
    assert_eq!(zombie.body.mob.hurt_by_player, Some([2; 16]));
    assert_eq!(zombie.body.mob.player_memory, 100);
    // Within the cooldown a weaker hit is refused.
    let (_, again) = combat::resolve(&rules, &mut zombie, &Hit::new(hit.source, 4.0));
    assert!(!again.hurt);
    // A fire-immune blaze ignores fire.
    let mut blaze = fx.mob("minecraft:blaze");
    let (_, fire) = combat::resolve(&rules, &mut blaze, &Hit::new(fx.damage("in_fire"), 5.0));
    assert!(!fire.hurt);
}

#[test]
fn deaths_drop_equipment_and_experience_from_the_mobs_random() {
    let fx = Fixture::new();
    let rules = fx.rules();
    let mut zombie = fx.mob("minecraft:zombie");
    zombie
        .body
        .mob
        .equipment
        .set(Slot::Mainhand, Some(stack(1)));
    zombie.body.mob.drop_chances.0[Slot::Mainhand as usize] = Some(2.0);
    let mut hit = Hit::new(fx.damage("player_attack"), 100.0);
    hit.attacker = Some(player());
    let (events, r) = combat::resolve(&rules, &mut zombie, &hit);
    assert!(r.died);
    assert_eq!(events.last(), Some(&Event::Entity(3)));
    let death = zombie.body.mob.death.as_ref().unwrap().as_map().unwrap();
    // The preserved sword drops unworn; it then no longer counts.
    assert_eq!(
        death.get_atom("equipment"),
        Some(&Value::List(vec![stack(1)]))
    );
    assert_eq!(death.get_atom("experience"), Some(&Value::Int(5)));
    assert_eq!(zombie.body.mob.equipment.get(Slot::Mainhand), None);

    // A helmet it would not keep unworn adds one to three.
    let mut helmeted = fx.mob("minecraft:zombie");
    helmeted.body.mob.equipment.set(Slot::Head, Some(stack(3)));
    let (_, _) = combat::resolve(&rules, &mut helmeted, &hit);
    let xp = helmeted
        .body
        .mob
        .death
        .as_ref()
        .unwrap()
        .as_map()
        .unwrap()
        .get_atom("experience")
        .cloned();
    let xp = xp.and_then(|v| v.as_int()).unwrap();
    assert!((6..=8).contains(&xp), "{xp}");

    // `/kill` dies without a hit: no source, the kill events.
    let mut cow = fx.mob("minecraft:cow");
    let mut events = Vec::new();
    assert!(body::kill(&rules, &mut cow, &mut events));
    assert_eq!(events, [Event::Killed, Event::Entity(3)]);
    assert!(!body::kill(&rules, &mut cow, &mut events));
    let mut done = false;
    let mut poof = 0;
    for _ in 0..20 {
        let mut e = Vec::new();
        done = body::tick(&mut cow.body, &mut e);
        poof += e.len();
    }
    assert!(done && poof == 1);
}

#[test]
fn vitals_burn_fall_drown_and_extinguish() {
    let fx = Fixture::new();
    let rules = fx.rules();
    let mut zombie = fx.mob("minecraft:zombie");
    zombie.body.mob.living.fire_ticks = 21;
    assert!(vitals::base_tick(&rules, &mut zombie).is_empty());
    // At 20 a second's damage (on_fire bypasses armour, no knockback).
    let events = vitals::base_tick(&rules, &mut zombie);
    assert_eq!(zombie.body.mob.living.health.value, 19.0);
    assert!(matches!(events[0], Event::Damage { .. }));

    let none = Touched::default();
    let moved = |landing| Moved {
        eye_water: false,
        eye_state: 0,
        landing,
        touched: &none,
        water: false,
        rain: false,
    };
    let mut cow = fx.mob("minecraft:cow");
    vitals::apply(&rules, &mut cow, &moved(Some((1, 7.5))));
    assert_eq!(cow.body.mob.living.health.value, 6.0);
    // Air on its landing palette's empty entry deals nothing.
    let mut cow = fx.mob("minecraft:cow");
    vitals::apply(&rules, &mut cow, &moved(Some((2, 30.0))));
    assert_eq!(cow.body.mob.living.health.value, 10.0);
    // A blaze is immune to falls.
    let mut blaze = fx.mob("minecraft:blaze");
    vitals::apply(&rules, &mut blaze, &moved(Some((1, 30.0))));
    assert_eq!(blaze.body.mob.living.health.value, 20.0);

    // Under water a cow drowns after its air; a zombie breathes.
    let under = Moved {
        eye_water: true,
        eye_state: 1,
        landing: None,
        touched: &none,
        water: true,
        rain: false,
    };
    let mut cow = fx.mob("minecraft:cow");
    let mut zombie = fx.mob("minecraft:zombie");
    for _ in 0..320 {
        vitals::apply(&rules, &mut cow, &under);
        vitals::apply(&rules, &mut zombie, &under);
    }
    assert_eq!(cow.body.mob.living.health.value, 8.0);
    assert_eq!(cow.body.mob.living.air_supply, 0);
    assert_eq!(zombie.body.mob.living.air_supply, 300);
    // A blaze in water takes a drowning hurt.
    let mut blaze = fx.mob("minecraft:blaze");
    vitals::apply(
        &rules,
        &mut blaze,
        &Moved {
            eye_water: false,
            ..under
        },
    );
    assert_eq!(blaze.body.mob.living.health.value, 19.0);
    // And so does one in rain (`isInWaterOrRain`); a zombie in rain does not.
    let rained = Moved {
        rain: true,
        ..moved(None)
    };
    let mut blaze = fx.mob("minecraft:blaze");
    vitals::apply(&rules, &mut blaze, &rained);
    assert_eq!(blaze.body.mob.living.health.value, 19.0);
    let mut zombie = fx.mob("minecraft:zombie");
    vitals::apply(&rules, &mut zombie, &rained);
    assert_eq!(zombie.body.mob.living.health.value, 20.0);

    // Water puts a burning cow out with the hiss.
    let water = Touched {
        immediate: Vec::new(),
        steps: vec![vec![Contact::Water]],
        active: true,
    };
    let mut cow = fx.mob("minecraft:cow");
    cow.body.mob.living.fire_ticks = 40;
    let events = vitals::apply(
        &rules,
        &mut cow,
        &Moved {
            touched: &water,
            ..moved(None)
        },
    );
    assert_eq!(cow.body.mob.living.fire_ticks, 0);
    assert!(matches!(
        events[0],
        Event::Sound {
            sound: SoundRef::Id(3),
            source: 6,
            ..
        }
    ));
}

struct Sunny {
    light: f64,
    rain: bool,
    random: LegacyRandom,
}

impl Sky for Sunny {
    fn monsters_burn(&self) -> bool {
        true
    }
    fn light(&self, _p: [i32; 3]) -> f64 {
        self.light
    }
    fn sees_sky(&self, _p: [i32; 3]) -> bool {
        true
    }
    fn rain(&self, _position: [f64; 3], _top: f64) -> bool {
        self.rain
    }
    fn random(&mut self) -> &mut LegacyRandom {
        &mut self.random
    }
}

#[test]
fn daylight_burns_undead_wears_helmets_and_rain_puts_out() {
    let fx = Fixture::new();
    let rules = fx.rules();
    let mut sky = Sunny {
        light: 1.0,
        rain: false,
        random: LegacyRandom::new(1),
    };
    let mut zombie = fx.mob("minecraft:zombie");
    for _ in 0..20 {
        vitals::daylight(&rules, &mut zombie, [0.5, 64.0, 0.5], &mut sky);
    }
    assert_eq!(zombie.body.mob.living.fire_ticks, 160);
    // Cows do not burn.
    let mut cow = fx.mob("minecraft:cow");
    vitals::daylight(&rules, &mut cow, [0.5, 64.0, 0.5], &mut sky);
    assert_eq!(cow.body.mob.living.fire_ticks, 0);
    // A helmet takes the wear instead.
    let mut helmeted = fx.mob("minecraft:zombie");
    helmeted.body.mob.equipment.set(Slot::Head, Some(stack(3)));
    for _ in 0..40 {
        vitals::daylight(&rules, &mut helmeted, [0.5, 64.0, 0.5], &mut sky);
    }
    assert_eq!(helmeted.body.mob.living.fire_ticks, 0);
    let worn = items::component(
        helmeted.body.mob.equipment.get(Slot::Head).unwrap(),
        "minecraft:damage",
    );
    assert!(worn.and_then(Value::as_int).unwrap() > 0);
    // Rain puts a burning mob out and keeps the sun off.
    sky.rain = true;
    vitals::daylight(&rules, &mut zombie, [0.5, 64.0, 0.5], &mut sky);
    assert_eq!(zombie.body.mob.living.fire_ticks, 0);
}

#[test]
fn attributes_values_and_mob_hits() {
    let fx = Fixture::new();
    let rules = fx.rules();
    let ty = fx.ty("minecraft:zombie");
    let mut zombie = fx.mob("minecraft:zombie");
    let a = fx.living.attributes;
    assert_eq!(
        mob::value(&fx.living, &fx.mob, ty, &zombie.body.mob, a.armor),
        2.0
    );
    zombie.body.mob.equipment.set(Slot::Chest, Some(stack(2)));
    zombie
        .body
        .mob
        .equipment
        .set(Slot::Mainhand, Some(stack(1)));
    assert_eq!(
        mob::value(&fx.living, &fx.mob, ty, &zombie.body.mob, a.armor),
        8.0
    );
    // The sword's modifier acts in the main hand only.
    assert_eq!(
        mob::value(&fx.living, &fx.mob, ty, &zombie.body.mob, a.attack_damage),
        8.0
    );
    let speed = fx.living.effects.speed;
    mob::add_effect(&fx.mob, &mut zombie.body.mob, speed, rung(100, 0));
    let movement = fx.mob.attributes.id("movement_speed").unwrap();
    let value = mob::value(&fx.living, &fx.mob, ty, &zombie.body.mob, movement);
    assert_eq!(value, 0.7 * (1.0 + f64::from_bits(0x3fc99999a0000000)));
    let hit = combat::mob_hit(&rules, &zombie, 5, fx.ty("minecraft:cow").id).unwrap();
    assert_eq!(hit.amount, 8.0);
    assert_eq!(hit.source, fx.damage("mob_attack"));
    assert_eq!(hit.attacker.as_ref().unwrap().entity_id, 5);
    assert_eq!(hit.extra_knockback.unwrap().0, 0.0);
    let synced = mob::synced(&fx.living, &fx.mob, ty, &zombie.body.mob.attributes);
    assert!(synced.windows(2).all(|w| w[0].id < w[1].id));
    let values = body::values(&rules, ty, &zombie.body);
    assert_eq!(values.len(), 10);
    assert_eq!(values[7].1, Value::Float(20.0));
}

#[test]
fn the_ai_mind_hears_hurts_and_resets_its_ambient_timer() {
    use super::super::ai::MindState;
    use super::super::combat::AiMind;
    let fx = Fixture::new();
    let rules = Rules {
        mind: &AiMind,
        ..fx.rules()
    };
    let mut zombie = fx.mob("minecraft:zombie");
    let state = MindState {
        tick: 41,
        no_action: 300,
        ..MindState::default()
    };
    zombie.body.mob.ai = Some(super::super::model::Mind {
        random: LegacyRandom::new(5),
        memories: None,
        state: Some(Box::new(state)),
    });
    let mut hit = Hit::new(fx.damage("player_attack"), 3.0);
    hit.attacker = Some(player());
    hit.position = Some([1.0, 64.0, 0.5]);
    let (_, r) = combat::resolve(&rules, &mut zombie, &hit);
    assert!(r.full);
    let s = zombie.body.mob.ai.as_ref().unwrap().state.as_ref().unwrap();
    assert_eq!(s.no_action, 0);
    assert_eq!(s.ambient, -80);
    let damage = s.damage.unwrap();
    assert_eq!(
        (damage.source, damage.tick),
        (fx.damage("player_attack"), 42)
    );
    assert_eq!(s.hurt_by.map(|(r, t)| (r.uuid, t)), Some(([2; 16], 41)));
}
