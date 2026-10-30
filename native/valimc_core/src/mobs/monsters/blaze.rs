//! Blazes (`Valimc.AI.Mobs.Blaze`, vanilla's `Blaze`): its goals, its
//! height offset and lift toward a target above it (`customServerAiStep`),
//! and its attack (`BlazeAttackGoal`, `Attack`): close by, a melee hit
//! every second; within its follow range and in sight, a volley of three
//! small fireballs after a three-second charge; out of sight, a few ticks'
//! chase. It falls slowly (the kernel scales a falling blaze's motion),
//! burns while charged (its entity data flag) and is always lit for its
//! idle time.
//!
//! Its own mind fields (`BlazeOwn`, the Elixir's `own`): the allowed height
//! offset, the ticks to its next change and whether it is charged, absent
//! until its first step or charge.

use super::entity;
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::f;
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::random_stroll::StrollOptions;
use crate::mobs::ai::goals::target::{self as target_goal, TargetOptions};
use crate::mobs::ai::goals::{
    HurtByTarget, Idle, LookAtPlayer, NearestAttackableTarget, RandomLookAround, RandomStroll,
    TargetKind,
};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, Registered, Registration};
use crate::mobs::model::Body;
use crate::mobs::term::{Atom, Value};

pub const BLAZE: &str = "minecraft:blaze";

/// A blaze's own mind fields.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlazeOwn {
    pub offset: f64,
    pub next_change: i64,
    pub charged: bool,
}

impl Default for BlazeOwn {
    /// `Blaze.own/0`.
    fn default() -> BlazeOwn {
        BlazeOwn {
            offset: 0.5,
            next_change: 0,
            charged: false,
        }
    }
}

fn own(t: &Turn) -> BlazeOwn {
    t.mind.own.family::<BlazeOwn>().copied().unwrap_or_default()
}

fn put(t: &mut Turn, own: BlazeOwn) {
    t.mind.own.family = Some(Box::new(own));
}

/// `setCharged`.
fn charge(t: &mut Turn, charged: bool) {
    put(t, BlazeOwn { charged, ..own(t) });
}

/// `RandomSource.triangle(mode, deviation)` of the mob's random.
pub fn triangle(t: &mut Turn, mode: f64, deviation: f64) -> f64 {
    let a = t.double();
    let b = t.double();
    mode + deviation * (a - b)
}

/// `Vec3.normalize` (`Projectile.normalize/1`): zero below a float 1.0e-5.
pub fn normalize([x, y, z]: [f64; 3]) -> [f64; 3] {
    let d = (x * x + y * y + z * z).sqrt();
    if d < f(1.0e-5) {
        [0.0; 3]
    } else {
        [x / d, y / d, z / d]
    }
}

/// `{:projectile, type, position, velocity, {yaw, pitch}}`: a fireball the
/// owner makes a body of.
pub fn projectile(t: &Turn, name: &str, position: [f64; 3], velocity: [f64; 3]) -> Effect {
    Effect::Projectile(Value::tuple([
        Value::Binary(name.as_bytes().to_vec()),
        Value::vec3(position),
        Value::vec3(velocity),
        Value::tuple([Value::Float(f(t.yaw())), Value::Float(f(t.pitch()))]),
    ]))
}

/// The blaze family.
pub struct Blaze {
    types: [&'static str; 1],
    type_id: u16,
}

impl Blaze {
    pub fn new(facts: &MobFacts) -> Result<Blaze, String> {
        Ok(Blaze {
            types: [BLAZE],
            type_id: entity(facts, BLAZE)?,
        })
    }
}

impl Hooks for Blaze {}

impl Family for Blaze {
    /// Its entity data: the charged flag (bit 0).
    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let charged = body
            .mob
            .ai
            .as_ref()
            .and_then(|m| m.state.as_ref())
            .and_then(|s| s.own.family::<BlazeOwn>())
            .is_some_and(|o| o.charged);
        vec![super::value(
            "blaze_flags",
            Value::Int(charged as i64),
            Value::Int(0),
        )]
    }
}

