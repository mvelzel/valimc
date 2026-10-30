//! Phantoms (`Valimc.AI.Mobs.Phantom`, vanilla's `Phantom`):
//!
//! - It flies (`travelFlying`, the kernel's `flying`; no input) where its
//!   own move control (`PhantomMoveControl`) steers it: turning at most four
//!   degrees a tick toward its move target, speeding up to 1.8 while it
//!   flies straight and slowing to 0.2 while it turns, its pitch toward the
//!   target, its motion easing a fifth of the way to that each tick; a wall
//!   turns it around. Its body faces its yaw and its head its last body
//!   (`PhantomBodyRotationControl`); it looks nowhere else.
//! - **Goals**: its attack strategy (circle above the target for a while,
//!   then swoop, with the swoop sound, then circle again), the swoop (at
//!   the target's middle; touching it, it bites and circles again; a wall
//!   or a hurt breaks it off; creative and spectating players and cats end
//!   it) and circling its anchor (at 5 to 15 blocks and a height that change
//!   now and then, away from blocks above and below); as target the highest
//!   player it may attack within 16 blocks around and 64 up and down, looked
//!   for every 30 updates (`Hunt`).
//! - Its own data: its size (its box, entity data), anchor, move target
//!   (`point`), phase and speed, and its tick count. It never lands.

use super::{fields, int};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, emax, emin, f, floor, reduced};
use crate::mobs::ai::goal::{Goal, MOVE};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::spawn;
use crate::mobs::ai::turn::{Kinds, Seen, Targeting, Turn};
use crate::mobs::combat::Family;
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Kind, KindMotion, Registered, Registration};
use crate::mobs::model::{Body, FamilyData, Impulse, TravelKind};
use crate::mobs::sensing::{inflate, intersects, GameMode};
use crate::mobs::term::{Atom, Value, NIL};

pub const PHANTOM: &str = "minecraft:phantom";

/// The phantom family.
pub struct Phantom {
    types: [&'static str; 1],
    cat: u16,
    /// Its type's `[width, height, eye height]`.
    dimensions: [f32; 3],
    swoop: i32,
}

impl Phantom {
    pub fn new(facts: &MobFacts) -> Result<Phantom, String> {
        let id = super::entity(facts, PHANTOM)?;
        let e = facts.entities.get(id).ok_or("no phantom")?;
        Ok(Phantom {
            types: [PHANTOM],
            cat: super::entity(facts, "minecraft:cat")?,
            dimensions: [e.width as f32, e.height as f32, e.eye_height as f32],
            swoop: super::sound(facts, "minecraft:entity.phantom.swoop")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[
            ("size", Value::Int(0)),
            ("anchor", NIL),
            ("point", Value::vec3([0.0; 3])),
            ("phase", Value::atom("circle")),
            ("speed", Value::Float(f(0.1))),
            ("ticks", Value::Int(0)),
        ])
    }
}

// ## Its data

fn anchor(data: &FamilyData) -> Option<[i32; 3]> {
    let [x, y, z] = data.get("anchor")?.as_ivec3()?;
    Some([x as i32, y as i32, z as i32])
}

fn set_anchor(t: &mut Turn, anchor: [i32; 3]) {
    t.mob
        .body
        .data
        .set("anchor", Value::ivec3(anchor.map(i64::from)));
}

fn point(data: &FamilyData) -> [f64; 3] {
    data.get("point")
        .and_then(Value::as_vec3)
        .unwrap_or([0.0; 3])
}

fn set_point(t: &mut Turn, point: [f64; 3]) {
    t.mob.body.data.set("point", Value::vec3(point));
}

fn swooping(data: &FamilyData) -> bool {
    data.get("phase").is_some_and(|p| p.is_atom("swoop"))
}

fn set_phase(t: &mut Turn, swoop: bool) {
    let phase = if swoop { "swoop" } else { "circle" };
    t.mob.body.data.set("phase", Value::atom(phase));
}

fn speed(data: &FamilyData) -> f64 {
    data.get("speed").and_then(Value::as_float).unwrap_or(0.0)
}

/// Whether it may attack `target` (`TargetingConditions.DEFAULT`).
fn attackable(t: &mut Turn, target: &Seen) -> bool {
    t.test(&target.reference, &Targeting::new(true))
}

/// `setAnchorAboveTarget`: 20 to 39 blocks above its target, at least
/// above sea level.
fn anchor_above_target(t: &mut Turn) {
    if anchor(t.data()).is_none() {
        return;
    }
    let Some(target) = t.target() else { return };
    let n = t.int(20);
    let y = floor(target.y()) + 20 + n;
    let sea = t.level.sea_level;
    let y = if y < sea { sea + 1 } else { y };
    set_anchor(t, [floor(target.x()), y, floor(target.z())]);
}

// `Mth.approach` and `Mth.approachDegrees` of floats.
fn approach(current: f64, target: f64, increment: f64) -> f64 {
    let increment = increment.abs();
    if current < target {
        fmath::clamp(f(current + increment), current, target)
    } else {
        fmath::clamp(f(current - increment), target, current)
    }
}

fn approach_degrees(current: f64, target: f64, increment: f64) -> f64 {
    approach(
        current,
        f(current + fmath::difference(current, target)),
        increment,
    )
}

fn dead(v: f64) -> f64 {
    if v.abs() < 0.003 {
        0.0
    } else {
        v
    }
}

impl Hooks for Phantom {
    fn turns_body(&self, _type_id: u16) -> bool {
        false
    }

