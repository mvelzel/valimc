//! Zombies, husks and zombie villagers (`Valimc.AI.Mobs.Zombie`, vanilla's
//! `Zombie`, `Husk` and `ZombieVillager`):
//!
//! - **Goals** are the zombie's (`Zombie.registerGoals`); a hurt one alerts
//!   others of its own class (a zombie alerts husks, drowned and zombie
//!   villagers too).
//! - **Spawning** (`finalizeSpawn`): loot pickup, a baby one time in twenty
//!   (a chicken jockey's draws), door breaking, armour and a sword, spear or
//!   shovel, their enchantments, a Halloween head, then its own random's
//!   reinforcement chance, knockback and follow range bonuses and, now and
//!   then, a leader. A husk draws its loot pickup again and may bring a
//!   camel husk ridden by a parched; a zombie villager takes its villager
//!   type from the biome and its profession from its random.
//! - **Hits**: a burning bare-handed zombie may set its target alight, a
//!   bare-handed husk makes it hungry.
//! - **Drowning** (after the move): a zombie with its eyes in water for 30 s
//!   starts turning into a drowned 15 s later, a husk into a zombie.
//!
//! `Parts` is what drowned share (`Valimc.AI.Mobs.Drowned` keeps a zombie's
//! data, babies, hits and attributes).

