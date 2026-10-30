//! The bat (`Valimc.AI.Mobs.Bat`, vanilla's `Bat`): an ambient flier with
//! no goals.
//!
//! A resting bat hangs under a block that conducts redstone, still and
//! snapped to the top of its block, now and then turning its head; a player
//! within four blocks, losing its perch or a hurt wakes it (level event
//! 1025, its takeoff). Awake it steers its motion toward a random spot near
//! it (picked again now and then, or when it gets there or the spot fills),
//! its vertical motion fading, and now and then perches under a conductor
//! above it (`customServerAiStep`). It neither pushes nor is pushed, never
//! takes fall damage, and its voice is lower. Resting is its saved flag
//! (`BatFlags`); its target spot is its own state (`BatSpot`).

use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::hooks::Hooks;
use crate::mobs::ai::turn::{Targeting, Turn};
use crate::mobs::combat::{Event, Family, Hit};
use crate::mobs::facts::MobFacts;
use crate::mobs::kinds::{Emission, Kind, KindMotion, Registered};
use crate::mobs::model::{Body, FamilyData, Impulse};
use crate::mobs::monsters::{fields, flag, value};
use crate::mobs::term::{Atom, Value};

pub const BAT: &str = "minecraft:bat";

/// Where a flying bat heads (`targetPosition`; `Mind.own`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BatSpot(pub [i32; 3]);

/// The bat family.
pub struct Bat {
    types: [&'static str; 1],
    ambient: i32,
}

fn sign(v: f64) -> f64 {
    if v > 0.0 {
        1.0
    } else if v < 0.0 {
        -1.0
    } else {
        0.0
    }
}

impl Bat {
    pub fn new(facts: &MobFacts) -> Result<Bat, String> {
        Ok(Bat {
            types: [BAT],
            ambient: crate::mobs::monsters::sound(facts, "minecraft:entity.bat.ambient")?,
        })
    }

    fn data_of() -> Vec<(Atom, Value)> {
        fields(&[("resting", Value::bool(true))])
    }

    fn wake(t: &mut Turn, cell: [i32; 3]) {
        t.mob.body.data.set("resting", Value::bool(false));
        t.effect(Effect::LevelEvent {
            cell,
            kind: 1025,
            data: 0,
        });
    }

    /// Resting: its head turns now and then; a player within four blocks or
    /// a lost perch wakes it.
    fn rest(t: &mut Turn) {
        let pos = t.block();
        let [x, y, z] = pos;
        if !t.level.conductor([x, y + 1, z]) {
            Bat::wake(t, pos);
            return;
        }
        if t.int(200) == 0 {
            let head = t.int(360);
            t.mob.body.head_yaw = head as f64;
        }
        let targeting = Targeting::new(false).range(4.0);
        let point = t.pos();
        if t.nearest_player(&targeting, point).is_some() {
            Bat::wake(t, pos);
        }
    }

    /// Flying: its motion steered a tenth of the way toward its spot, its
    /// body turned with it; one time in a hundred it perches under a
    /// conductor above it.
    fn fly(t: &mut Turn) {
        let [x, y, z] = t.block();
        let [tx, ty, tz] = Bat::target(t);
        let (dx, dy, dz) = (
            tx as f64 + 0.5 - t.x(),
            ty as f64 + 0.1 - t.y(),
            tz as f64 + 0.5 - t.z(),
        );
        // Its motion after `aiStep`'s dead zone.
        let [mx, my, mz] = t.velocity().map(|v| if v.abs() < 0.003 { 0.0 } else { v });
        let tenth = f(0.1);
        let impulse = [
            (sign(dx) * 0.5 - mx) * tenth,
            (sign(dy) * f(0.7) - my) * tenth,
            (sign(dz) * 0.5 - mz) * tenth,
        ];
        let yaw = fmath::yaw(mx + impulse[0], mz + impulse[2]);
        let current = t.yaw();
        t.mob.body.yaw = f(current + fmath::wrap(f(yaw - current)));
        t.mob.body.mob.motion.impulse = Impulse::One(impulse);
        if t.int(100) == 0 && t.level.conductor([x, y + 1, z]) {
            t.mob.body.data.set("resting", Value::bool(true));
        }
    }