    /// `PhantomLookControl.tick` does nothing.
    fn looks(&self, _type_id: u16) -> bool {
        false
    }
}

impl Family for Phantom {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Phantom::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        vec![super::value(
            "phantom_size",
            Value::Int(int(&body.data, "size")),
            Value::Int(0),
        )]
    }

    /// `getDefaultDimensions`: its type's scaled by `1 + 0.15 * size`.
    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        let size = int(&body.data, "size") as f32;
        let scale = 1.0 + 0.15f32 * size;
        Some(self.dimensions.map(|d| d * scale))
    }
}

impl Kind for Phantom {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Phantom"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(
                    1,
                    "PhantomAttackStrategyGoal",
                    0,
                    Strategy {
                        next_sweep: 0,
                        swoop: self.swoop,
                    },
                ),
                Registration::new(
                    2,
                    "PhantomSweepAttackGoal",
                    MOVE,
                    Sweep {
                        scared: false,
                        cat_search: 0,
                        cat: self.cat,
                    },
                ),
                Registration::new(3, "PhantomCircleAroundAnchorGoal", MOVE, Circle::default()),
            ],
            targets: vec![Registration::new(
                1,
                "PhantomAttackPlayerTargetGoal",
                0,
                Hunt {
                    next_scan: reduced(20),
                },
            )],
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            travel: (TravelKind::Flying, false),
            ..KindMotion::default()
        }
    }

    fn falls(&self) -> bool {
        false
    }

    /// `finalizeSpawn`: its anchor five blocks above it, size 0, then a
    /// mob's.
    fn finalize(&self, t: &mut Turn, reason: &Atom) {
        let [x, y, z] = t.block();
        set_anchor(t, [x, y + 5, z]);
        t.mob.body.data.set("size", Value::Int(0));
        spawn::mob(t, reason);
    }

    /// Its own tick count (`tickCount`, the cat search).
    fn tick_start(&self, t: &mut Turn) {
        let ticks = int(t.data(), "ticks") + 1;
        t.mob.body.data.set("ticks", Value::Int(ticks));
    }

    /// `PhantomBodyRotationControl`: its head faces its last body, its body
    /// its yaw.
    fn after_tick(&self, t: &mut Turn) {
        t.mob.body.head_yaw = t.mind.body_yaw;
        t.mind.body_yaw = t.yaw();
    }

    /// `PhantomMoveControl.tick`.
    fn move_control(&self, t: &mut Turn) {
        let mut speed = speed(t.data());
        if t.mob.body.mob.motion.horizontal_collision {
            t.mob.body.yaw = f(t.yaw() + 180.0);
            speed = f(0.1);
        }
        let [px, py, pz] = point(t.data());
        let (mut tdx, tdy, mut tdz) = (px - t.x(), py - t.y(), pz - t.z());
        let sd = (tdx * tdx + tdz * tdz).sqrt();
        if sd.abs() <= f(1.0e-5) {
            t.mob.body.data.set("speed", Value::Float(speed));
            return;
        }
        let scale = 1.0 - (tdy * f(0.7)).abs() / sd;
        tdx *= scale;
        tdz *= scale;
        let sd = (tdx * tdx + tdz * tdz).sqrt();
        let sd2 = (tdx * tdx + tdz * tdz + tdy * tdy).sqrt();
        let previous = t.yaw();
        let angle = f(fmath::atan2(tdz, tdx));
        let degrees = f(180.0 / f(std::f64::consts::PI));
        let a = fmath::wrap(f(previous + 90.0));
        let b = fmath::wrap(f(angle * degrees));
        let yaw = f(approach_degrees(a, b, 4.0) - 90.0);
        t.mob.body.yaw = yaw;
        t.mind.body_yaw = yaw;
        let speed = if fmath::difference(previous, yaw).abs() < 3.0 {
            approach(speed, f(1.8), f(f(0.005) * f(f(1.8) / speed)))
        } else {
            approach(speed, f(0.2), f(0.025))
        };
        let pitch = f(-(fmath::atan2(-tdy, sd) * fmath::DEGREES));
        let radians = f(std::f64::consts::PI / 180.0);
        let turn = f(yaw + 90.0);
        let cos = fmath::cos(f(turn * radians));
        let sin = fmath::sin(f(turn * radians));
        let psin = fmath::sin(f(pitch * radians));
        let txd = f(speed * cos) * (tdx / sd2).abs();
        let tzd = f(speed * sin) * (tdz / sd2).abs();
        let tyd = f(speed * psin) * (tdy / sd2).abs();
        // Its motion after `aiStep`'s dead zone, eased a fifth of the way
        // (the kernel adds it after the dead zone).
        let [vx, vy, vz] = t.velocity().map(dead);
        t.mob.body.mob.motion.impulse =
            Impulse::One([(txd - vx) * 0.2, (tyd - vy) * 0.2, (tzd - vz) * 0.2]);
        t.mob.body.pitch = pitch;
        t.mob.body.data.set("speed", Value::Float(speed));
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Phantom::data_of()
    }
}