use super::{entity, fields, flag, int, item, states, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{f, floor};
use crate::mobs::ai::goal::{JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    HurtByTarget, Idle, LookAtPlayer, MeleeAttack, MobTypes, NearestAttackableTarget,
    RandomLookAround, RandomStroll, RemoveBlock, TargetKind,
};
use crate::mobs::ai::hooks::{attribute, Hooks};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Kinds, Seen, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::level::Difficulty;
use crate::mobs::model::{Body, FamilyData, Mob, NativeMob, Number, Slot};
use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::inflate;
use crate::mobs::term::{Atom, Map, Value, NIL};
use crate::physics::mob::Ticked;
use crate::physics::Aabb;

pub const ZOMBIE: &str = "minecraft:zombie";
pub const HUSK: &str = "minecraft:husk";
pub const VILLAGER: &str = "minecraft:zombie_villager";
pub const DROWNED: &str = "minecraft:drowned";

const SPAWN_REINFORCEMENTS: &str = "minecraft:spawn_reinforcements";
const MOVEMENT_SPEED: &str = "minecraft:movement_speed";

/// What a zombie and a drowned share: the ids the zombie's rules read.
pub struct Parts {
    pub zombie: u16,
    pub husk: u16,
    pub villager: u16,
    pub drowned: u16,
    pub villagers: Vec<u16>,
    pub iron_golem: u16,
    pub turtle: u16,
    pub chicken: u16,
    pub camel_husk: u16,
    pub parched: u16,
    pub turtle_eggs: Vec<u16>,
    pub glow_ink: i32,
    pub hunger: i32,
    pub iron_sword: i32,
    pub iron_spear: i32,
    pub iron_shovel: i32,
    /// The states of a bubble column (`Air.submerged?`).
    pub bubble_column: (u16, u16),
    /// Each type's baby dimensions (`HostileFacts.baby/1`).
    pub babies: Vec<(String, [f32; 3])>,
}

impl Parts {
    pub fn new(facts: &MobFacts) -> Result<Parts, String> {
        let bubbles = states(facts, "minecraft:bubble_column")?;
        let babies = [ZOMBIE, HUSK, VILLAGER, DROWNED]
            .into_iter()
            .filter_map(|name| {
                let id = facts.entities.id(name)?;
                Some((name.to_owned(), *facts.hostile.babies.get(&id)?))
            })
            .collect();
        Ok(Parts {
            babies,
            zombie: entity(facts, ZOMBIE)?,
            husk: entity(facts, HUSK)?,
            villager: entity(facts, VILLAGER)?,
            drowned: entity(facts, DROWNED)?,
            villagers: vec![
                entity(facts, "minecraft:villager")?,
                entity(facts, "minecraft:wandering_trader")?,
            ],
            iron_golem: entity(facts, "minecraft:iron_golem")?,
            turtle: entity(facts, "minecraft:turtle")?,
            chicken: entity(facts, "minecraft:chicken")?,
            camel_husk: entity(facts, "minecraft:camel_husk")?,
            parched: entity(facts, "minecraft:parched")?,
            turtle_eggs: states(facts, "minecraft:turtle_egg")?,
            glow_ink: item(facts, "minecraft:glow_ink_sac")?,
            hunger: super::effect(facts, "minecraft:hunger")?,
            iron_sword: item(facts, "minecraft:iron_sword")?,
            iron_spear: item(facts, "minecraft:iron_spear")?,
            iron_shovel: item(facts, "minecraft:iron_shovel")?,
            bubble_column: (
                *bubbles.first().ok_or("no bubble column")?,
                *bubbles.last().ok_or("no bubble column")?,
            ),
        })
    }

    /// The types a hurt one of `type_id` alerts (`setAlertOthers`: its own
    /// class and its subclasses but zombified piglins).
    fn alerted(&self, type_id: u16) -> Vec<u16> {
        if type_id == self.zombie {
            vec![self.zombie, self.husk, self.drowned, self.villager]
        } else {
            vec![type_id]
        }
    }

    /// `ZombieAttackTurtleEggGoal`, `LookAtPlayerGoal` and
    /// `RandomLookAroundGoal`, the start of a zombie's and a drowned's goals.
    pub fn common_goals(&self) -> Vec<Registration> {
        vec![
            Registration::new(
                4,
                "ZombieAttackTurtleEggGoal",
                MOVE | JUMP,
                RemoveBlock::new(self.turtle_eggs.clone()),
            ),
            Registration::new(
                8,
                "LookAtPlayerGoal",
                LOOK,
                LookAtPlayer::new(8.0, 0.02, false, None),
            ),
            Registration::new(
                8,
                "RandomLookAroundGoal",
                MOVE | LOOK,
                RandomLookAround::new(),
            ),
        ]
    }

    /// `Turtle.BABY_ON_LAND_SELECTOR`'s target goal (turtles are not
    /// modelled yet: any turtle).
    pub fn turtle_target(&self) -> Registration {
        Registration::new(
            5,
            "NearestAttackableTargetGoal",
            TARGET,
            NearestAttackableTarget::new(
                TargetKind::Mob,
                Some(MobTypes::Types(vec![self.turtle])),
                true,
                TargetOptions::default(),
            ),
        )
    }

    // ## Data

    /// `data/1`: the baby flag, the special type, door breaking, its time
    /// with its eyes in water and its drowned conversion countdown (-1 when
    /// not converting); a zombie villager's villager data.
    pub fn data(&self, type_id: u16) -> Vec<(Atom, Value)> {
        let mut data = fields(&[
            ("baby", Value::bool(false)),
            ("special", Value::Int(0)),
            ("can_break_doors", Value::bool(false)),
            ("in_water", Value::Int(0)),
            ("converting", Value::bool(false)),
            ("conversion", Value::Int(-1)),
        ]);
        if type_id == self.villager {
            data.extend(fields(&[
                (
                    "villager",
                    Value::tuple([
                        Value::Binary(b"minecraft:plains".to_vec()),
                        Value::Binary(b"minecraft:none".to_vec()),
                        Value::Int(1),
                    ]),
                ),
                ("finalized", Value::bool(false)),
                ("cure", Value::Int(-1)),
                ("cure_by", NIL),
                ("xp", Value::Int(0)),
            ]));
        }
        data
    }

    /// `values/1`.
    pub fn values(&self, type_id: u16, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        let mut out = vec![
            value(
                "zombie_baby",
                Value::bool(flag(data, "baby")),
                Value::bool(false),
            ),
            value(
                "zombie_special_type",
                data.get("special").cloned().unwrap_or(Value::Int(0)),
                Value::Int(0),
            ),
            value(
                "zombie_drowned_conversion",
                Value::bool(flag(data, "converting")),
                Value::bool(false),
            ),
        ];
        if type_id == self.villager {
            out.push(value(
                "zombie_villager_converting",
                Value::bool(int(data, "cure") >= 0),
                Value::bool(false),
            ));
            out.push(value(
                "zombie_villager_data",
                data.get("villager").cloned().unwrap_or(NIL),
                NIL,
            ));
            out.push(value(
                "zombie_villager_finalized",
                Value::bool(flag(data, "finalized")),
                Value::bool(false),
            ));
        }
        out
    }

    /// `dimensions/1`: a baby's.
    pub fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        if !flag(&body.data, "baby") {
            return None;
        }
        self.babies
            .iter()
            .find(|(name, _)| *name == body.entity_type)
            .map(|(_, d)| *d)
    }

    /// `voice/2`: a baby's higher voice (a baby zombie villager's higher
    /// still).
    pub fn voice(&self, type_id: u16, data: &FamilyData) -> f32 {
        match (flag(data, "baby"), type_id == self.villager) {
            (true, true) => 2.0,
            (true, false) => 1.5,
            _ => 1.0,
        }
    }

    // ## Hits

    /// `Zombie.doHurtTarget` after the hit: a burning bare-handed zombie
    /// sets the target alight for twice the local difficulty's seconds by a
    /// chance that grows with it; a bare-handed husk then makes it hungry.
    pub fn hit(&self, t: &mut Turn, target: &Seen) {
        let difficulty = spawn::local(t).effective;
        let bare = t.mob.body.mob.equipment.get(Slot::Mainhand).is_none();
        let mut extras = Vec::new();
        if bare && t.mob.body.mob.living.fire_ticks > 0 {
            let roll = t.float();
            if roll < f(difficulty * f(0.3)) {
                extras.push((
                    Value::atom("ignite"),
                    Value::Int(2 * (difficulty.trunc() as i64) * 20),
                ));
            }
        }
        if t.type_id == self.husk && bare {
            let rung = Value::tuple([
                Value::Int(140 * difficulty.trunc() as i64),
                Value::Int(0),
                Value::bool(false),
                Value::bool(true),
                Value::bool(true),
            ]);
            extras.push((
                Value::atom("effect"),
                Value::tuple([Value::Int(self.hunger as i64), rung]),
            ));
        }
        if let Some(map) = (!extras.is_empty())
            .then(|| Map::from_pairs(extras))
            .flatten()
        {
            t.effect(Effect::AttackExtra(target.reference, Value::Map(map)));
        }
    }

    // ## Drowning

    /// `Zombie.tick`'s drowning tracker after the move (`ConversionTracker`):
    /// with its eyes in water for 600 ticks it starts converting, 300 ticks
    /// later it becomes `to` with the conversion's level event; out of water
    /// it starts over.
    pub fn drown(&self, mob: &mut NativeMob, ticked: &Ticked, to: u16, event: i32) -> Vec<Effect> {
        let m = &mob.body.mob;
        if !crate::mobs::living::mob::alive(m) || m.no_ai {
            return Vec::new();
        }
        let (first, last) = self.bubble_column;
        let submerged = ticked.eye_water && !(first..=last).contains(&ticked.eye_state);
        let data = &mut mob.body.data;
        if !submerged {
            data.set("in_water", Value::Int(-1));
            data.set("converting", Value::bool(false));
            return Vec::new();
        }
        if flag(data, "converting") {
            let conversion = int(data, "conversion") - 1;
            data.set("conversion", Value::Int(conversion));
            if conversion < 0 {
                let [x, y, z] = mob.position;
                let cell = [floor(x), floor(y), floor(z)];
                return vec![
                    Effect::Convert(to),
                    Effect::LevelEvent {
                        cell,
                        kind: event,
                        data: 0,
                    },
                ];
            }
        } else {
            let in_water = int(data, "in_water") + 1;
            data.set("in_water", Value::Int(in_water));
            if in_water >= 600 {
                data.set("converting", Value::bool(true));
                data.set("conversion", Value::Int(300));
            }
        }
        Vec::new()
    }

    // ## Spawning

    /// `Zombie.finalizeSpawn` (`zombie/3`): `populate` is its
    /// `populateDefaultEquipmentSlots` (on the level's random),
    /// `reinforcements` false its reinforcement chance that draws nothing.
    pub fn finalize(
        &self,
        t: &mut Turn,
        reason: &Atom,
        populate: impl FnOnce(&Parts, &mut Turn),
        reinforcements: bool,
    ) {
        spawn::mob(t, reason);
        let special = spawn::special(t);
        let conversion = reason.as_str() == "conversion";
        if !conversion {
            let roll = spawn::level_float(t);
            super::loot(t, roll, special);
        }
        // `getSpawnAsBabyOdds`, and a baby's chicken jockey.
        if spawn::level_float(t) < f(0.05) {
            set_baby(&mut t.mob.body.mob, &mut t.mob.body.data, true);
            self.jockey(t);
        }
        let roll = spawn::level_float(t);
        t.mob
            .body
            .data
            .set("can_break_doors", Value::bool(roll < f(special * f(0.1))));
        if !conversion {
            populate(self, t);
            spawn::enchant_equipment(t);
        }
        super::halloween(t);
        let type_id = t.type_id;
        let facts = t.level.facts;
        let mob = &mut t.mob.body;
        handle_attributes(
            facts,
            type_id,
            &mut mob.mob,
            &mut mob.data,
            &mut t.random,
            special,
            reason.as_str(),
            reinforcements,
        );
    }

    /// A zombie's `populateDefaultEquipmentSlots`: armour, then its weapon.
    pub fn populate(&self, t: &mut Turn) {
        spawn::armour(t);
        self.weapon(t);
    }

    // A baby rides a nearby chicken one time in twenty, else one time in
    // twenty a new one (riding is not modelled: the chicken stays beside it).
    fn jockey(&self, t: &mut Turn) {
        if spawn::level_float(t) < 0.05 {
            let b = inflate(&t.bbox(), 5.0, 3.0, 5.0);
            let chickens = t.mobs_in(Kinds::Types(&[self.chicken]), &b);
            if let Some(chicken) = chickens.first() {
                t.effect(Effect::Jockey(chicken.uuid()));
            }
        } else if spawn::level_float(t) < 0.05 {
            self.new_chicken(t);
        }
    }

    // `EntityTypes.CHICKEN.create(JOCKEY)` at the zombie, finalized at once:
    // its variant (one candidate of its climate) and sound variant, then
    // `Mob`'s draws.
    fn new_chicken(&self, t: &mut Turn) {
        spawn::level_int(t, 1);
        let sounds = t
            .level
            .facts
            .registries
            .get("minecraft:chicken_sound_variant")
            .map_or(0, |n| n.len()) as i32;
        spawn::level_int(t, sounds);
        let a = spawn::level_double(t);
        let b = spawn::level_double(t);
        let roll = spawn::level_float(t);
        let options = Map::from_atoms([
            ("jockey", Value::bool(true)),
            ("yaw", Value::Float(t.yaw())),
            ("left_handed", Value::bool(roll < f(0.05))),
            ("follow_bonus", Value::Float(0.11485000000000001 * (a - b))),
        ]);
        t.effect(Effect::Spawn {
            type_id: self.chicken,
            options: Value::Map(options),
        });
    }

    // `Zombie.populateDefaultEquipmentSlots` after the armour: a sword,
    // spear or shovel a hundredth of the time (a twentieth on hard).
    fn weapon(&self, t: &mut Turn) {
        let chance = if t.level.difficulty == Difficulty::Hard {
            0.05
        } else {
            0.01
        };
        if spawn::level_float(t) < f(chance) {
            let item = match spawn::level_int(t, 6) {
                0 => self.iron_sword,
                1 => self.iron_spear,
                _ => self.iron_shovel,
            };
            spawn::equip(t, Slot::Mainhand, Some(super::stack(item)));
        }
    }

    // A husk's natural spawn where a camel husk fits: one time in ten an
    // iron spear and a camel husk ridden by a parched (riding is not
    // modelled).
    fn camel_husk(&self, t: &mut Turn, reason: &Atom) {
        if reason.as_str() != "natural" {
            return;
        }
        let Some(camel) = t.level.facts.entities.get(self.camel_husk) else {
            return;
        };
        let [x, y, z] = t.block();
        let half = f(camel.width) / 2.0;
        let b = Aabb {
            min: [x as f64 + 0.5 - half, y as f64, z as f64 + 0.5 - half],
            max: [
                x as f64 + 0.5 + half,
                y as f64 + f(camel.height),
                z as f64 + 0.5 + half,
            ],
        };
        if t.level.fits(&b) && spawn::level_float(t) < f(0.1) {
            spawn::equip(t, Slot::Mainhand, Some(super::stack(self.iron_spear)));
            let natural = || Value::Map(Map::from_atoms([("reason", Value::atom("natural"))]));
            t.effect(Effect::Spawn {
                type_id: self.camel_husk,
                options: natural(),
            });
            t.effect(Effect::Spawn {
                type_id: self.parched,
                options: natural(),
            });
        }
    }
}

