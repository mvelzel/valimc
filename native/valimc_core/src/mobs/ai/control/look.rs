//! Vanilla's `LookControl` and `BodyRotationControl` (`Valimc.AI.Look`).
//! The look control runs after the goals and navigation, before the move:
//! toward the wanted look for two ticks after a goal sets it (the head's yaw
//! by at most the goal's speed, the pitch by its limit), else the head back
//! toward the body; the head stays within its limit of the body while the
//! mob navigates. The body control runs after the move: a moving body faces
//! its yaw and pulls the head within the limit; a still one follows a head
//! that turned past 15 degrees, and after ten still ticks turns toward the
//! head over ten more.

use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::mind::LookAt;
use crate::mobs::ai::turn::Turn;

/// `2.5000003E-7F` and `1.0E-5F`, widened.
const STILL: f64 = 2.5000003e-7_f32 as f64;
const NEAR: f64 = 1.0e-5_f32 as f64;

/// `LookControl.tick` (a family's own control, or its own measure of the
/// look, where it has one).
pub fn tick(t: &mut Turn) {
    let hooks = t.hooks;
    if !hooks.look_control(t) {
        look(t);
    }
}

fn look(t: &mut Turn) {
    // `resetXRotOnTick`.
    t.mob.body.pitch = 0.0;
    match t.mind.look {
        Some(look) if look.cooldown > 0 => {
            t.mind.look = Some(LookAt {
                cooldown: look.cooldown - 1,
                ..look
            });
            let (yaw, pitch) = wanted(t, &look);
            if let Some(yaw) = yaw {
                t.mob.body.head_yaw = fmath::rotate_towards(t.head(), yaw, look.y_max);
            }
            if let Some(pitch) = pitch {
                t.mob.body.pitch = fmath::rotate_towards(t.pitch(), pitch, look.x_max);
            }
        }
        _ => {
            t.mob.body.head_yaw = fmath::rotate_towards(t.head(), t.mind.body_yaw, 10.0);
        }
    }
    if !t.mind.navigation.done() && t.hooks.clamps_head(t.type_id) {
        t.mob.body.head_yaw =
            fmath::rotate_if_necessary(t.head(), t.mind.body_yaw, t.facts.max_head_y_rot);
    }
}

/// `getYRotD` and `getXRotD` of `look` (`Look.wanted/2`): None where it is
/// too close to measure.
pub fn wanted(t: &Turn, look: &LookAt) -> (Option<f64>, Option<f64>) {
    if let Some(rotations) = t.hooks.look_rotations(t, look) {
        return rotations;
    }
    let (dx, dy, dz) = (look.x - t.x(), look.y - t.eye_y(), look.z - t.z());
    let yaw = (dz.abs() > NEAR || dx.abs() > NEAR).then(|| fmath::yaw(dx, dz));
    let sd = (dx * dx + dz * dz).sqrt();
    let pitch = (dy.abs() > NEAR || sd.abs() > NEAR).then(|| fmath::pitch(dy, sd));
    (yaw, pitch)
}

/// `BodyRotationControl.clientTick` after the move from `(xo, zo)`.
pub fn body(t: &mut Turn, from: [f64; 2]) {
    if t.hooks.turns_body(t.type_id) {
        turn_body(t, from);
    }
}

fn turn_body(t: &mut Turn, [xo, zo]: [f64; 2]) {
    let (dx, dz) = (t.x() - xo, t.z() - zo);
    let limit = t.facts.max_head_y_rot;
    if dx * dx + dz * dz > STILL {
        let head = fmath::rotate_if_necessary(t.head(), t.yaw(), limit);
        t.mob.body.head_yaw = head;
        t.mind.body_yaw = t.yaw();
        t.mind.stable_head = head;
        t.mind.stable_time = 0;
    } else if f(t.head() - t.mind.stable_head).abs() > 15.0 {
        let body = fmath::rotate_if_necessary(t.mind.body_yaw, t.head(), limit);
        t.mind.stable_time = 0;
        t.mind.stable_head = t.head();
        t.mind.body_yaw = body;
    } else {
        let time = t.mind.stable_time + 1;
        let body = if time > 10 {
            let fraction = fmath::clamp(f((time - 10) as f64 / 10.0), 0.0, 1.0);
            let remaining = f(limit * f(1.0 - fraction));
            fmath::rotate_if_necessary(t.mind.body_yaw, t.head(), remaining)
        } else {
            t.mind.body_yaw
        };
        t.mind.stable_time = time;
        t.mind.body_yaw = body;
    }
}
