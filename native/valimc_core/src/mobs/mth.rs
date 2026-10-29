//! Vanilla's `Mth` and `Control` arithmetic for mobs (VMC-081d,
//! `Valimc.AI.Mth`, `Valimc.Data.Mth`): Java `float` operations are `f32`
//! operations here, so each rounds as Java's does; `atan2` is vanilla's table
//! approximation (`physics::mob::atan2`).

pub use crate::physics::mob::atan2;
use std::sync::OnceLock;

/// `180.0F / (float)Math.PI` as javac folds it into one double.
const DEGREES: f64 = 57.2957763671875;

/// The yaw that faces `(dx, dz)`: `(float)(atan2(dz, dx) * 180 / PI) - 90`.
pub fn yaw(dx: f64, dz: f64) -> f32 {
    (atan2(dz, dx) * DEGREES) as f32 - 90.0
}

/// The pitch that faces `dy` over horizontal distance `sd`.
pub fn pitch(dy: f64, sd: f64) -> f32 {
    (-(atan2(dy, sd) * DEGREES)) as f32
}

/// `Mth.wrapDegrees` of a float.
pub fn wrap(angle: f32) -> f32 {
    let mut a = angle % 360.0;
    if a >= 180.0 {
        a -= 360.0;
    }
    if a < -180.0 {
        a += 360.0;
    }
    a
}

/// `Mth.wrapDegrees` of a double.
pub fn wrap_f64(angle: f64) -> f64 {
    let mut a = angle % 360.0;
    if a >= 180.0 {
        a -= 360.0;
    }
    if a < -180.0 {
        a += 360.0;
    }
    a
}

/// `Mth.degreesDifference(from, to)`.
pub fn difference(from: f32, to: f32) -> f32 {
    wrap(to - from)
}

/// `Mth.clamp` of floats (Java's: below min gives min, else at most max).
pub fn clamp(value: f32, min: f32, max: f32) -> f32 {
    if value < min {
        min
    } else {
        value.min(max)
    }
}

/// `Mth.clamp` of doubles.
pub fn clamp_f64(value: f64, min: f64, max: f64) -> f64 {
    if value < min {
        min
    } else {
        value.min(max)
    }
}

/// `Mth.rotateIfNecessary(base, target, max)`.
pub fn rotate_if_necessary(base: f32, target: f32, max: f32) -> f32 {
    target - clamp(difference(base, target), -max, max)
}

/// `Control.rotateTowards(from, to, max)`.
pub fn rotate_towards(from: f32, to: f32, max: f32) -> f32 {
    from + clamp(difference(from, to), -max, max)
}

/// `MoveControl.rotlerp(from, to, max)`: within 0 to 360.
pub fn rotlerp(from: f32, to: f32, max: f32) -> f32 {
    let angle = from + clamp(wrap(to - from), -max, max);
    if angle < 0.0 {
        angle + 360.0
    } else if angle > 360.0 {
        angle - 360.0
    } else {
        angle
    }
}

/// `Mth.lerp(delta, from, to)` of floats.
pub fn lerp(delta: f32, from: f32, to: f32) -> f32 {
    from + delta * (to - from)
}

/// `Mth.rotLerp(delta, from, to)`.
pub fn rot_lerp(delta: f32, from: f32, to: f32) -> f32 {
    from + delta * wrap(to - from)
}

/// `Mth.approach(current, target, increment)`.
pub fn approach(current: f32, target: f32, increment: f32) -> f32 {
    let increment = increment.abs();
    if current < target {
        clamp(current + increment, current, target)
    } else {
        clamp(current - increment, target, current)
    }
}

/// `Mth.approachDegrees(current, target, increment)`.
pub fn approach_degrees(current: f32, target: f32, increment: f32) -> f32 {
    approach(current, current + difference(current, target), increment)
}

/// `Mth.positiveCeilDiv`.
pub fn ceil_div(input: i32, divisor: i32) -> i32 {
    -((-input).div_euclid(divisor))
}

/// `Goal.reducedTickDelay`: a delay for goals updated every other tick.
pub fn reduced(ticks: i32) -> i32 {
    ceil_div(ticks, 2)
}

/// `Mth.floor` of a double, as `BlockPos.containing` floors.
pub fn floor(value: f64) -> i32 {
    value.floor() as i32
}

/// `BlockPos.containing(x, y, z)`.
pub fn block(position: [f64; 3]) -> [i32; 3] {
    [floor(position[0]), floor(position[1]), floor(position[2])]
}

const RADIANS: f64 = 10_430.378350470453;

fn sine_table() -> &'static [f32] {
    static TABLE: OnceLock<Vec<f32>> = OnceLock::new();
    TABLE.get_or_init(|| {
        (0..65_536)
            .map(|i| (i as f64 / RADIANS).sin() as f32)
            .collect()
    })
}

/// `Mth.sin` of `value` radians (the 65,536-entry float table).
pub fn sin(value: f64) -> f32 {
    sine_table()[((value * RADIANS) as i64 & 65_535) as usize]
}

/// `Mth.cos` of `value` radians.
pub fn cos(value: f64) -> f32 {
    sine_table()[((value * RADIANS + 16_384.0) as i64 & 65_535) as usize]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn angles_wrap_and_rotate_as_floats() {
        assert_eq!(wrap(190.0), -170.0);
        assert_eq!(wrap(-190.0), 170.0);
        assert_eq!(rotlerp(350.0, 10.0, 30.0), 10.0);
        assert_eq!(rotate_towards(0.0, 90.0, 10.0), 10.0);
        assert_eq!(approach(1.0, 0.0, 0.25), 0.75);
        assert_eq!(reduced(5), 3);
        assert_eq!(ceil_div(-3, 2), -1);
    }
}
