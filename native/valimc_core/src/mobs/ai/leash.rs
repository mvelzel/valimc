//! A mob on a lead (VMC-081d), ported from `Valimc.AI.Leash`: vanilla's
//! `Leashable.tickLeash` at the end of `Entity.baseTick`.
//!
//! The mob's `leash` names its holder: a player its AI senses, or a fence
//! knot at a block (`Level::knots`). A lead restored from a record looks for
//! its holder (a missing knot is made again) and drops after 100 ticks
//! without one. A holder gone, dead or broken drops the lead (an item while
//! `entity_drops` is on). With its holder its home is the holder's block
//! (radius 5); past 12 blocks between the boxes' centres the lead breaks;
//! past the slack the lead pulls it as a damped spring; closer, it walks
//! toward the holder unless panicking. Its yaw turns by the lead's angular
//! momentum, which friction slows.

use super::effect::Effect;
use super::fmath::{self, emax, f};
use super::goal::MOVE;
use super::goals::Panic;
use super::navigation;
use super::turn::Turn;
use crate::mobs::kinds::Kind;
use crate::mobs::model::{Home, Leash, LeashHolder};
use crate::mobs::sensing::{Entity, Kind as RefKind, Ref};

const SNAP: f64 = 12.0;
const ELASTIC: f64 = 6.0;
const KNOT_WIDTH: f64 = 0.375;
const KNOT_HEIGHT: f64 = 0.5;

fn spring() -> f64 {
    f(0.3)
}

fn friction() -> f64 {
    f(0.91)
}

fn radians() -> f64 {
    f(std::f64::consts::PI / 180.0)
}

/// A holder as the lead reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Holder {
    pub position: [f64; 3],
    pub width: f64,
    pub height: f64,
    pub yaw: f64,
    pub movement: [f64; 3],
    pub id: Option<i32>,
}

/// `LeashFenceKnotEntity` at block `pos`: its centre, 0.375 up.
pub fn knot(pos: [i32; 3], id: Option<i32>) -> Holder {
    Holder {
        position: [
            pos[0] as f64 + 0.5,
            pos[1] as f64 + 0.375,
            pos[2] as f64 + 0.5,
        ],
        width: KNOT_WIDTH,
        height: KNOT_HEIGHT,
        yaw: 0.0,
        movement: [0.0; 3],
        id,
    }
}

/// `holder/2`: the holder the lead names, or None where it cannot interact
/// with the level.
pub fn holder(t: &Turn, holder: &LeashHolder) -> Option<Holder> {
    match holder {
        LeashHolder::Player(uuid) => {
            let r = Ref {
                kind: RefKind::Player,
                uuid: *uuid,
            };
            match t.sensing.entity(&r) {
                Some(Entity::Player(p)) if p.alive => Some(Holder {
                    position: p.position,
                    width: p.width,
                    height: p.height,
                    yaw: p.yaw,
                    movement: p.movement,
                    id: Some(p.id),
                }),
                _ => None,
            }
        }
        LeashHolder::Knot(pos) => t.level.knot(*pos).map(|id| knot(*pos, Some(id))),
    }
}

/// `canBeLeashed` of a family.
pub fn leashable(kind: &dyn Kind) -> bool {
    kind.leashable()
}

/// `tickLeash`: one tick of the mob's lead, if it has one.
pub fn tick(_kind: &dyn Kind, t: &mut Turn) {
    let Some(leash) = t.mob.body.mob.leash.clone() else {
        return;
    };
    let found = restore(t, &leash);
    match t.mob.body.mob.leash.clone() {
        Some(leash) if !leash.restored => held(t, leash, found),
        _ => {}
    }
}

// `restoreLeashFromSave`.
fn restore(t: &mut Turn, leash: &Leash) -> Option<Holder> {
    if !leash.restored {
        return holder(t, &leash.holder);
    }
    match (holder(t, &leash.holder), &leash.holder) {
        (Some(h), _) => {
            put_leash(
                t,
                Some(Leash {
                    id: h.id,
                    restored: false,
                    ..leash.clone()
                }),
            );
            Some(h)
        }
        (None, LeashHolder::Knot(pos)) => {
            let h = knot(*pos, None);
            t.effect(Effect::MakeKnot(*pos));
            put_leash(
                t,
                Some(Leash {
                    restored: false,
                    ..leash.clone()
                }),
            );
            Some(h)
        }
        (None, _) if t.mind.tick > 100 => {
            drop_item(t);
            put_leash(t, None);
            None
        }
        (None, _) => None,
    }
}

