//! Squid and glow squid (`Valimc.AI.Mobs.Squid`, vanilla's `Squid` and
//! `GlowSquid`).
//!
//! A squid moves only by its motion: its tentacles beat on a cycle, and
//! late in each stroke in water it takes its movement vector (a random
//! heading from `RandomMovement`, or away from what hurt it, `Flee`),
//! otherwise slowing by a tenth; its body turns toward its motion. Out of
//! water it falls and drifts only down, and loses air as a fish does. Hurt
//! by a living thing it squirts ink (its squirt sound, thirty ink particles
//! drawn from its random). A glow squid darkens for five seconds when hurt
//! and draws its glow particle's place every tick.
//!
//! Its tentacle cycle, rotations and movement vector are its own state
//! (`SquidOwn`, unsaved as vanilla's); a fresh one's tentacle speed is
//! drawn as vanilla's constructor draws it, after `random.setSeed(id)`.

use super::{entity, fields, int, value};
use crate::mobs::ai::fmath::{self, emax, emin, f, reduced};
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::Turn;
use crate::mobs::animals::{age, ageable, settle_ageable};
use crate::mobs::combat::{Event, Family, Hit, SoundRef};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered, Registration};
use crate::mobs::level::{FluidKind, AIR};
use crate::mobs::model::{Body, FamilyData, TravelKind};
use crate::mobs::random::LegacyRandom;
use crate::mobs::term::{Atom, Value};

pub const SQUID: &str = "minecraft:squid";
pub const GLOW_SQUID: &str = "minecraft:glow_squid";

const PI: f64 = std::f32::consts::PI as f64;
const TWO_PI: f64 = (std::f64::consts::PI * 2.0) as f32 as f64;
const DEG: f64 = 57.2957763671875;

/// A squid's own state: the tentacle cycle, rotations and movement vector,
/// and whether it was in water as its tick began.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SquidOwn {
    pub tentacle: f64,
    pub tentacle_speed: f64,
    pub rotate_speed: f64,
    pub x_rot: f64,
    pub z_rot: f64,
    pub movement: [f64; 3],
    pub in_water: bool,
}

impl SquidOwn {
    /// A fresh one of the squid with network id `id`.
    pub fn fresh(id: i32) -> SquidOwn {
        let r = LegacyRandom::new(id as i64).float() as f64;
        SquidOwn {
            tentacle: 0.0,
            tentacle_speed: f(f(1.0 / f(r + 1.0)) * f(0.2)),
            rotate_speed: 0.0,
            x_rot: 0.0,
            z_rot: 0.0,
            movement: [0.0; 3],
            in_water: false,
        }
    }
}

/// Its own state (`Squid.own/2`).
fn own(t: &Turn) -> SquidOwn {
    t.mind
        .own
        .family::<SquidOwn>()
        .copied()
        .unwrap_or_else(|| SquidOwn::fresh(t.id))
}

fn put(t: &mut Turn, o: SquidOwn) {
    t.mind.own.family = Some(Box::new(o));
}

/// `hasMovementVector`.
fn moving([x, y, z]: [f64; 3]) -> bool {
    x * x + y * y + z * z > f(1.0e-5)
}

