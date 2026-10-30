//! Skeletons, strays and bogged (`Valimc.AI.Mobs.Skeleton`, vanilla's
//! `AbstractSkeleton` and its kinds):
//!
//! - **Goals**: keeping out of the sun by day and fleeing it when burning,
//!   fleeing wolves, wandering and looking around; a bow goal while it holds
//!   a bow, else melee (`Weapon`, `reassessWeaponGoal`); the player, iron
//!   golems and baby turtles as targets.
//! - **Spawning**: armour, a bow, their enchantments, loot pickup and a
//!   Halloween head.
//! - **Freezing**: a skeleton in powder snow for seven seconds shakes and
//!   becomes a stray fifteen seconds later.

use super::{entity, fields, flag, int, item, item_tag, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    AvoidEntity, EntityTest, FleeSun, HurtByTarget, LookAtPlayer, MeleeAttack, MobTypes,
    NearestAttackableTarget, RandomLookAround, RandomStroll, RangedBowAttack, RestrictSun,
    TargetKind,
};
use crate::mobs::ai::hooks::{item_id, Hooks};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::level::Difficulty;
use crate::mobs::model::{Body, FamilyData, Slot};
use crate::mobs::term::{Atom, Value};

pub const SKELETON: &str = "minecraft:skeleton";
pub const STRAY: &str = "minecraft:stray";
pub const BOGGED: &str = "minecraft:bogged";

/// The skeleton family.
pub struct Skeleton {
    types: [&'static str; 3],
    skeleton: u16,
    stray: u16,
    bogged: u16,
    wolf: u16,
    iron_golem: u16,
    turtle: u16,
    bow: i32,
    spears: Vec<i32>,
    preferred: Vec<i32>,
}

impl Skeleton {
    pub fn new(facts: &MobFacts) -> Result<Skeleton, String> {
        Ok(Skeleton {
            types: [SKELETON, STRAY, BOGGED],
            skeleton: entity(facts, SKELETON)?,
            stray: entity(facts, STRAY)?,
            bogged: entity(facts, BOGGED)?,
            wolf: entity(facts, "minecraft:wolf")?,
            iron_golem: entity(facts, "minecraft:iron_golem")?,
            turtle: entity(facts, "minecraft:turtle")?,
            bow: item(facts, "minecraft:bow")?,
            spears: item_tag(facts, "minecraft:spears"),
            preferred: item_tag(facts, "minecraft:skeleton_preferred_weapons"),
        })
    }

