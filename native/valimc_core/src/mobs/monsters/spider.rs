//! Spiders and cave spiders (`Valimc.AI.Mobs.Spider`, vanilla's `Spider`
//! and `CaveSpider`):
//!
//! - **Goals**: floating, fleeing armadillos, leaping at a target two to
//!   four blocks away, chasing it even unseen (giving up now and then in the
//!   light, `Attack`), wandering and looking around; the player and iron
//!   golems as targets only in the dark, whoever hurt it any time.
//! - **Climbing**: a spider that bumped into a wall climbs it (its
//!   `onClimbable`, the kernel's wall climb), and its paths lead to the
//!   target's block even where no path does (`WallClimberNavigation`).
//! - **Spawning**: a skeleton jockey one time in a hundred and, on hard, now
//!   and then an endless speed, strength, regeneration or invisibility. A
//!   cave spider draws nothing.
//! - **Bites**: a cave spider's poisons for 7 seconds (15 on hard).

use super::{entity, fields, flag, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{f, floor};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    AvoidEntity, EntityTest, Float, HurtByTarget, LeapAtTarget, LookAtPlayer, MeleeAttack,
    MobTypes, NearestAttackableTarget, RandomLookAround, RandomStroll, TargetKind,
};
use crate::mobs::ai::hooks::{Hooks, Tag};
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, NavSpec, Registered, Registration};
use crate::mobs::level::Difficulty;
use crate::mobs::model::{Body, FamilyData, NativeMob, Rung};
use crate::mobs::term::{Atom, Map, Value};
use crate::physics::mob::Ticked;

pub const SPIDER: &str = "minecraft:spider";
pub const CAVE_SPIDER: &str = "minecraft:cave_spider";

/// `SpiderTargetGoal`'s condition: only in the dark.
const DARK: Tag = 1;

/// The effects a hard spawn may give (`Spider.SpiderEffectsGroupData`).
const EFFECTS: [&str; 5] = [
    "minecraft:speed",
    "minecraft:speed",
    "minecraft:strength",
    "minecraft:regeneration",
    "minecraft:invisibility",
];

/// The spider family.
pub struct Spider {
    types: [&'static str; 2],
    cave: u16,
    armadillo: u16,
    iron_golem: u16,
    poison: i32,
    effects: Vec<i32>,
}

impl Spider {
    pub fn new(facts: &MobFacts) -> Result<Spider, String> {
        Ok(Spider {
            types: [SPIDER, CAVE_SPIDER],
            cave: entity(facts, CAVE_SPIDER)?,
            armadillo: entity(facts, "minecraft:armadillo")?,
            iron_golem: entity(facts, "minecraft:iron_golem")?,
            poison: super::effect(facts, "minecraft:poison")?,
            effects: EFFECTS
                .iter()
                .map(|name| super::effect(facts, name))
                .collect::<Result<_, _>>()?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("climbing", Value::bool(false))])
    }
}

/// `brightness/1`: `getLightLevelDependentMagicValue` at the spider's eyes.
pub fn brightness(t: &Turn) -> f64 {
    let [x, _, z] = t.pos();
    t.level.light([floor(x), floor(t.eye_y()), floor(z)]) as f64
}

impl Hooks for Spider {
    fn test(&self, t: &mut Turn, tag: Tag) -> bool {
        tag == DARK && brightness(t) < 0.5
    }

    /// `CaveSpider.doHurtTarget`: a poisoning bite (none on easy).
    fn hit(&self, t: &mut Turn, target: &Seen) {
        if t.type_id != self.cave {
            return;
        }
        let seconds = match t.level.difficulty {
            Difficulty::Normal => 7,
            Difficulty::Hard => 15,
            _ => 0,
        };
        if seconds > 0 {
            let rung = Value::tuple([
                Value::Int(seconds * 20),
                Value::Int(0),
                Value::bool(false),
                Value::bool(true),
                Value::bool(true),
            ]);
            let extras = Map::from_atoms([(
                "effect",
                Value::tuple([Value::Int(self.poison as i64), rung]),
            )]);
            t.effect(Effect::AttackExtra(target.reference, Value::Map(extras)));
        }
    }
}

impl Family for Spider {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Spider::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let flags = if flag(&body.data, "climbing") { 1 } else { 0 };
        vec![value("spider_flags", Value::Int(flags), Value::Int(0))]
    }
}