/// The squid family.
pub struct Squid {
    types: [&'static str; 2],
    glow: u16,
    babies: [(u16, [f32; 3]); 2],
    /// `(type, squirt sound, ink particle, volume)`.
    squirts: [(u16, i32, &'static str, f64); 2],
    neutral: i32,
    levitation: i32,
}

impl Squid {
    pub fn new(facts: &MobFacts) -> Result<Squid, String> {
        let squid = entity(facts, SQUID)?;
        let glow = entity(facts, GLOW_SQUID)?;
        let baby = |id| {
            facts
                .animal
                .water_ageable
                .get(&id)
                .map(|(_, dims)| (id, *dims))
                .ok_or("no water ageable facts for a squid")
        };
        let volume = |id| facts.ai.mob(id).map_or(1.0, |m| m.volume);
        Ok(Squid {
            types: [SQUID, GLOW_SQUID],
            glow,
            babies: [baby(squid)?, baby(glow)?],
            squirts: [
                (
                    squid,
                    super::sound(facts, "minecraft:entity.squid.squirt")?,
                    "minecraft:squid_ink",
                    volume(squid),
                ),
                (
                    glow,
                    super::sound(facts, "minecraft:entity.glow_squid.squirt")?,
                    "minecraft:glow_squid_ink",
                    volume(glow),
                ),
            ],
            neutral: facts.sounds.source("neutral").ok_or("no neutral source")?,
            levitation: super::effect(facts, "minecraft:levitation")?,
        })
    }

    fn data_of(&self, type_id: u16) -> Vec<(Atom, Value)> {
        // `AgeableWaterCreature`'s fields: an animal's without love.
        let mut data = ageable();
        data.truncate(3);
        if type_id == self.glow {
            data.extend(fields(&[("dark", Value::Int(0))]));
        }
        data
    }

    fn type_of(&self, body: &Body) -> u16 {
        if body.entity_type == GLOW_SQUID {
            self.glow
        } else {
            self.squirts[0].0
        }
    }

    /// `Squid.aiStep` after its super (and `AgeableMob`'s ageing): the
    /// tentacle cycle, the stroke's motion, the body's turn; a glow squid's
    /// dark ticks and glow particle draws.
    fn after_ai(&self, t: &mut Turn) {
        settle_ageable(t);
        let mut o = own(t);
        let mut tentacle = f(o.tentacle + o.tentacle_speed);
        let mut speed = o.tentacle_speed;
        if tentacle > std::f64::consts::PI * 2.0 {
            tentacle = f(tentacle - TWO_PI);
            if t.int(10) == 0 {
                let r = t.float();
                speed = f(f(1.0 / f(r + 1.0)) * f(0.2));
            }
            t.effect(crate::mobs::ai::effect::Effect::Event(19));
        }
        o.tentacle = tentacle;
        o.tentacle_speed = speed;
        if o.in_water {
            self.stroke(t, &mut o);
        } else {
            self.fall(t, &mut o);
        }
        put(t, o);
        if t.type_id == self.glow {
            glow(t);
        }
    }

    fn stroke(&self, t: &mut Turn, o: &mut SquidOwn) {
        if o.tentacle < PI {
            let scale = f(o.tentacle / PI);
            if scale > 0.75 {
                o.rotate_speed = 1.0;
                t.mob.body.velocity = o.movement;
            } else {
                o.rotate_speed = f(o.rotate_speed * f(0.8));
            }
        } else {
            o.rotate_speed = f(o.rotate_speed * f(0.99));
            let [vx, vy, vz] = t.velocity();
            t.mob.body.velocity = [vx * 0.9, vy * 0.9, vz * 0.9];
        }
        let [mx, my, mz] = t.velocity();
        let horizontal = (mx * mx + mz * mz).sqrt();
        let body = t.mind.body_yaw;
        let turn = f(f(-f(fmath::atan2(mx, mz)) * f(DEG)) - body);
        let body = f(body + f(turn * f(0.1)));
        o.z_rot = f(o.z_rot + f(f(PI * o.rotate_speed) * f(1.5)));
        let pitch = f(f(-f(fmath::atan2(horizontal, my)) * f(DEG)) - o.x_rot);
        o.x_rot = f(o.x_rot + f(pitch * f(0.1)));
        t.mob.body.yaw = body;
        t.mind.body_yaw = body;
    }

    // Out of water it only falls (or rises with Levitation), by its air drag.
    fn fall(&self, t: &mut Turn, o: &mut SquidOwn) {
        let vy = t.velocity()[1];
        let levitation = t.mob.body.mob.living.effects.amplifier(self.levitation);
        let yd = match levitation {
            Some(a) => 0.05 * (a as f64 + 1.0),
            None => vy - t.attribute("minecraft:gravity"),
        };
        let modifier = t.attribute("minecraft:air_drag_modifier");
        let drag = f(emin(
            1.0,
            emax(0.0, f(1.0 - f(f(1.0 - f(0.98)) * f(modifier)))),
        ));
        o.x_rot = f(o.x_rot + f(f(-90.0 - o.x_rot) * f(0.02)));
        t.mob.body.velocity = [0.0, yd * drag, 0.0];
    }
}

// `GlowSquid.aiStep`: its dark ticks run out; its glow particle's place is
// drawn (`getRandomX`, `getRandomY`, `getRandomZ`) though the server shows
// nothing.
fn glow(t: &mut Turn) {
    let dark = int(t.data(), "dark");
    if dark > 0 {
        t.mob.body.data.set("dark", Value::Int(dark - 1));
    }
    t.double();
    t.double();
    t.double();
}

// `rotateVector`: about x by its body pitch, then y by its body yaw.
fn rotation(x_rot: f64, body_yaw: f64) -> impl Fn([f64; 3]) -> [f64; 3] {
    let (xs, xc) = (
        (x_rot * std::f64::consts::PI / 180.0).sin(),
        (x_rot * std::f64::consts::PI / 180.0).cos(),
    );
    let (ys, yc) = (
        (-body_yaw * std::f64::consts::PI / 180.0).sin(),
        (-body_yaw * std::f64::consts::PI / 180.0).cos(),
    );
    move |[x, y, z]| {
        let (y1, z1) = (y * xc + z * xs, z * xc - y * xs);
        [x * yc + z1 * ys, y1, z1 * yc - x * ys]
    }
}

impl Hooks for Squid {
    fn voice(&self, _type_id: u16, data: &FamilyData) -> f32 {
        if age(data) < 0 {
            1.5
        } else {
            1.0
        }
    }
}

impl Family for Squid {
    fn data(&self, type_id: u16) -> FamilyData {
        FamilyData::new(self.data_of(type_id)).unwrap_or_else(FamilyData::empty)
    }

    fn own_air(&self) -> bool {
        true
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let data = &body.data;
        let mut values = vec![
            value(
                "ageable_baby",
                Value::bool(age(data) < 0),
                Value::bool(false),
            ),
            value(
                "age_locked",
                Value::bool(data.age_locked().unwrap_or(false)),
                Value::bool(false),
            ),
        ];
        if body.entity_type == GLOW_SQUID {
            values.push(value(
                "glow_squid_dark_ticks",
                Value::Int(int(data, "dark")),
                Value::Int(0),
            ));
        }
        values
    }

    fn dimensions(&self, body: &Body) -> Option<[f32; 3]> {
        if age(&body.data) >= 0 {
            return None;
        }
        let ty = self.type_of(body);
        self.babies
            .iter()
            .find(|(id, _)| *id == ty)
            .map(|(_, d)| *d)
    }

    fn voice(&self, body: &Body) -> f32 {
        Hooks::voice(self, 0, &body.data)
    }

    /// `Squid.hurtServer`: hurt by a living thing it squirts ink, its squirt
    /// sound and thirty ink particles below and behind it; a glow squid
    /// darkens for 100 ticks.
    fn hurt(&self, body: &mut Body, _hit: &Hit, events: &mut Vec<Event>) {
        let glow = body.entity_type == GLOW_SQUID;
        let baby = age(&body.data) < 0;
        let ty = self.type_of(body);
        let Some(mind) = body.mob.ai.as_mut() else {
            return;
        };
        let Some(state) = mind.state.as_ref() else {
            return;
        };
        if glow {
            body.data.set("dark", Value::Int(100));
        }
        if state.hurt_by.is_none() {
            return;
        }
        let x_rot = state.own.family::<SquidOwn>().map_or(0.0, |o| o.x_rot);
        let rotate = rotation(x_rot, state.body_yaw);
        let Some(&(_, squirt, ink, volume)) = self.squirts.iter().find(|s| s.0 == ty) else {
            return;
        };
        let pitch = mind.random.voice_pitch(1.0) as f64;
        events.push(Event::Sound {
            sound: SoundRef::Id(squirt),
            source: self.neutral,
            volume,
            pitch,
        });
        let scale = if baby { f(0.1) } else { f(0.3) };
        let at = rotate([0.0, -1.0, 0.0]);
        for _ in 0..30 {
            let a = mind.random.float() as f64;
            let b = mind.random.float() as f64;
            let c = mind.random.float() as f64;
            let [dx, dy, dz] = rotate([a * 0.6 - 0.3, -1.0, b * 0.6 - 0.3]);
            let k = f(scale + f(c * 2.0));
            events.push(Event::Other(Value::Tuple(vec![
                Value::atom("particles"),
                Value::Binary(ink.as_bytes().to_vec()),
                Value::Tuple(vec![Value::atom("at"), Value::vec3(at), Value::Float(0.5)]),
                Value::vec3([dx * k, dy * k, dz * k]),
                Value::Float(0.1),
                Value::Int(0),
            ])));
        }
    }
}

impl Kind for Squid {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Squid"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered {
            goals: vec![
                Registration::new(0, "SquidRandomMovementGoal", 0, RandomMovement),
                Registration::new(1, "SquidFleeGoal", 0, Flee::default()),
            ],
            targets: Vec::new(),
        }
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            fluid_pushed: false,
            travel: (TravelKind::Squid, false),
            emission: Emission::Events,
            ..KindMotion::default()
        }
    }

