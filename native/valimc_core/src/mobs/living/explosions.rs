//! `Valimc.Living.Explosions`: what an explosion does to an entity it
//! reaches (`ServerExplosion.hurtEntities` with the default
//! `ExplosionDamageCalculator`): damage by distance and exposure, and a push
//! away from the centre.

use super::f;

/// The box whose entities an explosion of `radius` at `center` considers:
/// `[x0, y0, z0, x1, y1, z1]`.
pub fn reach(radius: f64, center: [f64; 3]) -> [f64; 6] {
    let double = f(radius * 2.0);
    let lo = |v: f64| (v - double - 1.0).floor();
    let hi = |v: f64| (v + double + 1.0).floor();
    [
        lo(center[0]),
        lo(center[1]),
        lo(center[2]),
        hi(center[0]),
        hi(center[1]),
        hi(center[2]),
    ]
}

fn squared(a: [f64; 3], b: [f64; 3]) -> f64 {
    (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])
}

/// The distance from `center` in units of twice the radius, or None past
/// them.
pub fn distance(radius: f64, center: [f64; 3], position: [f64; 3]) -> Option<f64> {
    let distance = squared(position, center).sqrt() / f(radius * 2.0);
    (distance <= 1.0).then_some(distance)
}

/// `getEntityDamageAmount` at `position`, which sees `seen` of the centre.
pub fn damage(radius: f64, center: [f64; 3], position: [f64; 3], seen: f64) -> f64 {
    let double = f(radius * 2.0);
    let distance = squared(position, center).sqrt() / double;
    let power = (1.0 - distance) * seen;
    f((power * power + power) / 2.0 * 7.0 * double + 1.0)
}

/// The push away from `center` toward `origin`, `(1 - distance) * seen *
/// (1 - resistance)` long.
pub fn knockback(
    center: [f64; 3],
    origin: [f64; 3],
    distance: f64,
    seen: f64,
    resistance: f64,
) -> [f64; 3] {
    let d = [
        origin[0] - center[0],
        origin[1] - center[1],
        origin[2] - center[2],
    ];
    let length = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
    let power = (1.0 - distance) * seen * (1.0 - resistance);
    if length < 1.0e-5 {
        [0.0; 3]
    } else {
        [
            d[0] / length * power,
            d[1] / length * power,
            d[2] / length * power,
        ]
    }
}
