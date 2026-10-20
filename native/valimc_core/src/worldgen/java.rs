//! Java arithmetic that differs from Rust's: `Math.min`/`Math.max` on floats
//! (NaN wins, -0.0 is below 0.0), `Mth.clamp`, and integer `floorDiv`/`floorMod`.

pub fn fmin(a: f32, b: f32) -> f32 {
    if a.is_nan() {
        a
    } else if a == 0.0 && b == 0.0 && b.is_sign_negative() {
        b
    } else if a <= b {
        a
    } else {
        b
    }
}

pub fn fmax(a: f32, b: f32) -> f32 {
    if a.is_nan() {
        a
    } else if a == 0.0 && b == 0.0 && a.is_sign_negative() {
        b
    } else if a >= b {
        a
    } else {
        b
    }
}

/// `Mth.clamp(float, float, float)`.
pub fn clamp(value: f32, min: f32, max: f32) -> f32 {
    if value < min {
        min
    } else {
        fmin(value, max)
    }
}

pub fn floor_div(a: i32, b: i32) -> i32 {
    a.wrapping_div(b) - i32::from((a % b != 0) && ((a < 0) != (b < 0)))
}

pub fn floor_mod(a: i32, b: i32) -> i32 {
    a.wrapping_sub(floor_div(a, b).wrapping_mul(b))
}

/// `Mth.floor(float)`: floor through a double, saturating like Java's cast.
pub fn floor_f32(value: f32) -> i32 {
    (value as f64).floor() as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn min_max_follow_java() {
        assert!(fmin(0.0, -0.0).is_sign_negative());
        assert!(fmin(-0.0, 0.0).is_sign_negative());
        assert!(fmax(-0.0, 0.0).is_sign_positive());
        assert!(fmax(0.0, -0.0).is_sign_positive());
        assert!(fmin(f32::NAN, 1.0).is_nan() && fmin(1.0, f32::NAN).is_nan());
        assert!(fmax(f32::NAN, 1.0).is_nan() && fmax(1.0, f32::NAN).is_nan());
        assert_eq!(fmin(1.0, 2.0), 1.0);
        assert_eq!(fmax(1.0, 2.0), 2.0);
    }

    #[test]
    fn floor_division() {
        for (a, b) in [(7, 4), (-7, 4), (7, -4), (-7, -4), (-8, 4), (0, 3)] {
            assert_eq!(floor_div(a, b), (a as f64 / b as f64).floor() as i32);
            assert_eq!(floor_mod(a, b), a - floor_div(a, b) * b);
        }
        assert_eq!(floor_mod(-1, 8), 7);
    }
}