    /// `wasTouchingWater` as its tick began, for its `aiStep` after the move.
    fn before_ai(&self, t: &mut Turn) {
        let o = SquidOwn {
            in_water: t.in_water(),
            ..own(t)
        };
        put(t, o);
    }

    fn after_ai(&self, t: &mut Turn) {
        Squid::after_ai(self, t);
    }

    /// `WaterAnimal.handleAirSupply`, as a fish's.
    fn air(&self, supply: i32, wet: bool) -> Option<(i32, f64)> {
        Some(if wet {
            (300, 0.0)
        } else if supply - 1 <= -20 {
            (0, 2.0)
        } else {
            (supply - 1, 0.0)
        })
    }

    fn dying(&self) -> bool {
        true
    }

    fn still(&self) -> bool {
        true
    }

    fn fresh_data(&self, type_id: u16) -> Vec<(Atom, Value)> {
        self.data_of(type_id)
    }
}

// ## Goals

/// `SquidRandomMovementGoal` (`Squid.RandomMovement`): always running; idle
/// for over 100 ticks the squid stops, else now and then (one update in
/// 25), or when out of water or without one, it picks a new heading: a
/// fifth of a block a tick around, a tenth up or down.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RandomMovement;

impl Goal for RandomMovement {
    fn can_use(&mut self, _t: &mut Turn) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        let mut o = own(t);
        if t.mind.no_action > 100 {
            o.movement = [0.0; 3];
            put(t, o);
            return;
        }
        let n = t.int(reduced(50) as i32);
        if n == 0 || !o.in_water || !moving(o.movement) {
            let a = t.float();
            let angle = f(a * TWO_PI);
            let b = t.float();
            o.movement = [
                f(fmath::cos(angle) * f(0.2)),
                f(f(-0.1) + f(b * f(0.2))),
                f(fmath::sin(angle) * f(0.2)),
            ];
            put(t, o);
        }
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Squid.RandomMovement"
    }
}

