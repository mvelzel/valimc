//! `Valimc.AI.Mth` and `Valimc.Data.Mth` as the Elixir computes them: each
//! operation in doubles, rounded to a Java float exactly where the Elixir
//! calls `Float32.round` (`f`). For float inputs this is Java's float
//! arithmetic (one double operation rounded equals the float operation); for
//! any other input it still gives the Elixir's bits.

use crate::mobs::mth;

/// `Float32.round`: `(float) value`, widened back.
#[inline]
pub fn f(value: f64) -> f64 {
    value as f32 as f64
}

/// Erlang's `min/2`: the first argument unless the second is smaller.
#[inline]
pub fn emin(a: f64, b: f64) -> f64 {
    if b < a {
        b
    } else {
        a
    }
}

/// Erlang's `max/2`: the first argument unless the second is larger.
#[inline]
pub fn emax(a: f64, b: f64) -> f64 {
    if b > a {
        b
    } else {
        a
    }
}

/// `180.0F / (float)Math.PI` as javac folds it into one double.
pub const DEGREES: f64 = 57.2957763671875;

/// `Mth.atan2`: vanilla's table approximation.
#[inline]
pub fn atan2(y: f64, x: f64) -> f64 {
    mth::atan2(y, x)
}

/// The yaw that faces `(dx, dz)`.
pub fn yaw(dx: f64, dz: f64) -> f64 {
    f(f(atan2(dz, dx) * DEGREES) - 90.0)
}

/// The pitch that faces `dy` over horizontal distance `sd`.
pub fn pitch(dy: f64, sd: f64) -> f64 {
    f(-(atan2(dy, sd) * DEGREES))
}

/// `Mth.wrapDegrees` of a float.
pub fn wrap(angle: f64) -> f64 {
    let mut a = angle % 360.0;
    if a >= 180.0 {
        a = f(a - 360.0);
    }
    if a < -180.0 {
        a = f(a + 360.0);
    }
    a
}

/// `Mth.degreesDifference(from, to)`.
pub fn difference(from: f64, to: f64) -> f64 {
    wrap(f(to - from))
}

/// `Mth.clamp` of floats.
pub fn clamp(value: f64, min: f64, max: f64) -> f64 {
    if value < min {
        min
    } else {
        emin(value, max)
    }
}

/// `Mth.rotateIfNecessary(base, target, max)`.
pub fn rotate_if_necessary(base: f64, target: f64, max: f64) -> f64 {
    f(target - clamp(difference(base, target), -max, max))
}

/// `Control.rotateTowards(from, to, max)`.
pub fn rotate_towards(from: f64, to: f64, max: f64) -> f64 {
    f(from + clamp(difference(from, to), -max, max))
}

/// `MoveControl.rotlerp(from, to, max)`: within 0 to 360.
pub fn rotlerp(from: f64, to: f64, max: f64) -> f64 {
    let angle = f(from + clamp(wrap(f(to - from)), -max, max));
    if angle < 0.0 {
        f(angle + 360.0)
    } else if angle > 360.0 {
        f(angle - 360.0)
    } else {
        angle
    }
}

/// `Mth.positiveCeilDiv`.
pub fn ceil_div(input: i64, divisor: i64) -> i64 {
    -((-input).div_euclid(divisor))
}

/// `Goal.reducedTickDelay`.
pub fn reduced(ticks: i64) -> i64 {
    ceil_div(ticks, 2)
}

/// `Mth.sin` of `value` radians (`Valimc.Data.Mth`), as a double.
#[inline]
pub fn sin(value: f64) -> f64 {
    mth::sin(value) as f64
}

/// `Mth.cos` of `value` radians.
#[inline]
pub fn cos(value: f64) -> f64 {
    mth::cos(value) as f64
}

/// `Math.sin` and `Math.cos` (`physics_sin_cos`: Java's own).
pub fn java_sin_cos(value: f64) -> (f64, f64) {
    (
        crate::worldgen::java::sin(value),
        crate::worldgen::java::cos(value),
    )
}

/// `floor` of a double, as the Elixir's `floor/1` (and `BlockPos`).
#[inline]
pub fn floor(value: f64) -> i32 {
    value.floor() as i32
}

/// `BlockPos.containing`.
#[inline]
pub fn block(p: [f64; 3]) -> [i32; 3] {
    [floor(p[0]), floor(p[1]), floor(p[2])]
}

/// The squared distance between two points.
#[inline]
pub fn distance_sq(a: [f64; 3], b: [f64; 3]) -> f64 {
    let d = [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_where_the_elixir_rounds() {
        assert_eq!(wrap(190.0), -170.0);
        assert_eq!(wrap(-190.0), 170.0);
        assert_eq!(rotlerp(350.0, 10.0, 30.0), 10.0);
        assert_eq!(rotate_towards(0.0, 90.0, 10.0), 10.0);
        assert_eq!(rotate_if_necessary(0.0, 90.0, 75.0), 15.0);
        assert_eq!(reduced(5), 3);
        assert_eq!(reduced(-3), -1);
        // A double that is no float rounds once, after the subtraction.
        let from = 0.1;
        assert_eq!(rotate_towards(from, 0.3, 90.0), f(from + f(0.3 - from)));
        assert_eq!(emin(0.0, -0.0).to_bits(), 0.0f64.to_bits());
        assert_eq!(emax(-0.0, 0.0).to_bits(), (-0.0f64).to_bits());
        assert_eq!(clamp(-0.0, 0.0, 1.0).to_bits(), (-0.0f64).to_bits());
    }
}
