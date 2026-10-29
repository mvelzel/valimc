//! `Valimc.Living.Melee` as mobs use it: `LivingEntity.knockback` and the
//! direction of an attacker's extra knockback (`causeExtraKnockback`).

use super::super::mth;
use super::{emin, f, math_random};

/// `(float) (Math.PI / 180.0)`.
const DEG: f64 = 0.01745329238474369;
/// `1.0E-5F`, widened.
const EPSILON: f64 = 9.999999747378752e-6;

/// The knockback of a hit: `0.4F`, widened.
pub const DEFAULT_KNOCKBACK: f64 = 0.4000000059604645;

/// `LivingEntity.knockback(power, xd, zd)` on a body moving at `velocity`:
/// its new velocity (the same when its resistance cancels it). A direction
/// too small to normalize is drawn from `Math.random()`.
pub fn knockback(
    velocity: [f64; 3],
    on_ground: bool,
    power: f64,
    direction: [f64; 2],
    resistance: f64,
) -> [f64; 3] {
    let power = power * (1.0 - resistance);
    if power <= 0.0 {
        return velocity;
    }
    let [mut xd, mut zd] = direction;
    while xd * xd + zd * zd < EPSILON {
        xd = (math_random() - math_random()) * 0.01;
        zd = (math_random() - math_random()) * 0.01;
    }
    let length = (xd * xd + zd * zd).sqrt();
    let (nx, nz) = if length < EPSILON {
        (0.0, 0.0)
    } else {
        (xd / length, zd / length)
    };
    let (dx, dz) = (nx * power, nz * power);
    let [vx, vy, vz] = velocity;
    [
        vx / 2.0 - dx,
        if on_ground {
            emin(0.4, vy / 2.0 + power)
        } else {
            vy
        },
        vz / 2.0 - dz,
    ]
}

/// The knockback direction of an attacker facing `yaw` degrees
/// (`Melee.facing/1`): `{sin(yaw), -cos(yaw)}`.
pub fn facing(yaw: f64) -> [f64; 2] {
    let radians = f(f(yaw) * DEG);
    [mth::sin(radians) as f64, -(mth::cos(radians) as f64)]
}
