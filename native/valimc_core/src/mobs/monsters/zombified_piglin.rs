//! Zombified piglins (`Valimc.AI.Mobs.ZombifiedPiglin`, vanilla's
//! `ZombifiedPiglin`): a zombie's goals and spawn with a neutral mob's
//! anger.
//!
//! - **Goals** are a zombie's without the village goal; as targets whoever
//!   hurt it (its kind around joins), a player it is angry with (or any
//!   while universally angry), and universal anger's reset.
//! - **Anger** (`NeutralMob`, 20 to 39 seconds): angry, it walks faster
//!   (the `attacking` speed modifier) and growls once, 0 to 20 ticks after
//!   it first found a target; with a target it alerts its kind around that
//!   have none every four to six seconds while it sees its own.
//! - **Spawning** is a zombie's with a golden sword (one time in twenty a
//!   golden spear), no armour and no reinforcements.
//!
//! Its own mind fields (`PiglinOwn`) beside its anger: the ticks to its
//! first growl and to its next alert. Each is absent until set, as the
//! Elixir's `own` map keys are.

use super::zombie::{Parts, ZOMBIE};
use super::{entity, item};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::{self as target_goal, TargetOptions};
use crate::mobs::ai::goals::{
    neutral, HurtByTarget, Idle, MeleeAttack, NearestAttackableTarget, RandomStroll,
    ResetUniversalAnger, TargetKind, TargetTest,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::mind::Anger;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Kinds, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::model::{Body, FamilyData, Number, Slot};
use crate::mobs::sensing::Ref;
use crate::mobs::term::{Atom, Value};
use crate::physics::Aabb;

pub const ZOMBIFIED_PIGLIN: &str = "minecraft:zombified_piglin";

/// `PERSISTENT_ANGER_TIME`: 20 to 39 seconds.
const ANGER: (i64, i64) = (400, 780);
const SPEED: &str = "minecraft:movement_speed";
const ATTACKING: &str = "minecraft:attacking";

/// A zombified piglin's own mind fields beside its anger.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PiglinOwn {
    pub first_sound: Option<i64>,
    pub next_alert: Option<i64>,
}

/// The zombified piglin family.
pub struct ZombifiedPiglin {
    types: [&'static str; 1],
    type_id: u16,
    zombie: u16,
    parts: Parts,
    golden_sword: i32,
    golden_spear: i32,
    angry: i32,
    /// `HostileFacts.baby/1`.
    baby: Option<[f32; 3]>,
}

impl ZombifiedPiglin {
    pub fn new(facts: &MobFacts) -> Result<ZombifiedPiglin, String> {
        let type_id = entity(facts, ZOMBIFIED_PIGLIN)?;
        Ok(ZombifiedPiglin {
            types: [ZOMBIFIED_PIGLIN],
            type_id,
            baby: facts.hostile.babies.get(&type_id).copied(),
            zombie: entity(facts, ZOMBIE)?,
            parts: Parts::new(facts)?,
            golden_sword: item(facts, "minecraft:golden_sword")?,
            golden_spear: item(facts, "minecraft:golden_spear")?,
            angry: super::sound(facts, "minecraft:entity.zombified_piglin.angry")?,
        })
    }

    // `populateDefaultEquipmentSlots`: a golden sword, one time in twenty a
    // golden spear, from the level's random.
    fn golden(&self, t: &mut Turn) {
        let n = spawn::level_int(t, 20);
        let item = if n == 0 {
            self.golden_spear
        } else {
            self.golden_sword
        };
        spawn::equip(t, Slot::Mainhand, Some(super::stack(item)));
    }

    // `growl/1` (`maybePlayFirstAngerSound`): twice as loud, pitched up 1.8
    // times.
    fn growl(&self, t: &mut Turn) {
        let Some(n) = own(t).first_sound.filter(|&n| n > 0) else {
            return;
        };
        put(t, |o| o.first_sound = Some(n - 1));
        if n - 1 == 0 {
            let pitch = t.random.voice_pitch(1.0) as f64;
            let volume = f(t.facts.volume * 2.0);
            t.sound_id(self.angry, volume, f(pitch * f(1.8)));
        }
    }

    // `maybeAlertOthers`.
    fn maybe_alert(&self, t: &mut Turn) {
        if let Some(n) = own(t).next_alert.filter(|&n| n > 0) {
            put(t, |o| o.next_alert = Some(n - 1));
            return;
        }
        if let Some(target) = t.target() {
            if t.sees(&target.reference) {
                self.alert_others(t, target.reference);
            }
        }
        let n = t.int(41) as i64;
        put(t, |o| o.next_alert = Some(80 + n));
    }

