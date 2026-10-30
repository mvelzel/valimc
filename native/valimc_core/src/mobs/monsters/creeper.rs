//! Creepers (`Valimc.AI.Mobs.Creeper`, vanilla's `Creeper`):
//!
//! - **Goals**: floating, swelling at a target within three blocks it sees
//!   (`Swell`), fleeing ocelots and cats, chasing (its hits do nothing),
//!   wandering and looking around; the player as its target, then whoever
//!   hurt it.
//! - **Swelling** (its `tick` before the rest): its fuse counts up while it
//!   swells (a lit one always does) and down otherwise; the hiss as it
//!   starts; at 30 it explodes (`{:explode, ...}`): power 3, twice that when
//!   charged; it is gone.
//! - **Lighting** (`mobInteract`): flint and steel or a fire charge lights
//!   it, worn or used up.

use super::{entity, fields, flag, int, item, item_tag, source, value};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{Goal, JUMP, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{
    AvoidEntity, EntityTest, Float, HurtByTarget, LookAtPlayer, MeleeAttack,
    NearestAttackableTarget, RandomLookAround, RandomStroll, TargetKind,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::navigation;
use crate::mobs::ai::turn::Turn;
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::interact::{At, Done, Hand, Interaction, Other, Outcome, Source};
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::living::mob::alive;
use crate::mobs::model::{Body, FamilyData};
use crate::mobs::sensing::Ref;
use crate::mobs::term::{Atom, Map, Value};

pub const CREEPER: &str = "minecraft:creeper";

/// The creeper family.
pub struct Creeper {
    types: [&'static str; 1],
    creeper: u16,
    ocelot: u16,
    cat: u16,
    igniters: Vec<i32>,
    fire_charge: i32,
    fire_charge_sound: i32,
    flint_sound: i32,
}

impl Creeper {
    pub fn new(facts: &MobFacts) -> Result<Creeper, String> {
        let igniters = item_tag(facts, "minecraft:creeper_igniters");
        Ok(Creeper {
            types: [CREEPER],
            creeper: entity(facts, CREEPER)?,
            ocelot: entity(facts, "minecraft:ocelot")?,
            cat: entity(facts, "minecraft:cat")?,
            igniters,
            fire_charge: item(facts, "minecraft:fire_charge")?,
            fire_charge_sound: super::sound(facts, "minecraft:item.firecharge.use")?,
            flint_sound: super::sound(facts, "minecraft:item.flintandsteel.use")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("swell", Value::Int(0)),
            ("swell_dir", Value::Int(-1)),
            ("powered", Value::bool(false)),
            ("ignited", Value::bool(false)),
            ("max_swell", Value::Int(30)),
            ("radius", Value::Int(3)),
        ])
    }
}

impl Hooks for Creeper {
    /// `Creeper.doHurtTarget`: its melee hits do nothing.
    fn harmless(&self, _type_id: u16) -> bool {
        true
    }
}

impl Family for Creeper {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Creeper::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        vec![
            value(
                "creeper_swell_dir",
                data.get("swell_dir").cloned().unwrap_or(Value::Int(-1)),
                Value::Int(-1),
            ),
            value(
                "creeper_powered",
                Value::bool(flag(data, "powered")),
                Value::bool(false),
            ),
            value(
                "creeper_ignited",
                Value::bool(flag(data, "ignited")),
                Value::bool(false),
            ),
        ]
    }
}

impl Kind for Creeper {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Creeper"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let avoid = |types| {
            Registration::new(
                3,
                "AvoidEntityGoal",
                MOVE,
                AvoidEntity::new(EntityTest::Mobs(types), 6.0, 1.0, 1.2),
            )
        };
        Registered {
            goals: vec![
                Registration::new(1, "FloatGoal", JUMP, Float::new()),
                Registration::new(2, "SwellGoal", MOVE, Swell::default()),
                avoid(vec![self.ocelot]),
                avoid(vec![self.cat]),
                Registration::new(
                    4,
                    "MeleeAttackGoal",
                    MOVE | LOOK,
                    MeleeAttack::new(1.0, false, false),
                ),
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
                    2,
                    "HurtByTargetGoal",
                    TARGET,
                    HurtByTarget::new(false, Vec::new(), Vec::new()),
                ),
            ],
        }
    }

    /// `Creeper.tick` before the rest of its tick: a lit creeper swells; the
    /// hiss as it starts; the fuse moves by the swell direction (never below
    /// 0) and at its end the creeper explodes, which ends its tick.
    fn tick_start(&self, t: &mut Turn) {
        if !alive(&t.mob.body.mob) {
            return;
        }
        if flag(t.data(), "ignited") {
            t.mob.body.data.set("swell_dir", Value::Int(1));
        }
        let (swell, dir) = (int(t.data(), "swell"), int(t.data(), "swell_dir"));
        if dir > 0 && swell == 0 {
            // `playSound(CREEPER_PRIMED, 1.0, 0.5)`.
            t.sound("minecraft:entity.creeper.primed", 1.0, 0.5);
        }
        let swell = (swell + dir).max(0);
        let max = int(t.data(), "max_swell");
        if swell >= max {
            t.mob.body.data.set("swell", Value::Int(max));
            let powered = flag(t.data(), "powered");
            let radius = int(t.data(), "radius") as f64 * if powered { 2.0 } else { 1.0 };
            let blast = Map::from_atoms([
                ("center", Value::vec3(t.pos())),
                ("radius", Value::Float(radius)),
                ("powered", Value::bool(powered)),
            ]);
            t.effect(Effect::Explode(Value::Map(blast)));
            t.effect(Effect::Discard);
        } else {
            t.mob.body.data.set("swell", Value::Int(swell));
        }
    }

    /// `Creeper.mobInteract`: an igniter lights it (the others hear the item
    /// at the creeper, pitched from its random); flint and steel wears, a
    /// fire charge is used up.
    fn interact(&self, i: &mut Interaction) -> Outcome {
        let Some(id) = i.request.item_id() else {
            return Outcome::Pass;
        };
        if !self.igniters.contains(&id) || !alive(&i.mob.body.mob) {
            return Outcome::Pass;
        }
        let roll = i.random().float() as f64;
        let pitch = f(f(roll * f(0.4)) + f(0.8));
        let sound = if id == self.fire_charge {
            self.fire_charge_sound
        } else {
            self.flint_sound
        };
        i.mob.body.data.set("ignited", Value::bool(true));
        let damageable = i.rules.living.item(id).max_damage.is_some();
        Outcome::Done(Done {
            hand: Some(if damageable {
                Hand::Wear(1)
            } else {
                Hand::Use(1)
            }),
            swing: true,
            others: Some(Other {
                sound,
                source: Source::Id(source(i.rules.facts, self.creeper)),
                volume: 1.0,
                pitch,
                at: At::Animal,
            }),
            ..Done::default()
        })
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Creeper::data_of()
    }
}

/// `SwellGoal` (`Creeper.Swell`): a creeper about to explode, or with a
/// living target within three blocks, stops and swells while the target
/// stays within seven blocks and in sight, else lets its fuse fall back.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Swell {
    target: Option<Ref>,
}

impl Goal for Swell {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if int(t.data(), "swell_dir") > 0 {
            return true;
        }
        t.target()
            .is_some_and(|target| target.alive && t.distance_sq(target.position) < 9.0)
    }

    fn start(&mut self, t: &mut Turn) {
        self.target = t.target().map(|e| e.reference);
        navigation::stop(t);
    }

    fn stop(&mut self, _t: &mut Turn) {
        self.target = None;
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        let dir = match t.entity(self.target.as_ref()) {
            Some(target)
                if target.alive
                    && t.distance_sq(target.position) <= 49.0
                    && t.sees(&target.reference) =>
            {
                1
            }
            _ => -1,
        };
        t.mob.body.data.set("swell_dir", Value::Int(dir));
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Creeper.Swell"
    }
}
