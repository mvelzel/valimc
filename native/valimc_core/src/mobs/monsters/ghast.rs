//! Ghasts (`Valimc.AI.Mobs.Ghast`, vanilla's `Ghast`): it flies
//! (`travelFlying`, the kernel's `flying`) with its own move control
//! (`GhastMoveControl`, the kernel's `float`), wanders to random places
//! within 16 blocks (`FloatAround`), faces where it drifts or its target
//! (`Look`) and, at a player within 64 blocks it sees, charges for a second
//! and shoots a large fireball (`Shoot`), then rests two seconds. It
//! targets players no more than four blocks above or below it. Its own
//! data: whether it is charging (entity data) and its explosion power. A
//! large fireball a player sent back hurts it for 1000.

use super::blaze::{normalize, projectile};
use super::{fields, flag};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::goal::{Goal, LOOK, MOVE, TARGET};
use crate::mobs::ai::goals::target::TargetOptions;
use crate::mobs::ai::goals::{NearestAttackableTarget, TargetKind, TargetTest};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::combat::{Family, Hit};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, KindMotion, Registered, Registration};
use crate::mobs::model::{Body, FamilyData, FloatControl, TravelKind};
use crate::mobs::sensing;
use crate::mobs::term::{Atom, Value};

pub const GHAST: &str = "minecraft:ghast";

/// The ghast family.
pub struct Ghast {
    types: [&'static str; 1],
}

impl Ghast {
    pub fn new(_facts: &MobFacts) -> Result<Ghast, String> {
        Ok(Ghast { types: [GHAST] })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("charging", Value::bool(false)), ("power", Value::Int(1))])
    }
}

/// Its move control: what it wants and when it next pushes (none before
/// any).
fn float(t: &Turn) -> FloatControl {
    t.mob.body.mob.motion.float.clone().unwrap_or(FloatControl {
        wanted: None,
        duration: 0,
    })
}

/// `MoveControl.setWantedPosition` on a ghast's move control.
fn want(t: &mut Turn, p: [f64; 3]) {
    let mut control = float(t);
    control.wanted = Some(p);
    t.mob.body.mob.motion.float = Some(control);
}

/// `setCharging`.
fn charging(t: &mut Turn, on: bool) {
    t.mob.body.data.set("charging", Value::bool(on));
}

impl Hooks for Ghast {}

impl Family for Ghast {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Ghast::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![super::value(
            "ghast_charging",
            Value::bool(flag(&body.data, "charging")),
            Value::bool(false),
        )]
    }

    /// `hurtServer`: a large fireball a player sent back
    /// (`isReflectedFireball`) hurts for 1000, past its fire immunity.
    fn taken(&self, _body: &Body, hit: &Hit) -> Option<Hit> {
        let reflected = hit
            .direct
            .as_ref()
            .is_some_and(|d| d.entity_type == "minecraft:fireball")
            && hit.attacker.as_ref().is_some_and(|a| a.player);
        reflected.then(|| Hit {
            amount: 1000.0,
            bypass_immunity: true,
            ..hit.clone()
        })
    }
}

impl Kind for Ghast {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Ghast"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(5, "RandomFloatAroundGoal", MOVE, FloatAround),
                Registration::new(7, "GhastLookGoal", LOOK, Look),
                Registration::new(7, "GhastShootFireballGoal", 0, Shoot { charge: 0 }),
            ],
            targets: vec![Registration::new(
                1,
                "NearestAttackableTargetGoal",
                TARGET,
                NearestAttackableTarget::new(
                    TargetKind::Player,
                    None,
                    true,
                    TargetOptions {
                        selector: Some(TargetTest::WithinY(4.0)),
                        ..TargetOptions::default()
                    },
                ),
            )],
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            travel: (TravelKind::Flying, false),
            ..KindMotion::default()
        }
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Ghast::data_of()
    }
}

/// `Ghast.RandomFloatAroundGoal` (`Ghast.FloatAround`): with no place
/// wanted, or one less than a block or more than 60 away, a random place
/// within 16 blocks on each axis (three floats of its random). It runs for
/// one tick.
#[derive(Clone, Debug, PartialEq)]
pub struct FloatAround;

// `center + (nextFloat() * 2 - 1) * 16`, in floats.
fn offset(t: &mut Turn, center: f64) -> f64 {
    let r = t.float();
    center + f(f(f(r * 2.0) - 1.0) * 16.0)
}