fn held(t: &mut Turn, leash: Leash, holder: Option<Holder>) {
    let Some(holder) = holder else {
        if t.level.rules.entity_drops {
            drop(t);
        } else {
            remove(t);
        }
        return;
    };
    let leash = Leash {
        id: holder.id,
        ..leash
    };
    put_leash(t, Some(leash.clone()));
    let distance = between(
        t.pos(),
        t.width,
        t.height,
        holder.position,
        holder.width,
        holder.height,
    );
    // `whenLeashedTo`: home at the holder's block.
    t.mob.body.mob.home = Some(Home {
        center: fmath::block(holder.position),
        radius: ELASTIC as i32 - 1,
    });
    let mut leash = leash;
    if distance > SNAP {
        if let Some(id) = t.level.facts.sounds.id("minecraft:item.lead.break") {
            t.effect(Effect::SoundAt {
                id,
                source: "neutral",
                at: holder.position,
                volume: 1.0,
                pitch: 1.0,
            });
        }
        // `leashTooFarBehaviour`: the lead drops, `:move` goals stop.
        drop(t);
        t.mind.disabled |= MOVE;
    } else if distance > ELASTIC - holder.width - t.width {
        match elastic(t, &holder, &leash) {
            None => close(t, &holder),
            Some(pulled) => {
                leash = pulled;
                pull(t);
            }
        }
    } else {
        close(t, &holder);
    }
    yaw(t, &leash);
}

// The yaw turns by the angular momentum, which friction slows.
fn yaw(t: &mut Turn, leash: &Leash) {
    t.mob.body.yaw = f(t.yaw() - leash.momentum);
    if t.mob.body.mob.leash.is_some() {
        let momentum = leash.momentum * angular_friction(t);
        if let Some(now) = &mut t.mob.body.mob.leash {
            now.momentum = momentum;
        }
    }
}

// `angularFriction`.
fn angular_friction(t: &Turn) -> f64 {
    if t.on_ground() {
        let [x, y, z] = t.pos();
        let below = [fmath::floor(x), fmath::floor(y - 0.500001), fmath::floor(z)];
        let friction = match t.level.block(below) {
            None => 0.6,
            Some(state) => t.level.physics.motion(state).friction as f64,
        };
        f(f(friction) * self::friction())
    } else if t.in_liquid() {
        f(0.8)
    } else {
        friction()
    }
}

/// `leashDistanceTo`: the distance between the boxes' centres of two
/// bodies.
pub fn between(a: [f64; 3], aw: f64, ah: f64, b: [f64; 3], bw: f64, bh: f64) -> f64 {
    let [ax, ay, az] = center(a, aw, ah);
    let [bx, by, bz] = center(b, bw, bh);
    ((bx - ax) * (bx - ax) + (by - ay) * (by - ay) + (bz - az) * (bz - az)).sqrt()
}

// `AABB.getCenter` of `EntityDimensions.makeBoundingBox` (a float half
// width).
fn center([x, y, z]: [f64; 3], width: f64, height: f64) -> [f64; 3] {
    let half = f(width / 2.0);
    let lerp = |a: f64, b: f64| a + 0.5 * (b - a);
    [
        lerp(x - half, x + half),
        lerp(y, y + height),
        lerp(z - half, z + half),
    ]
}

// `checkElasticInteractions` with one attachment point each: the leash
// with the pull applied to the mob, or None within the slack.
fn elastic(t: &mut Turn, holder: &Holder, leash: &Leash) -> Option<Leash> {
    let own = if t.mob.body.mob.no_ai {
        [0.0; 3]
    } else {
        t.velocity()
    };
    let yaw = f(t.yaw() * radians());
    let lever = rotate([0.0, 0.5 * t.height, 0.5 * t.width], -yaw);
    let holder_yaw = f(holder.yaw * radians());
    let [hx, hy, hz] = rotate([0.0, 0.5 * holder.height, 0.0], -holder_yaw);
    let [lx, ly, lz] = lever;
    let [x, y, z] = t.pos();
    let object = [x + lx, y + ly, z + lz];
    let [px, py, pz] = holder.position;
    let pivot = [px + hx, py + hy, pz + hz];
    let ([fx, fy, fz], torque) = damped(pivot, object, own, lever)?;
    let leash = Leash {
        momentum: leash.momentum + 10.0 * torque,
        ..leash.clone()
    };
    let [mx, my, mz] = holder.movement;
    let [ox, oy, oz] = t.velocity();
    let [rx, ry, rz] = [mx - ox, my - oy, mz - oz];
    let [vx, vy, vz] = t.velocity();
    t.mob.body.velocity = [
        vx + (fx * 0.8 + rx * 0.11),
        vy + (fy * 0.2 + ry * 0.11),
        vz + (fz * 0.8 + rz * 0.11),
    ];
    put_leash(t, Some(leash.clone()));
    Some(leash)
}