// ## Goals

/// `PhantomAttackPlayerTargetGoal` (`Phantom.Hunt`): every 30 updates (the
/// first after 10) the players within 16 blocks around and 64 up and down
/// that it may attack within 64 blocks, highest first; the first it may
/// attack becomes its target. It keeps one it may still attack.
#[derive(Clone, Debug, PartialEq)]
pub struct Hunt {
    next_scan: i64,
}

impl Goal for Hunt {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        if self.next_scan > 0 {
            self.next_scan -= 1;
            return false;
        }
        self.next_scan = reduced(60);
        let b = inflate(&t.bbox(), 16.0, 64.0, 16.0);
        let conditions = Targeting::new(true).range(64.0);
        let players: Vec<Seen> = t
            .sensing
            .players
            .iter()
            .map(|p| Seen::of(crate::mobs::sensing::Entity::Player(p)))
            .collect();
        let mut near = Vec::new();
        for p in players {
            if intersects(&p.bbox, &b) && t.test(&p.reference, &conditions) {
                near.push(p);
            }
        }
        // `Enum.sort_by(& &1.y, :desc)`: stable, highest first.
        near.sort_by(|a, b| b.y().total_cmp(&a.y()));
        for p in near {
            if attackable(t, &p) {
                t.set_target(Some(p.reference));
                return true;
            }
        }
        false
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) => attackable(t, &target),
            None => false,
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Phantom.Hunt"
    }
}

/// `PhantomAttackStrategyGoal` (`Phantom.Strategy`): while it may attack
/// its target it circles above it for five updates at first, then swoops
/// (its anchor moved above the target, the swoop sound) and circles again
/// for 80 to 110 updates; when it stops, its anchor rises 10 to 29 blocks
/// over the ground there.
#[derive(Clone, Debug, PartialEq)]
pub struct Strategy {
    next_sweep: i64,
    swoop: i32,
}

impl Goal for Strategy {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match t.target() {
            Some(target) => attackable(t, &target),
            None => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        set_phase(t, false);
        anchor_above_target(t);
        self.next_sweep = reduced(10);
    }

    fn stop(&mut self, t: &mut Turn) {
        let Some([x, _, z]) = anchor(t.data()) else {
            return;
        };
        let n = t.int(20);
        let ground = t.level.motion_blocking(x, z);
        set_anchor(t, [x, ground + 10 + n, z]);
    }

    fn tick(&mut self, t: &mut Turn) {
        if swooping(t.data()) {
            return;
        }
        let n = self.next_sweep - 1;
        if n > 0 {
            self.next_sweep = n;
            return;
        }
        set_phase(t, true);
        anchor_above_target(t);
        let k = t.int(4) as i64;
        let r = t.float();
        let pitch = f(f(0.95) + f(r * f(0.1)));
        t.sound_id(self.swoop, 10.0, pitch);
        self.next_sweep = reduced((8 + k) * 20);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Phantom.Strategy"
    }
}

/// `PhantomSweepAttackGoal` (`Phantom.Sweep`): swooping at its target's
/// middle; touching it (its box grown by 0.2) it bites (level event 1039)
/// and circles again, as it does after hitting a wall or being hurt. A
/// creative or spectating target, or a cat within 16 blocks (looked for
/// each second), ends it, and its target with it.
#[derive(Clone, Debug, PartialEq)]
pub struct Sweep {
    scared: bool,
    cat_search: i64,
    cat: u16,
}