impl Goal for FloatAround {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match float(t).wanted {
            None => true,
            Some(w) => {
                let d = t.distance_sq(w);
                !(1.0..=3600.0).contains(&d)
            }
        }
    }

    fn can_continue(&mut self, _t: &mut Turn) -> bool {
        false
    }

    // `getSuitableFlyToPosition(mob, 0)`: with no distance to blocks asked
    // for, the first place is good.
    fn start(&mut self, t: &mut Turn) {
        let [x, y, z] = t.pos();
        let x = offset(t, x);
        let y = offset(t, y);
        let z = offset(t, z);
        want(t, [x, y, z]);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Ghast.FloatAround"
    }
}

/// `Ghast.GhastLookGoal` (`Ghast.Look`), every tick
/// (`faceMovementDirection`): with no target it turns, body too, to where
/// it drifts; with one within 64 blocks it turns toward it.
#[derive(Clone, Debug, PartialEq)]
pub struct Look;

// Its motion as `aiStep` left it before the goals: tiny parts zeroed.
fn dead(v: f64) -> f64 {
    if v.abs() < 0.003 {
        0.0
    } else {
        v
    }
}

// `setYRot(-((float)atan2) * (180F / PI))` and the body with it.
fn face(t: &mut Turn, angle: f64) {
    let yaw = f(-f(angle) * fmath::DEGREES);
    t.mob.body.yaw = yaw;
    t.mind.body_yaw = yaw;
}

impl Goal for Look {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        true
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        match t.target() {
            None => {
                let [vx, _, vz] = t.velocity();
                face(t, fmath::atan2(dead(vx), dead(vz)));
            }
            Some(target) => {
                if t.distance_sq(target.position) < 4096.0 {
                    face(t, fmath::atan2(target.x() - t.x(), target.z() - t.z()));
                }
            }
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Ghast.Look"
    }
}

/// `Ghast.GhastShootFireballGoal` (`Ghast.Shoot`), every tick while it has
/// a target: within 64 blocks and in its sight it charges (the warning
/// event 1015 at ten ticks); at twenty it shoots a large fireball from four
/// blocks before it toward the target's middle (event 1016) and waits forty
/// ticks; out of sight the charge runs down. It shows charging past ten
/// ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct Shoot {
    charge: i64,
}

impl Shoot {
    fn charged(&mut self, t: &mut Turn, target: &Seen) {
        match self.charge {
            10 => {
                let cell = t.block();
                t.effect(Effect::LevelEvent {
                    cell,
                    kind: 1015,
                    data: 0,
                });
            }
            20 => {
                self.charge = -40;
                shoot(t, target);
            }
            _ => {}
        }
    }
}

// `getViewVector(1)`: a living entity looks along its head
// (`calculateViewVector(xRot, yHeadRot)`), in floats.
fn view(t: &Turn) -> [f64; 3] {
    let radians = f(std::f64::consts::PI / 180.0);
    let p = f(t.pitch() * radians);
    let g = f(-t.head() * radians);
    let (h, i) = (fmath::cos(g), fmath::sin(g));
    let (j, k) = (fmath::cos(p), fmath::sin(p));
    [f(i * j), -k, f(h * j)]
}

// A large fireball four blocks before its face, toward the target's middle.
fn shoot(t: &mut Turn, target: &Seen) {
    let [vx, _, vz] = view(t);
    let half = t.y() + t.height * 0.5;
    let xd = target.x() - (t.x() + vx * 4.0);
    let yd = target.y() + target.height * 0.5 - (0.5 + half);
    let zd = target.z() - (t.z() + vz * 4.0);
    let [dx, dy, dz] = normalize(normalize([xd, yd, zd]));
    let position = [t.x() + vx * 4.0, half + 0.5, t.z() + vz * 4.0];
    let cell = t.block();
    t.effect(Effect::LevelEvent {
        cell,
        kind: 1016,
        data: 0,
    });
    let effect = projectile(
        t,
        "minecraft:fireball",
        position,
        [dx * 0.1, dy * 0.1, dz * 0.1],
    );
    t.effect(effect);
}

impl Goal for Shoot {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.target().is_some()
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn start(&mut self, _t: &mut Turn) {
        self.charge = 0;
    }

    fn stop(&mut self, t: &mut Turn) {
        charging(t, false);
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(target) = t.target() else {
            return;
        };
        let seen = t.distance_sq(target.position) < 4096.0 && {
            let (level, sensing, eyes) = t.split();
            sensing
                .entity(&target.reference)
                .is_some_and(|e| sensing::line_of_sight(level, &eyes, e))
        };
        if seen {
            self.charge += 1;
            self.charged(t, &target);
        } else if self.charge > 0 {
            self.charge -= 1;
        }
        charging(t, self.charge > 10);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Ghast.Shoot"
    }
}
