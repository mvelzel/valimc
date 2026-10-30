//! Endermites (`Valimc.AI.Mobs.Endermite`, vanilla's `Endermite`): small
//! melee monsters that climb out of powder snow. Its body always faces its
//! yaw (`tick` sets `yBodyRot` first), its steps are events, and one that is
//! not persistent lives 2400 ticks (`Lifetime`, saved), then is discarded,
//! a `NoAI` one too.

use super::{entity, fields, int};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::goal::{JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    ClimbPowderSnow, Float, HurtByTarget, LookAtPlayer, MeleeAttack, NearestAttackableTarget,
    RandomLookAround, RandomStroll, TargetKind,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered, Registration};
use crate::mobs::model::FamilyData;
use crate::mobs::term::{Atom, Value};

pub const ENDERMITE: &str = "minecraft:endermite";

/// Its lifetime.
const LIFE: i64 = 2400;

/// The endermite family.
pub struct Endermite {
    types: [&'static str; 1],
    type_id: u16,
}

impl Endermite {
    pub fn new(facts: &MobFacts) -> Result<Endermite, String> {
        Ok(Endermite {
            types: [ENDERMITE],
            type_id: entity(facts, ENDERMITE)?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("life", Value::Int(0))])
    }
}

impl Hooks for Endermite {}

impl Family for Endermite {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Endermite::data_of()).unwrap_or_else(FamilyData::empty)
    }
}

impl Kind for Endermite {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Endermite"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(
                    1,
                    "ClimbOnTopOfPowderSnowGoal",
                    JUMP,
                    ClimbPowderSnow::new(),
                ),
                Registration::new(
                    2,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(1.0, false, false),
                ),
                Registration::new(
                    3,
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
                    7,
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
            ],
            targets: vec![
                Registration::new(
                    1,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(true, vec![self.type_id], Vec::new()),
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
            ],
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            emission: Emission::Events,
            ..KindMotion::default()
        }
    }

    /// `tick` sets its body's yaw first.
    fn tick_start(&self, t: &mut Turn) {
        t.mind.body_yaw = t.yaw();
    }

    /// `aiStep` after its super: a mob that is not persistent ages, and goes
    /// at the end of its lifetime.
    fn after_ai(&self, t: &mut Turn) {
        let life = int(t.data(), "life");
        let life = if t.mob.body.mob.persistent {
            life
        } else {
            life + 1
        };
        t.mob.body.data.set("life", Value::Int(life));
        if life >= LIFE {
            t.effect(Effect::Discard);
        }
    }

    fn still(&self) -> bool {
        true
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Endermite::data_of()
    }
}