    fn data_of(&self, type_id: u16) -> Vec<(Atom, Value)> {
        if type_id == self.skeleton {
            fields(&[
                ("in_snow", Value::Int(0)),
                ("converting", Value::bool(false)),
                ("conversion", Value::Int(-1)),
            ])
        } else if type_id == self.bogged {
            fields(&[("sheared", Value::bool(false))])
        } else {
            Vec::new()
        }
    }
}

/// `intervals/1`: the bow goal's least interval on hard and otherwise
/// (`getHardAttackInterval`, `getAttackInterval`).
fn intervals(bogged: bool) -> (i64, i64) {
    if bogged {
        (50, 70)
    } else {
        (20, 40)
    }
}

impl Hooks for Skeleton {}

impl Family for Skeleton {
    fn data(&self, type_id: u16) -> FamilyData {
        FamilyData::new(self.data_of(type_id)).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        match body.entity_type.as_str() {
            SKELETON => vec![value(
                "skeleton_stray_conversion",
                Value::bool(flag(&body.data, "converting")),
                Value::bool(false),
            )],
            BOGGED => vec![value(
                "bogged_sheared",
                Value::bool(flag(&body.data, "sheared")),
                Value::bool(false),
            )],
            _ => Vec::new(),
        }
    }
}

impl Kind for Skeleton {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Skeleton"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let target = |priority, types: Vec<u16>, interval| {
            Registration::new(
                priority,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Mob,
                    Some(MobTypes::Types(types)),
                    true,
                    TargetOptions {
                        interval,
                        ..TargetOptions::default()
                    },
                ),
            )
        };
        Registered {
            goals: vec![
                Registration::new(2, "RestrictSunGoal", 0, RestrictSun::new()),
                Registration::new(3, "FleeSunGoal", MOVE, FleeSun::new(1.0)),
                Registration::new(
                    3,
                    "AvoidEntityGoal",
                    MOVE,
                    AvoidEntity::new(EntityTest::Mobs(vec![self.wolf]), 6.0, 1.0, 1.2),
                ),
                Registration::new(
                    5,
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
                Registration::new(
                    6,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, None),
                ),
                Registration::new(
                    6,
                    "RandomLookAroundGoal",
                    MOVE | LOOK,
                    RandomLookAround::new(),
                ),
                // Added by `reassessWeaponGoal` as it is made: melee until it
                // holds a bow.
                Registration::new(
                    4,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    Weapon::new(self.bow, self.bogged),
                ),
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), Vec::new()),
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
                target(3, vec![self.iron_golem], 10),
                // `Turtle.BABY_ON_LAND_SELECTOR`: any turtle yet.
                target(3, vec![self.turtle], 10),
            ],
        }
    }

    /// `finalizeSpawn`: a mob's, then armour, a bow, their enchantments,
    /// loot pickup and a Halloween head.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        spawn::mob(t, reason);
        let special = spawn::special(t);
        spawn::armour(t);
        spawn::equip(t, Slot::Mainhand, Some(super::stack(self.bow)));
        spawn::enchant_equipment(t);
        let roll = spawn::level_float(t);
        super::loot(t, roll, special);
        super::halloween(t);
    }

    /// `Skeleton.tick`'s freezing tracker before the rest of its tick
    /// (`ConversionTracker` over `isInPowderSnow` as its last move left it):
    /// 140 ticks in powder snow start the conversion, 300 more turn it into
    /// a stray with the level event 1048.
    fn tick_start(&self, t: &mut Turn) {
        if t.type_id != self.skeleton || t.mob.body.mob.no_ai {
            return;
        }
        let snow = t.mob.body.mob.motion.powder_snow;
        let data = &mut t.mob.body.data;
        if snow && flag(data, "converting") {
            let conversion = int(data, "conversion") - 1;
            data.set("conversion", Value::Int(conversion));
            if conversion < 0 {
                t.effect(Effect::Convert(self.stray));
                let cell = t.block();
                t.effect(Effect::LevelEvent {
                    cell,
                    kind: 1048,
                    data: 0,
                });
            }
        } else if snow {
            let in_snow = int(data, "in_snow") + 1;
            data.set("in_snow", Value::Int(in_snow));
            if in_snow >= 140 {
                data.set("converting", Value::bool(true));
                data.set("conversion", Value::Int(300));
            }
        } else {
            data.set("in_snow", Value::Int(-1));
            data.set("converting", Value::bool(false));
        }
    }

    fn wants(&self, _t: &Turn, item: i32) -> bool {
        !self.spears.contains(&item)
    }

    fn preferred_weapons(&self, _type_id: u16) -> Option<&[i32]> {
        Some(&self.preferred)
    }

    fn fresh_data(&self, type_id: u16) -> Vec<(Atom, Value)> {
        self.data_of(type_id)
    }
}

/// Which weapon goal runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Melee,
    Bow,
}

/// A skeleton's weapon goal (`Skeleton.Weapon`,
/// `AbstractSkeleton.reassessWeaponGoal`): the bow goal
/// (`RangedBowAttackGoal` at its type's interval) while it holds a bow,
/// else melee (`MeleeAttackGoal` at 1.2). Vanilla swaps the two goals at the
/// end of the list as the weapon changes; one goal that follows the weapon
/// keeps that order, stopping the running one when the weapon changes.
#[derive(Clone, Debug, PartialEq)]
pub struct Weapon {
    mode: Mode,
    melee: MeleeAttack,
    bow: RangedBowAttack,
    bow_item: i32,
    bogged: u16,
}

impl Weapon {
    fn new(bow_item: i32, bogged: u16) -> Weapon {
        Weapon {
            mode: Mode::Melee,
            melee: MeleeAttack::new(1.2, false, false),
            bow: RangedBowAttack::new(1.0, 20, 15.0),
            bow_item,
            bogged,
        }
    }

    fn mode(&self, t: &Turn) -> Mode {
        let held =
            |slot| t.mob.body.mob.equipment.get(slot).and_then(item_id) == Some(self.bow_item);
        if held(Slot::Mainhand) || held(Slot::Offhand) {
            Mode::Bow
        } else {
            Mode::Melee
        }
    }

    // The goal for what it holds now, at the type's interval for the
    // difficulty.
    fn current(&mut self, t: &Turn) {
        self.mode = self.mode(t);
        let (hard, normal) = intervals(t.type_id == self.bogged);
        let interval = if t.level.difficulty == Difficulty::Hard {
            hard
        } else {
            normal
        };
        self.bow.set_interval(interval);
    }

    fn sub(&mut self) -> &mut dyn Goal {
        match self.mode {
            Mode::Bow => &mut self.bow,
            Mode::Melee => &mut self.melee,
        }
    }
}

impl Goal for Weapon {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.current(t);
        self.sub().can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if self.mode(t) != self.mode {
            return false;
        }
        self.sub().can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.sub().start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.sub().stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.sub().tick(t);
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Skeleton.Weapon"
    }
}