/// `setBaby`: the flag and the baby speed modifier.
pub fn set_baby(mob: &mut Mob, data: &mut FamilyData, baby: bool) {
    data.set("baby", Value::bool(baby));
    let add = baby.then_some((Number::Float(0.5), 1));
    mob.attributes.toggle(MOVEMENT_SPEED, "minecraft:baby", add);
}

/// `Zombie.handleAttributes`, from the zombie's own `random`: its
/// reinforcement chance (none drawn without `reinforcements`), a knockback
/// resistance and follow range bonus and, by chance, a leader (more
/// reinforcements and health, full health but after a conversion or load,
/// door breaking).
#[allow(clippy::too_many_arguments)]
pub fn handle_attributes(
    facts: &MobFacts,
    type_id: u16,
    mob: &mut Mob,
    data: &mut FamilyData,
    random: &mut LegacyRandom,
    special: f64,
    reason: &str,
    reinforcements: bool,
) {
    if reinforcements {
        let d = random.double();
        spawn::set_base(mob, SPAWN_REINFORCEMENTS, d * f(0.1));
    } else {
        spawn::set_base(mob, SPAWN_REINFORCEMENTS, 0.0);
    }
    let d = random.double();
    spawn::add_modifier(
        mob,
        "minecraft:knockback_resistance",
        spawn::BONUS,
        d * f(0.05),
        0,
    );
    let d = random.double();
    let follow = d * 1.5 * special;
    if follow > 1.0 {
        spawn::add_modifier(
            mob,
            spawn::FOLLOW,
            "minecraft:zombie_random_spawn_bonus",
            follow,
            2,
        );
    }
    if (random.float() as f64) < f(special * f(0.05)) {
        let d = random.double();
        spawn::add_modifier(
            mob,
            SPAWN_REINFORCEMENTS,
            "minecraft:leader_zombie_bonus",
            d * 0.25 + 0.5,
            0,
        );
        let d = random.double();
        spawn::add_modifier(
            mob,
            "minecraft:max_health",
            "minecraft:leader_zombie_bonus",
            d * 3.0 + 1.0,
            2,
        );
        if !matches!(reason, "conversion" | "load" | "dimension_travel") {
            // `setHealth(getMaxHealth())`: the maximum follows the bonus.
            let max = f(attribute(facts, type_id, mob, "minecraft:max_health"));
            mob.living.health.maximum = max;
            mob.living.health.value = max;
        }
        data.set("can_break_doors", Value::bool(true));
    }
}