impl Kind for Blaze {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Blaze"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(4, "BlazeAttackGoal", MOVE | LOOK, Attack::default()),
                Registration::new(
                    5,
                    "MoveTowardsRestrictionGoal",
                    MOVE,
                    Idle::new("MoveTowardsRestrictionGoal"),
                ),
                Registration::new(
                    7,
                    "WaterAvoidingRandomStrollGoal",
                    MOVE,
                    RandomStroll::new(
                        1.0,
                        StrollOptions {
                            water_avoiding: true,
                            probability: 0.0,
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

    /// `customServerAiStep`: every 100 ticks a new height offset
    /// (`triangle(0.5, 6.891)`), and a lift toward a target whose eyes are
    /// higher than its own plus the offset.
    fn custom_step(&self, t: &mut Turn) {
        let mut o = own(t);
        let next = o.next_change - 1;
        if next <= 0 {
            let offset = triangle(t, 0.5, 6.891);
            o.next_change = 100;
            o.offset = f(offset);
        } else {
            o.next_change = next;
        }
        put(t, o);
        if let Some(target) = t.target() {
            if target.eye_y() > t.eye_y() + o.offset && t.can_attack(&target.reference) {
                t.mind.rise = true;
            }
        }
    }
}

/// `Blaze.BlazeAttackGoal` (`Blaze.Attack`), updated every tick: close by
/// (within two blocks) and in sight, a melee hit every 20 ticks while
/// walking at its target; within the follow range and in sight, a volley:
/// charged for 60 ticks, then three small fireballs six ticks apart toward
/// the target with a spread for the distance, then 100 ticks' rest; out of
/// sight, it follows for five ticks. A shot is the blaze's shoot event
/// (1018) and a projectile.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Attack {
    attack_step: i64,
    attack_time: i64,
    last_seen: i64,
}

impl Attack {
    fn attack(&mut self, t: &mut Turn, target: &Seen) {
        let seen = t.sees(&target.reference);
        self.last_seen = if seen { 0 } else { self.last_seen + 1 };
        let distance = t.distance_sq(target.position);
        let follow = target_goal::follow(t);
        if distance < 4.0 {
            if !seen {
                return;
            }
            if self.attack_time <= 0 {
                self.attack_time = 20;
                t.effect(Effect::Attack(target.reference));
            }
            t.move_to(target.position, 1.0);
        } else if distance < follow * follow && seen {
            self.volley(t, target, distance);
            t.look_at([target.x(), target.eye_y(), target.z()], 10.0, 10.0);
        } else if self.last_seen < 5 {
            t.move_to(target.position, 1.0);
        }
    }

    fn volley(&mut self, t: &mut Turn, target: &Seen, distance: f64) {
        if self.attack_time > 0 {
            return;
        }
        let step = self.attack_step + 1;
        if step == 1 {
            self.attack_step = step;
            self.attack_time = 60;
            charge(t, true);
        } else if step <= 4 {
            self.attack_step = step;
            self.attack_time = 6;
        } else {
            self.attack_step = 0;
            self.attack_time = 100;
            charge(t, false);
        }
        if self.attack_step > 1 {
            shoot(t, target, distance);
        }
    }
}

// One small fireball from the blaze's middle, half a block up.
fn shoot(t: &mut Turn, target: &Seen, distance: f64) {
    let xd = target.x() - t.x();
    let yd = target.y() + target.height * 0.5 - (t.y() + t.height * 0.5);
    let zd = target.z() - t.z();
    let spread = distance.sqrt().sqrt() * 0.5;
    let x = triangle(t, xd, 2.297 * spread);
    let z = triangle(t, zd, 2.297 * spread);
    let [dx, dy, dz] = normalize(normalize([x, yd, z]));
    let position = [t.x(), t.y() + t.height * 0.5 + 0.5, t.z()];
    let cell = t.block();
    t.effect(Effect::LevelEvent {
        cell,
        kind: 1018,
        data: 0,
    });
    let effect = projectile(
        t,
        "minecraft:small_fireball",
        position,
        [dx * 0.1, dy * 0.1, dz * 0.1],
    );
    t.effect(effect);
}

impl Goal for Attack {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) if target.alive => t.can_attack(&target.reference),
            _ => false,
        }
    }

    fn start(&mut self, _t: &mut Turn) {
        self.attack_step = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        self.last_seen = 0;
        charge(t, false);
    }

    fn tick(&mut self, t: &mut Turn) {
        self.attack_time -= 1;
        if let Some(target) = t.target() {
            self.attack(t, &target);
        }
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Blaze.Attack"
    }
}
