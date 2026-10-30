//! A strider (`Valimc.Entity.Animals.Strider`, vanilla's `Strider`), an
//! animal: it walks on lava (the kernel's lava walker), heads for lava
//! within eight blocks when out of it (`GoToLava`), panics, breeds on and
//! is tempted by warped fungus and follows its parent. Away from lava and
//! other warm blocks it shivers (its suffocating flag) and slows by a
//! third. Tempted it now and then sounds happy, panicking it retreats.
//!
//! Riding with a saddle and a warped fungus on a stick, and the jockeys it
//! may spawn with, wait for vehicles (VMC-046), as in the Elixir.

use super::{Animal, Species};
use crate::mobs::ai::fmath::{f, floor};
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE};
use crate::mobs::ai::goals::move_to_block::{BlockOptions, BlockTest, MoveToBlock};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::{
    Breed, FollowParent, ItemTest, LookAtPlayer, MobTypes, Panic, RandomLookAround, RandomStroll,
    Tempt,
};
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::navigation;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::Turn;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{KindMotion, Registered, Registration};
use crate::mobs::model::{FamilyData, Number};
use crate::mobs::term::{Atom, Value};

const LAVA: Tag = 1;
const SPEED: &str = "minecraft:movement_speed";
const SUFFOCATING: &str = "minecraft:suffocating";

pub struct Strider {
    tempt: Vec<i32>,
    /// The states of the warm blocks.
    warm: Vec<u16>,
    /// The lava block's states.
    lava: (u16, u16),
    happy: i32,
    retreat: i32,
    ambient: i32,
}

impl Strider {
    pub fn new(facts: &MobFacts) -> Result<Strider, String> {
        let blocks = &facts.blocks;
        let mut warm: Vec<u16> = facts
            .tags
            .get("minecraft:block", "minecraft:strider_warm_blocks")
            .unwrap_or_default()
            .iter()
            .filter_map(|&id| blocks.block(id as u16))
            .flat_map(|b| b.first..=b.last)
            .collect();
        warm.sort_unstable();
        let lava = blocks
            .id("lava")
            .and_then(|id| blocks.block(id))
            .map(|b| (b.first, b.last))
            .ok_or("no lava")?;
        let sound = |name: &str| {
            facts
                .sounds
                .id(name)
                .ok_or_else(|| format!("unknown sound {name}"))
        };
        Ok(Strider {
            tempt: crate::mobs::monsters::item_tag(facts, "minecraft:strider_tempt_items"),
            warm,
            lava,
            happy: sound("minecraft:entity.strider.happy")?,
            retreat: sound("minecraft:entity.strider.retreat")?,
            ambient: sound("minecraft:entity.strider.ambient")?,
        })
    }

    fn lava_state(&self, state: Option<u16>) -> bool {
        state.is_some_and(|s| (self.lava.0..=self.lava.1).contains(&s))
    }

    fn warm(&self, state: Option<i64>) -> bool {
        state.is_some_and(|s| u16::try_from(s).is_ok_and(|s| self.warm.binary_search(&s).is_ok()))
    }

    // Whether it shivers: not in or on a warm block nor in lava
    // (`getBlockStateOnLegacy`: through its supporting block, as its last
    // move left it).
    fn shiver(&self, t: &mut Turn) {
        let inside = t.level.block(t.block()).map(i64::from);
        let on = match t.mob.body.mob.motion.support {
            Some(s) => Some(s as i64),
            None => {
                let [x, y, z] = t.pos();
                t.level
                    .block([floor(x), floor(y - f(0.2)), floor(z)])
                    .map(i64::from)
            }
        };
        let warm = self.warm(inside) || self.warm(on) || t.in_lava();
        set_suffocating(t, !warm);
    }
}

/// `setSuffocating`: its flag and a third less speed.
fn set_suffocating(t: &mut Turn, on: bool) {
    let add = on.then_some((Number::Float(f(-0.34)), 1));
    t.mob.body.mob.attributes.toggle(SPEED, SUFFOCATING, add);
    t.mob.body.data.set("suffocating", Value::bool(on));
}

fn tempted_or_panicking(t: &Turn) -> (bool, bool) {
    let goals = &t.mind.goals;
    (goals.runs::<Tempt>(), goals.runs::<Panic>())
}

impl Species for Strider {
    const TYPE: &'static str = "minecraft:strider";
    const MODULE: &'static str = "Valimc.Entity.Animals.Strider";