// `computeDampenedSpringInteraction`.
fn damped(
    [px, py, pz]: [f64; 3],
    [ox, oy, oz]: [f64; 3],
    [mx, my, mz]: [f64; 3],
    [lx, _, lz]: [f64; 3],
) -> Option<([f64; 3], f64)> {
    let [dx, dy, dz] = [px - ox, py - oy, pz - oz];
    let distance = (dx * dx + dy * dy + dz * dz).sqrt();
    if distance < ELASTIC {
        return None;
    }
    let [nx, ny, nz] = normalize([dx, dy, dz]);
    let stretch = distance - ELASTIC;
    let [fx, fy, fz] = [nx * stretch, ny * stretch, nz * stretch];
    let torque = lz * fx - lx * fz;
    let force = if mx * fx + my * fy + mz * fz >= 0.0 {
        [fx * spring(), fy * spring(), fz * spring()]
    } else {
        [fx, fy, fz]
    };
    Some((force, torque))
}

fn normalize([x, y, z]: [f64; 3]) -> [f64; 3] {
    let length = (x * x + y * y + z * z).sqrt();
    if length < 1.0e-5 {
        [0.0; 3]
    } else {
        [x / length, y / length, z / length]
    }
}

// `Vec3.yRot` (`Mth.cos`, `Mth.sin`).
fn rotate([x, y, z]: [f64; 3], angle: f64) -> [f64; 3] {
    let (sin, cos) = (fmath::sin(angle), fmath::cos(angle));
    [x * cos + z * sin, y, z * cos - x * sin]
}

// `onElasticLeashPull`: `checkFallDistanceAccumulation`.
fn pull(t: &mut Turn) {
    let vy = t.velocity()[1];
    let motion = &mut t.mob.body.mob.motion;
    if vy > -0.5 && motion.fall_distance > 1.0 {
        motion.fall_distance = 1.0;
    }
}

// `PathfinderMob.closeRangeLeashBehaviour`: toward the holder, two blocks
// short.
fn close(t: &mut Turn, holder: &Holder) {
    if panicking(t) {
        return;
    }
    t.mind.disabled &= !MOVE;
    let [x, y, z] = t.pos();
    let [hx, hy, hz] = holder.position;
    let (dx, dy, dz) = (hx - x, hy - y, hz - z);
    let sq = |v: f64| {
        let v = f(v);
        f(v * v)
    };
    let d = f(f(f(sq(dx) + sq(dy)) + sq(dz)).sqrt());
    let scale = emax(f(d - 2.0), 0.0);
    let [nx, ny, nz] = normalize([dx, dy, dz]);
    let target = [x + nx * scale, y + ny * scale, z + nz * scale];
    navigation::move_to(t, target, 1.0);
}

// `PathfinderMob.isPanicking`: a running panic goal.
fn panicking(t: &Turn) -> bool {
    t.mind.goals.runs::<Panic>()
}

/// `dropLeash`: the lead goes, an item where the mob stands; a knot it held
/// checks whether it holds any other mob.
pub fn drop(t: &mut Turn) {
    drop_item(t);
    remove(t);
}

// `removeLeash`: no item; `onLeashRemoved`: no home.
fn remove(t: &mut Turn) {
    if let Some(Leash {
        holder: LeashHolder::Knot(pos),
        ..
    }) = &t.mob.body.mob.leash
    {
        let pos = *pos;
        t.effect(Effect::KnotFree(pos));
    }
    put_leash(t, None);
    t.mob.body.mob.home = None;
}

// `spawnAtLocation(LEAD)`.
fn drop_item(t: &mut Turn) {
    let at = t.pos();
    t.effect(Effect::Lead(at));
}

fn put_leash(t: &mut Turn, leash: Option<Leash>) {
    t.mob.body.mob.leash = leash;
}

/// `Mob.updateControlFlags` every fifth tick (after the tick): the goal
/// selector's flags enabled again.
pub fn control_flags(t: &mut Turn) {
    if t.mind.disabled != 0 && t.mind.tick % 5 == 0 {
        t.mind.disabled = 0;
    }
}
