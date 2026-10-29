//! Vanilla's `SmoothSwimmingMoveControl` and `SmoothSwimmingLookControl`
//! (`Valimc.AI.SmoothSwimming`: dolphins, axolotls), as a family's move
//! and look controls run them.
//!
//! The move control: toward the wanted position while the mob navigates
//! (its yaw, body and head turned at most `max_y`; in water its pitch five
//! degrees toward the target within `max_x`, its forward and up inputs by
//! its pitch; out of water slower while it still has to turn), else still.
//! The look control: toward the wanted look 20 degrees past it and 10
//! below, else level (while still) and the head back to the body; the body
//! follows a head more than `max_from_center` off, four degrees a tick.

use super::look;
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::mind::LookAt;
use crate::mobs::ai::turn::Turn;
use crate::mobs::model::{Control, Impulse, MotionSet};

/// `(float)Math.PI / 180.0F`, widened.
const RADIANS: f64 = (std::f64::consts::PI / 180.0) as f32 as f64;
const STILL: f64 = 2.5000003e-7_f32 as f64;
const NEAR: f64 = 1.0e-5_f32 as f64;

/// The move control's settings.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SmoothSwimming {
    /// Its pitch's and yaw's turns.
    pub max_x: f64,
    pub max_y: f64,
    /// Its speed's fractions in and out of water.
    pub in_water: f64,
    pub out: f64,
    /// A little lift in water.
    pub gravity: bool,
}

/// `SmoothSwimmingMoveControl.tick`.
pub fn tick(t: &mut Turn, controls: &SmoothSwimming) {
    let in_water = t.in_water();
    let lift = if controls.gravity && in_water {
        vec![[0.0, 0.005, 0.0]]
    } else {
        vec![]
    };
    match t.mob.body.mob.motion.control {
        Control::MoveTo { target, speed } => {
            if t.mind.navigation.done() {
                set(t, 0.0, [Some(0.0); 3]);
            } else {
                steer(t, target, speed, in_water, controls);
            }
        }
        _ => set(t, 0.0, [Some(0.0); 3]),
    }
    t.mob.body.mob.motion.impulse = Impulse::List(lift);
}

fn steer(t: &mut Turn, wanted: [f64; 3], modifier: f64, in_water: bool, c: &SmoothSwimming) {
    let (xd, yd, zd) = (wanted[0] - t.x(), wanted[1] - t.y(), wanted[2] - t.z());
    if xd * xd + yd * yd + zd * zd < STILL {
        // Only its forward input stops.
        let speed = t.speed();
        set(t, speed, [None, None, Some(0.0)]);
        return;
    }
    let wanted_yaw = fmath::yaw(xd, zd);
    let yaw = fmath::rotlerp(t.yaw(), wanted_yaw, c.max_y);
    t.mob.body.yaw = yaw;
    t.mob.body.head_yaw = yaw;
    t.mind.body_yaw = yaw;
    let attribute = t.attribute("minecraft:movement_speed");
    let speed = f(modifier * attribute);
    if in_water {
        let sqrt = (xd * xd + zd * zd).sqrt();
        if yd.abs() > NEAR || sqrt.abs() > NEAR {
            let pitch = fmath::clamp(fmath::wrap(fmath::pitch(yd, sqrt)), -c.max_x, c.max_x);
            t.mob.body.pitch = fmath::rotate_towards(t.pitch(), pitch, 5.0);
        }
        let angle = f(t.pitch() * RADIANS);
        let (cos, sin) = (fmath::cos(angle), fmath::sin(angle));
        set(
            t,
            f(speed * f(c.in_water)),
            [None, Some(f(-sin * speed)), Some(f(cos * speed))],
        );
    } else {
        let left = fmath::wrap(f(t.yaw() - wanted_yaw)).abs();
        let factor = f(1.0 - fmath::clamp(f((left - 10.0) / 50.0), 0.0, 1.0));
        set(t, f(f(speed * f(c.out)) * factor), [None; 3]);
    }
}

// `setSpeed` and the inputs it sets itself (None: `setSpeed`'s).
fn set(t: &mut Turn, speed: f64, inputs: [Option<f64>; 3]) {
    t.mob.body.mob.motion.set = Some(MotionSet::Inputs {
        speed,
        lift: false,
        inputs,
    });
}

/// `SmoothSwimmingLookControl.tick` with `max_from_center`.
pub fn look(t: &mut Turn, max_from_center: f64) {
    match t.mind.look {
        Some(l) if l.cooldown > 0 => {
            t.mind.look = Some(LookAt {
                cooldown: l.cooldown - 1,
                ..l
            });
            let (yaw, pitch) = look::wanted(t, &l);
            if let Some(yaw) = yaw {
                t.mob.body.head_yaw = fmath::rotate_towards(t.head(), f(yaw + 20.0), l.y_max);
            }
            if let Some(pitch) = pitch {
                t.mob.body.pitch = fmath::rotate_towards(t.pitch(), f(pitch + 10.0), l.x_max);
            }
        }
        l => {
            if t.mind.navigation.done() {
                t.mob.body.pitch = fmath::rotate_towards(t.pitch(), 0.0, 5.0);
            }
            let speed = l.map_or(0.0, |l| l.y_max);
            t.mob.body.head_yaw = fmath::rotate_towards(t.head(), t.mind.body_yaw, speed);
        }
    }
    let diff = fmath::wrap(f(t.head() - t.mind.body_yaw));
    if diff < -max_from_center {
        t.mind.body_yaw = f(t.mind.body_yaw - 4.0);
    } else if diff > max_from_center {
        t.mind.body_yaw = f(t.mind.body_yaw + 4.0);
    }
}