    fn goals(&self, a: &Animal<Self>, _facts: &MobFacts) -> Registered {
        Registered {
            goals: vec![
                Registration::new(1, "PanicGoal", MOVE, Panic::new(1.65, None)),
                Registration::new(2, "BreedGoal", MOVE | LOOK, Breed::new(1.0, None, None)),
                Registration::new(
                    3,
                    "TemptGoal",
                    MOVE | LOOK,
                    Tempt::new(1.4, ItemTest::Set(self.tempt.clone()), false, 2.5),
                ),
                Registration::new(4, "StriderGoToLavaGoal", MOVE | JUMP, GoToLava::new()),
                Registration::new(5, "FollowParentGoal", 0, FollowParent::new(1.0)),
                Registration::new(
                    7,
                    "RandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            interval: 60,
                            ..StrollOptions::default()
                        },
                    ),
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
                Registration::new(
                    9,
                    "LookAtPlayerGoal",
                    LOOK,
                    LookAtPlayer::new(8.0, 0.02, false, Some(MobTypes::Types(vec![a.type_id]))),
                ),
            ],
            targets: Vec::new(),
        }
    }

    fn defaults(&self) -> Vec<(Atom, Value)> {
        vec![(Atom::from_static("suffocating"), Value::bool(false))]
    }

    fn fields(&self, _a: &Animal<Self>, data: &FamilyData) -> Vec<(Atom, Value, Value)> {
        let on = data
            .get("suffocating")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        vec![(
            Atom::from_static("strider_suffocating"),
            Value::bool(on),
            Value::bool(false),
        )]
    }

    fn offspring(
        &self,
        _a: &Animal<Self>,
        _t: &mut Turn,
        _partner: &FamilyData,
    ) -> Vec<(Atom, Value)> {
        self.defaults()
    }

    /// `finalizeSpawn`'s own part for an adult: one time in thirty a
    /// zombified piglin rides it, else one time in ten a baby strider (the
    /// level's random; riders wait for vehicles).
    fn spawn_part(&self, _a: &Animal<Self>, t: &mut Turn, _reason: &Atom) {
        if super::age(t.data()) < 0 {
            return;
        }
        if spawn::level_int(t, 30) != 0 {
            spawn::level_int(t, 10);
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            lava_walker: true,
            ..KindMotion::default()
        }
    }

    /// `Strider.tick` before its super: tempted, a happy sound one tick in
    /// 140; panicking, a retreat one tick in 60; then whether it shivers.
    fn tick_start(&self, _a: &Animal<Self>, t: &mut Turn) {
        let sound = match tempted_or_panicking(t) {
            (true, _) => (t.int(140) == 0).then_some(self.happy),
            (false, true) => (t.int(60) == 0).then_some(self.retreat),
            _ => None,
        };
        if let Some(sound) = sound {
            crate::mobs::ai::think::make_sound(t, sound);
        }
        if !t.mob.body.mob.no_ai {
            self.shiver(t);
        }
    }

    /// `getAmbientSound`: none while panicking or tempted.
    fn ambient_sound(&self, _a: &Animal<Self>, t: &mut Turn) -> Option<Option<i32>> {
        let (tempted, panicking) = tempted_or_panicking(t);
        Some((!(tempted || panicking)).then_some(self.ambient))
    }

    /// `getWalkTargetValue`: lava is worth 10; out of it, only lava is
    /// worth anything.
    fn walk_value(&self, _a: &Animal<Self>, t: &mut Turn, pos: [i32; 3]) -> Option<f64> {
        Some(if self.lava_state(t.level.block(pos)) {
            10.0
        } else if t.in_lava() {
            f64::NEG_INFINITY
        } else {
            0.0
        })
    }

    /// `StriderGoToLavaGoal`'s `isValidTarget`: lava with room for a land
    /// walker above.
    fn block(
        &self,
        _a: &Animal<Self>,
        t: &mut Turn,
        tag: Tag,
        [x, y, z]: [i32; 3],
        _goal: &mut MoveToBlock,
    ) -> bool {
        if tag != LAVA {
            return false;
        }
        let lava = self.lava_state(t.level.block([x, y, z]));
        let above = t.level.block([x, y + 1, z]);
        lava && above.is_some_and(|s| {
            t.paths
                .flags
                .get(s as usize)
                .is_some_and(|f| f & crate::path::LAND != 0)
        })
    }
}

/// `Strider.StriderGoToLavaGoal` (`Strider.GoToLava`, `MoveToBlockGoal` at
/// 1.0, eight blocks around and two up or down): out of lava, to a lava
/// block with room to stand above it; it walks to the lava block itself
/// (recalculating every 20 ticks toward that block, not the one above it).
#[derive(Clone, Debug, PartialEq)]
pub struct GoToLava(MoveToBlock);

impl GoToLava {
    fn new() -> GoToLava {
        GoToLava(MoveToBlock::new(
            1.0,
            8,
            BlockTest::Family(LAVA),
            BlockOptions {
                vertical: 2,
                ..BlockOptions::default()
            },
        ))
    }
}

impl Goal for GoToLava {
    fn every_tick(&self) -> bool {
        true
    }

    fn can_use(&mut self, t: &mut Turn) -> bool {
        if t.in_lava() {
            false
        } else {
            self.0.can_use(t)
        }
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let cell = self.0.cell;
        let valid = self.0.valid(t, cell);
        !t.in_lava() && valid
    }

    fn start(&mut self, t: &mut Turn) {
        self.0.start(t);
    }

    // `MoveToBlockGoal.tick` toward the lava block itself.
    fn tick(&mut self, t: &mut Turn) {
        let goal = &mut self.0;
        let [x, y, z] = goal.cell;
        let d = [
            x as f64 + 0.5 - t.x(),
            y as f64 + 0.5 - t.y(),
            z as f64 + 0.5 - t.z(),
        ];
        if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 1.0 {
            goal.reached = true;
            goal.tries -= 1;
        } else {
            let tries = goal.tries + 1;
            if tries % 20 == 0 {
                navigation::move_to(t, [x as f64 + 0.5, y as f64, z as f64 + 0.5], goal.speed);
            }
            goal.reached = false;
            goal.tries = tries;
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.Entity.Animals.Strider.GoToLava"
    }
}