/// The zombie family.
pub struct Zombie {
    pub parts: Parts,
    types: [&'static str; 3],
}

impl Zombie {
    pub fn new(facts: &MobFacts) -> Result<Zombie, String> {
        Ok(Zombie {
            parts: Parts::new(facts)?,
            types: [ZOMBIE, HUSK, VILLAGER],
        })
    }
}

impl Hooks for Zombie {
    fn voice(&self, type_id: u16, data: &FamilyData) -> f32 {
        self.parts.voice(type_id, data)
    }

    fn hit(&self, t: &mut Turn, target: &Seen) {
        self.parts.hit(t, target);
    }
}

impl Family for Zombie {
    fn data(&self, type_id: u16) -> FamilyData {
        FamilyData::new(self.parts.data(type_id)).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let type_id = self.type_of(body);
        self.parts.values(type_id, &body.data)
    }

    fn voice(&self, body: &Body) -> f32 {
        self.parts.voice(self.type_of(body), &body.data)
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        self.parts.dimensions(body)
    }
}

impl Zombie {
    fn type_of(&self, body: &Body) -> u16 {
        match body.entity_type.as_str() {
            HUSK => self.parts.husk,
            VILLAGER => self.parts.villager,
            _ => self.parts.zombie,
        }
    }
}

impl Kind for Zombie {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Zombie"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, type_id: u16) -> Registered {
        let p = &self.parts;
        let mut goals = p.common_goals();
        goals.extend([
            Registration::new(2, "SpearUseGoal", MOVE | LOOK, Idle::new("SpearUseGoal")),
            Registration::new(
                3,
                "ZombieAttackGoal",
                MOVE | LOOK,
                MeleeAttack::new(1.0, false, true),
            ),
            Registration::new(
                6,
                "MoveThroughVillageGoal",
                MOVE,
                Idle::new("MoveThroughVillageGoal"),
            ),
            Registration::new(
                7,
                "WaterAvoidingRandomStrollGoal",
                MOVE,
                RandomStroll::new(
                    1.0,
                    StrollOptions {
                        water_avoiding: true,
                        ..StrollOptions::default()
                    },
                ),
            ),
        ]);
        let targets = vec![
            Registration::new(
                1,
                "HurtByTargetGoal",
                TARGET,
                HurtByTarget::new(true, p.alerted(type_id), Vec::new()),
            ),
            Registration::new(
                2,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Player,
                    None,
                    true,
                    TargetOptions::default(),
                ),
            ),
            Registration::new(
                3,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(p.villagers.clone())),
                    false,
                    TargetOptions::default(),
                ),
            ),
            Registration::new(
                3,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(vec![p.iron_golem])),
                    true,
                    TargetOptions::default(),
                ),
            ),
            p.turtle_target(),
        ];
        Registered { goals, targets }
    }

    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        let p = &self.parts;
        if t.type_id == p.villager {
            // The profession its random drew as it was made, then the
            // biome's type.
            if !flag(t.data(), "finalized") {
                let level = t
                    .data()
                    .get("villager")
                    .and_then(Value::as_tuple)
                    .and_then(|v| v.get(2).cloned())
                    .unwrap_or(Value::Int(1));
                let professions = &t.level.facts.hostile.professions;
                let i = t.int(professions.len() as i32);
                let profession = professions[i as usize].clone();
                let biome = t.level.biome_name(t.block()).to_owned();
                let kind = t.level.facts.hostile.villager_type(&biome).to_owned();
                let data = &mut t.mob.body.data;
                data.set(
                    "villager",
                    Value::tuple([
                        Value::Binary(kind.into_bytes()),
                        Value::Binary(profession.into_bytes()),
                        level,
                    ]),
                );
                data.set("finalized", Value::bool(true));
            }
            p.finalize(t, reason, Parts::populate, true);
        } else if t.type_id == p.husk {
            p.finalize(t, reason, Parts::populate, true);
            let special = spawn::special(t);
            if reason.as_str() != "conversion" {
                let roll = spawn::level_float(t);
                super::loot(t, roll, special);
            }
            p.camel_husk(t, reason);
        } else {
            p.finalize(t, reason, Parts::populate, true);
        }
    }

    fn after_move(&self, mob: &mut NativeMob, ticked: &Ticked) -> Vec<Effect> {
        let p = &self.parts;
        match mob.body.entity_type.as_str() {
            ZOMBIE => p.drown(mob, ticked, p.drowned, 1040),
            HUSK => p.drown(mob, ticked, p.zombie, 1041),
            _ => Vec::new(),
        }
    }

    fn wants(&self, _t: &Turn, item: i32) -> bool {
        item != self.parts.glow_ink
    }

    fn baby(&self, body: &Body) -> bool {
        flag(&body.data, "baby")
    }

    fn set_baby(&self, mob: &mut Mob, data: &mut FamilyData, baby: bool) {
        set_baby(mob, data, baby);
    }

    fn after_conversion(&self, facts: &MobFacts, body: &mut Body, special: f64) {
        let type_id = self.type_of(body);
        let Some(mut mind) = body.mob.ai.take() else {
            return;
        };
        handle_attributes(
            facts,
            type_id,
            &mut body.mob,
            &mut body.data,
            &mut mind.random,
            special,
            "conversion",
            true,
        );
        body.mob.ai = Some(mind);
    }

    fn fresh_data(&self, type_id: u16) -> Vec<(Atom, Value)> {
        self.parts.data(type_id)
    }
}