/// `SquidFleeGoal` (`Squid.Flee`): in water, within ten blocks of what last
/// hurt it, the squid heads away from it every tick, faster the closer it
/// is (vanilla leaves the heading unnormalized), flat where the way is air.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Flee {
    ticks: i64,
}

fn attacker(t: &Turn) -> Option<crate::mobs::ai::turn::Seen> {
    let (r, _) = t.mind.hurt_by?;
    t.entity(Some(&r))
}

/// `SquidFleeGoal`'s test of a block: air, water, or neither.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Way {
    No,
    Air,
    Water,
}

fn way(t: &Turn, cell: [i32; 3]) -> Way {
    match t.level.block(cell) {
        None => Way::No,
        Some(s) if t.level.state_flag(s, AIR) => Way::Air,
        Some(s) if t.level.fluid_of(s) == FluidKind::Water => Way::Water,
        Some(_) => Way::No,
    }
}

impl Goal for Flee {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match attacker(t) {
            None => false,
            Some(a) => own(t).in_water && t.distance_sq(a.position) < 100.0,
        }
    }

    fn start(&mut self, _t: &mut Turn) {
        self.ticks = 0;
    }

    fn every_tick(&self) -> bool {
        true
    }

    fn tick(&mut self, t: &mut Turn) {
        self.ticks += 1;
        let Some(a) = attacker(t) else { return };
        let [ax, ay, az] = a.position;
        let flee = [t.x() - ax, t.y() - ay, t.z() - az];
        let [fx, fy, fz] = flee;
        let cell = fmath::block([t.x() + fx, t.y() + fy, t.z() + fz]);
        let way = way(t, cell);
        if way == Way::No {
            return;
        }
        let length = (fx * fx + fy * fy + fz * fz).sqrt();
        let [fx, fy, fz] = if length > 0.0 {
            let speed = if length > 5.0 {
                3.0 - (length - 5.0) / 5.0
            } else {
                3.0
            };
            if speed > 0.0 {
                [fx * speed, fy * speed, fz * speed]
            } else {
                flee
            }
        } else {
            flee
        };
        // Flat where the way is air (the Elixir's `fy - fy`: +0.0).
        let fy = if way == Way::Air { 0.0 } else { fy };
        let mut o = own(t);
        o.movement = [fx / 20.0, fy / 20.0, fz / 20.0];
        put(t, o);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Mobs.Squid.Flee"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_squid_draws_its_tentacle_speed_from_its_id() {
        // `1 / (nextFloat + 1) * 0.2` after `setSeed(id)`.
        let r = LegacyRandom::new(7).float();
        let speed = 1.0f32 / (r + 1.0) * 0.2;
        assert_eq!(SquidOwn::fresh(7).tentacle_speed, speed as f64);
    }
}