    // `alertOthers`: its kind within its follow range (ten blocks up and
    // down) that have no target take its own.
    fn alert_others(&self, t: &mut Turn, target: Ref) {
        let within = target_goal::follow(t);
        let [x, y, z] = t.pos();
        let b = Aabb {
            min: [x - within, y - 10.0, z - within],
            max: [x + 1.0 + within, y + 1.0 + 10.0, z + 1.0 + within],
        };
        for other in t.mobs_in(Kinds::Types(&[self.type_id]), &b) {
            if other.uuid() != t.uuid && t.entity(other.target.as_ref()).is_none() {
                t.effect(Effect::Alert {
                    mob: other.uuid(),
                    target,
                });
            }
        }
    }
}

fn own(t: &Turn) -> PiglinOwn {
    t.mind
        .own
        .family::<PiglinOwn>()
        .cloned()
        .unwrap_or_default()
}

fn put(t: &mut Turn, f: impl FnOnce(&mut PiglinOwn)) {
    let mut o = own(t);
    f(&mut o);
    t.mind.own.family = Some(Box::new(o));
}

/// `ensure/1`: a fresh mind's own fields, the neutral ones with its own.
fn ensure(t: &mut Turn) {
    if t.mind.own.is_empty() {
        t.mind.own.anger = Some(Anger::default());
        t.mind.own.family = Some(Box::new(PiglinOwn {
            first_sound: Some(0),
            next_alert: Some(0),
        }));
    }
}

/// The `attacking` modifier's +0.05 movement speed on or off.
fn modify(t: &mut Turn, on: bool) {
    let add = on.then_some((Number::Float(0.05), 0));
    t.mob.body.mob.attributes.toggle(SPEED, ATTACKING, add);
}

fn attacking(t: &Turn) -> bool {
    t.mob
        .body
        .mob
        .attributes
        .get(SPEED)
        .is_some_and(|o| o.modifiers.iter().any(|m| m.id == ATTACKING))
}

impl Hooks for ZombifiedPiglin {
    /// `setTarget`: a first target draws the delays to its first growl (0
    /// to 20 ticks) and its first alert (80 to 120).
    fn set_target(&self, t: &mut Turn, target: Option<Ref>) -> bool {
        ensure(t);
        if target.is_some() && t.target().is_none() {
            let sound = t.int(21) as i64;
            let alert = t.int(41) as i64;
            put(t, |o| {
                o.first_sound = Some(sound);
                o.next_alert = Some(80 + alert);
            });
        }
        t.put_target(target);
        true
    }
}

impl Family for ZombifiedPiglin {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(self.parts.data(self.zombie)).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        self.parts.values(self.type_id, &body.data)
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        if !super::flag(&body.data, "baby") {
            return None;
        }
        self.baby
    }
}

impl Kind for ZombifiedPiglin {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.ZombifiedPiglin"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        let mut goals = self.parts.common_goals();
        goals.extend([
            Registration::new(1, "SpearUseGoal", MOVE | LOOK, Idle::new("SpearUseGoal")),
            Registration::new(
                2,
                "ZombieAttackGoal",
                MOVE | LOOK,
                MeleeAttack::new(1.0, false, true),
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
                    TargetOptions {
                        selector: Some(TargetTest::AngryAt),
                        ..TargetOptions::default()
                    },
                ),
            ),
            Registration::new(
                3,
                "ResetUniversalAngerTargetGoal",
                0,
                ResetUniversalAnger::new(ANGER),
            ),
        ];
        Registered { goals, targets }
    }

    /// A zombie's `finalizeSpawn` with its golden weapon and no
    /// reinforcements.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        self.parts.finalize(t, reason, |_, t| self.golden(t), false);
    }

    /// `customServerAiStep`: the attacking speed while angry and its first
    /// growl, the anger kept up (staying angry while it has a target), and
    /// alerts while it has a target.
    fn custom_step(&self, t: &mut Turn) {
        ensure(t);
        let modified = attacking(t);
        if neutral::angry(t) {
            if !modified {
                modify(t, true);
            }
            self.growl(t);
        } else if modified {
            modify(t, false);
        }
        neutral::update(t, true, ANGER);
        if t.target().is_some() {
            self.maybe_alert(t);
        }
    }

    /// `getAmbientSound`: angry or not.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if neutral::angry(t) {
            return Some(self.angry);
        }
        let name = t.facts.ambient_sound.as_deref()?;
        t.level.facts.sounds.id(name)
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        self.parts.data(self.zombie)
    }
}