impl Kind for Spider {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Spider"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn navigation(&self, _type_id: u16) -> NavSpec {
        NavSpec {
            climber: true,
            ..NavSpec::default()
        }
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let dark = |priority, kind, select| {
            Registration::new(
                priority,
                "SpiderTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    kind,
                    select,
                    true,
                    TargetOptions {
                        when: Some(DARK),
                        ..TargetOptions::default()
                    },
                ),
            )
        };
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                // Armadillos are not modelled yet: none is scared.
                Registration::new(
                    2,
                    "AvoidEntityGoal",
                    MOVE,
                    AvoidEntity::new(EntityTest::Mobs(vec![self.armadillo]), 6.0, 1.0, 1.2),
                ),
                Registration::new(3, "LeapAtTargetGoal", MOVE | JUMP, LeapAtTarget::new(0.4)),
                Registration::new(4, "SpiderAttackGoal", MOVE | LOOK, Attack::new()),
                Registration::new(
                    5,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        0.8,
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
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), Vec::new()),
                ),
                dark(2, TargetKind::Player, None),
                dark(
                    3,
                    TargetKind::Mob,
                    Some(MobTypes::Types(vec![self.iron_golem])),
                ),
            ],
        }
    }

    /// `finalizeSpawn`: a mob's, a skeleton jockey one time in a hundred,
    /// and on hard by chance an endless effect; a cave spider's draws
    /// nothing.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        if t.type_id == self.cave {
            return;
        }
        spawn::mob(t, reason);
        if spawn::level_int(t, 100) == 0 {
            spawn::companion(t, "minecraft:skeleton", &Atom::from_static("jockey"));
        }
        if t.level.difficulty == Difficulty::Hard
            && spawn::level_float(t) < f(f(0.1) * spawn::special(t))
        {
            let effect = self.effects[spawn::level_int(t, 5) as usize];
            let rung = Rung {
                ticks: -1,
                amplifier: 0,
                ambient: false,
                particles: true,
                icon: true,
            };
            let facts = t.level.facts;
            crate::mobs::living::mob::add_effect(facts, &mut t.mob.body.mob, effect, rung);
        }
    }

    /// `Spider.onClimbable`: it climbs what it bumped into.
    fn climbs(&self, body: &Body) -> Option<bool> {
        Some(flag(&body.data, "climbing"))
    }

    /// `Spider.tick` after the move: `setClimbing(horizontalCollision)`.
    fn after_move(&self, mob: &mut NativeMob, ticked: &Ticked) -> Vec<Effect> {
        mob.body
            .data
            .set("climbing", Value::bool(ticked.mob.horizontal_collision));
        Vec::new()
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Spider::data_of()
    }
}

/// `SpiderAttackGoal` (`Spider.Attack`): melee that follows an unseen
/// target; in light of half brightness or more it gives up one time in a
/// hundred, dropping its target.
#[derive(Clone, Debug, PartialEq)]
pub struct Attack {
    melee: MeleeAttack,
}

impl Attack {
    fn new() -> Attack {
        Attack {
            melee: MeleeAttack::new(1.0, true, false),
        }
    }
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        self.melee.can_use(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        if brightness(t) >= 0.5 && t.int(100) == 0 {
            t.set_target(None);
            return false;
        }
        self.melee.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.melee.start(t);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.melee.stop(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.melee.tick(t);
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Spider.Attack"
    }
}