    /// Its spot: dropped once filled or below the world, picked again when
    /// missing, one time in thirty, or within two blocks.
    fn target(t: &mut Turn) -> [i32; 3] {
        let kept = t
            .mind
            .own
            .family::<BatSpot>()
            .map(|s| s.0)
            .filter(|&p| t.level.air(p) && p[1] > t.level.min_y);
        let again = match kept {
            None => true,
            Some([tx, ty, tz]) => {
                let n = t.int(30);
                let (cx, cy, cz) = (
                    tx as f64 + 0.5 - t.x(),
                    ty as f64 + 0.5 - t.y(),
                    tz as f64 + 0.5 - t.z(),
                );
                n == 0 || cx * cx + cy * cy + cz * cz < 4.0
            }
        };
        match kept {
            Some(spot) if !again => spot,
            _ => {
                let a = t.int(7);
                let b = t.int(7);
                let c = t.int(6);
                let d = t.int(7);
                let e = t.int(7);
                let spot = [
                    fmath::floor(t.x() + a as f64 - b as f64),
                    fmath::floor(t.y() + c as f64 - 2.0),
                    fmath::floor(t.z() + d as f64 - e as f64),
                ];
                t.mind.own.family = Some(Box::new(BatSpot(spot)));
                spot
            }
        }
    }
}

impl Hooks for Bat {
    /// `getVoicePitch`: the usual, times 0.95.
    fn voice_scale(&self, _type_id: u16) -> f32 {
        0.95
    }
}

impl Family for Bat {
    fn data(&self, _type_id: u16) -> FamilyData {
        FamilyData::new(Bat::data_of()).unwrap_or_else(FamilyData::empty)
    }

    fn values(&self, body: &Body) -> Vec<(Atom, Value, Value)> {
        let resting = flag(&body.data, "resting");
        vec![value(
            "bat_flags",
            Value::Int(if resting { 1 } else { 0 }),
            Value::Int(0),
        )]
    }

    fn voice_scale(&self, _body: &Body) -> f32 {
        0.95
    }

    /// `hurtServer`: a hurt wakes it.
    fn hurt(&self, body: &mut Body, _hit: &Hit, _events: &mut Vec<Event>) {
        if flag(&body.data, "resting") {
            body.data.set("resting", Value::bool(false));
        }
    }
}

impl Kind for Bat {
    fn module(&self) -> &'static str {
        "Valimc.AI.Mobs.Bat"
    }

    fn types(&self) -> &[&'static str] {
        &self.types
    }

    fn goals(&self, _facts: &MobFacts, _type_id: u16) -> Registered {
        Registered::default()
    }

    fn kernel_motion(&self) -> KindMotion {
        KindMotion {
            pushable: false,
            pushes: false,
            emission: Emission::Events,
            ..KindMotion::default()
        }
    }

    fn falls(&self) -> bool {
        false
    }

    /// `getAmbientSound`: a resting bat only one time in four.
    fn ambient_sound(&self, t: &mut Turn) -> Option<i32> {
        if flag(t.data(), "resting") && t.int(4) != 0 {
            return None;
        }
        Some(self.ambient)
    }

    /// `customServerAiStep`: resting, or flying toward its spot.
    fn custom_step(&self, t: &mut Turn) {
        if flag(t.data(), "resting") {
            Bat::rest(t);
        } else {
            Bat::fly(t);
        }
    }

    /// `Bat.tick` after its super: a resting bat stops and hangs from the
    /// top of its block; a flying one's vertical motion fades.
    fn after_tick(&self, t: &mut Turn) {
        if flag(t.data(), "resting") {
            t.mob.body.velocity = [0.0; 3];
            let y = fmath::floor(t.y()) as f64 + 1.0 - t.height;
            t.mob.position[1] = y;
        } else {
            let [vx, vy, vz] = t.velocity();
            t.mob.body.velocity = [vx, vy * 0.6, vz];
        }
    }

    fn fresh_data(&self, _type_id: u16) -> Vec<(Atom, Value)> {
        Bat::data_of()
    }
}