impl Goal for Sweep {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.target().is_some() && swooping(t.data())
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        let Some(target) = t.target() else {
            return false;
        };
        if !target.alive
            || matches!(target.mode, Some(GameMode::Creative | GameMode::Spectator))
            || !swooping(t.data())
        {
            return false;
        }
        let ticks = int(t.data(), "ticks");
        if ticks > self.cat_search {
            let b = inflate(&t.bbox(), 16.0, 16.0, 16.0);
            let cats = t.mobs_in(Kinds::Types(&[self.cat]), &b);
            self.cat_search = ticks + 20;
            self.scared = !cats.is_empty();
        }
        !self.scared
    }

    fn stop(&mut self, t: &mut Turn) {
        t.set_target(None);
        set_phase(t, false);
    }

    fn tick(&mut self, t: &mut Turn) {
        let Some(target) = t.target() else { return };
        set_point(
            t,
            [target.x(), target.y() + target.height * 0.5, target.z()],
        );
        if intersects(&inflate(&t.bbox(), 0.2, 0.2, 0.2), &target.bbox) {
            t.effect(Effect::Attack(target.reference));
            let cell = t.block();
            t.effect(Effect::LevelEvent {
                cell,
                kind: 1039,
                data: 0,
            });
            set_phase(t, false);
        } else if t.mob.body.mob.motion.horizontal_collision
            || t.mob.body.mob.living.health.hurt_ticks > 0
        {
            set_phase(t, false);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Phantom.Sweep"
    }
}

/// `PhantomCircleAroundAnchorGoal` (`Phantom.Circle`): with no target, or
/// circling, it flies round its anchor: a distance of 5 to 15 blocks, a
/// height of -4 to 5 and a direction drawn as it starts; now and then a new
/// height, a step farther out (back to 5 and turning past 15) or a new
/// angle; each new move target 15 degrees on, and sooner when it reaches
/// one or a block above or below is in its way.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Circle {
    angle: f64,
    distance: f64,
    height: f64,
    clockwise: f64,
}

impl Circle {
    /// `selectNext`: the anchor its block if it has none, 15 degrees on.
    fn select(&mut self, t: &mut Turn) {
        let anchor = anchor(t.data()).unwrap_or_else(|| t.block());
        let step = f(f(15.0) * f(std::f64::consts::PI / 180.0));
        let angle = f(self.angle + f(self.clockwise * step));
        let [ax, ay, az] = anchor;
        let (cos, sin) = (fmath::cos(angle), fmath::sin(angle));
        let point = [
            ax as f64 + f(self.distance * cos),
            ay as f64 + f(-4.0 + self.height),
            az as f64 + f(self.distance * sin),
        ];
        self.angle = angle;
        set_anchor(t, anchor);
        set_point(t, point);
    }

    fn touching(t: &Turn) -> bool {
        let [px, py, pz] = point(t.data());
        let d = [px - t.x(), py - t.y(), pz - t.z()];
        d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 4.0
    }
}

impl Goal for Circle {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        t.target().is_none() || !swooping(t.data())
    }

    fn start(&mut self, t: &mut Turn) {
        let a = t.float();
        let b = t.float();
        let c = t.boolean();
        self.distance = f(5.0 + f(a * 10.0));
        self.height = f(-4.0 + f(b * 9.0));
        self.clockwise = if c { 1.0 } else { -1.0 };
        self.select(t);
    }

    fn tick(&mut self, t: &mut Turn) {
        if t.int(reduced(350) as i32) == 0 {
            let r = t.float();
            self.height = f(-4.0 + f(r * 9.0));
        }
        if t.int(reduced(250) as i32) == 0 {
            let distance = f(self.distance + 1.0);
            if distance > 15.0 {
                self.distance = 5.0;
                self.clockwise = -self.clockwise;
            } else {
                self.distance = distance;
            }
        }
        if t.int(reduced(450) as i32) == 0 {
            let r = t.float();
            self.angle = f(f(r * 2.0) * f(std::f64::consts::PI));
            self.select(t);
        }
        if Circle::touching(t) {
            self.select(t);
        }
        let [x, y, z] = t.block();
        if point(t.data())[1] < t.y() && !t.level.air([x, y - 1, z]) {
            self.height = emax(1.0, self.height);
            self.select(t);
        }
        if point(t.data())[1] > t.y() && !t.level.air([x, y + 1, z]) {
            self.height = emin(-1.0, self.height);
            self.select(t);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Phantom.Circle"
    }
}
