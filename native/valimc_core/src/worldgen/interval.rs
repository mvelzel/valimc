//! Float value ranges of density functions (vanilla's `Interval`). Compiling
//! `min` and `max` consults them, so they follow vanilla's float arithmetic
//! exactly. `NAI` (not an interval) marks an undefined range.

use super::java::{fmax, fmin};

#[derive(Clone, Copy, Debug)]
pub struct Interval {
    pub min: f32,
    pub max: f32,
    nai: bool,
}

pub const NAI: Interval = Interval {
    min: f32::NAN,
    max: f32::NAN,
    nai: true,
};

pub const INFINITE: Interval = Interval {
    min: f32::NEG_INFINITY,
    max: f32::INFINITY,
    nai: false,
};

fn mul_bound(left: f32, right: f32) -> f32 {
    if left != 0.0 && right != 0.0 {
        left * right
    } else {
        0.0
    }
}

// Named after vanilla's static methods, not the operator traits.
#[allow(clippy::should_implement_trait)]
impl Interval {
    /// A range; vanilla rejects reversed or NaN bounds, which only invalid
    /// data produces, and those become `NAI` here.
    pub fn of(min: f32, max: f32) -> Interval {
        if max < min || min.is_nan() || max.is_nan() {
            NAI
        } else {
            Interval {
                min,
                max,
                nai: false,
            }
        }
    }

    pub fn symmetric(range: f32) -> Interval {
        Interval::of(-range, range)
    }

    pub fn exact(value: f32) -> Interval {
        Interval::of(value, value)
    }

    pub fn is_nai(&self) -> bool {
        self.nai
    }

    pub fn contains(&self, value: f32) -> bool {
        value >= self.min && value <= self.max
    }

    pub fn encapsulating(intervals: &[Interval]) -> Interval {
        let (mut min, mut max) = (f32::INFINITY, f32::NEG_INFINITY);
        for i in intervals.iter().filter(|i| !i.nai) {
            min = fmin(i.min, min);
            max = fmax(i.max, max);
        }
        if max < min {
            NAI
        } else {
            Interval::of(min, max)
        }
    }

    pub fn encapsulating_values(first: f32, second: f32) -> Interval {
        match (first.is_nan(), second.is_nan()) {
            (true, true) => NAI,
            (true, false) => Interval::exact(second),
            (false, true) => Interval::exact(first),
            _ => Interval::of(fmin(first, second), fmax(first, second)),
        }
    }

    pub fn add(l: Interval, r: Interval) -> Interval {
        let (min, max) = (l.min + r.min, l.max + r.max);
        if min.is_nan() || max.is_nan() {
            NAI
        } else {
            Interval::of(min, max)
        }
    }

    pub fn sub(l: Interval, r: Interval) -> Interval {
        let (min, max) = (l.min - r.max, l.max - r.min);
        if min.is_nan() || max.is_nan() {
            NAI
        } else {
            Interval::of(min, max)
        }
    }

    pub fn mul(l: Interval, r: Interval) -> Interval {
        if l.nai || r.nai {
            return NAI;
        }
        let a = mul_bound(l.min, r.min);
        let b = mul_bound(l.min, r.max);
        let c = mul_bound(l.max, r.min);
        let d = mul_bound(l.max, r.max);
        Interval::of(fmin(fmin(a, b), fmin(c, d)), fmax(fmax(a, b), fmax(c, d)))
    }

    pub fn reciprocal(input: Interval) -> Interval {
        if input.nai || (input.min == 0.0 && input.max == 0.0) {
            NAI
        } else if !input.contains(0.0) {
            Interval::of(1.0 / input.max, 1.0 / input.min)
        } else if input.max == 0.0 {
            Interval::of(f32::NEG_INFINITY, 1.0 / input.min)
        } else if input.min == 0.0 {
            Interval::of(1.0 / input.max, f32::INFINITY)
        } else {
            INFINITE
        }
    }

    pub fn div(l: Interval, r: Interval) -> Interval {
        Interval::mul(l, Interval::reciprocal(r))
    }

    pub fn min_of(l: Interval, r: Interval) -> Interval {
        if l.nai || r.nai {
            NAI
        } else {
            Interval::of(fmin(l.min, r.min), fmin(l.max, r.max))
        }
    }

    pub fn max_of(l: Interval, r: Interval) -> Interval {
        if l.nai || r.nai {
            NAI
        } else {
            Interval::of(fmax(l.min, r.min), fmax(l.max, r.max))
        }
    }

    pub fn clamp(input: Interval, min: f32, max: f32) -> Interval {
        if min > max || input.nai {
            NAI
        } else if input.min >= max {
            Interval::of(max, max)
        } else if input.max <= min {
            Interval::of(min, min)
        } else {
            Interval::of(fmax(input.min, min), fmin(input.max, max))
        }
    }

    pub fn abs(input: Interval) -> Interval {
        if input.nai {
            return NAI;
        }
        let max = fmax(input.min.abs(), input.max.abs());
        if input.contains(0.0) {
            Interval::of(0.0, max)
        } else {
            Interval::of(fmin(input.min.abs(), input.max.abs()), max)
        }
    }

    pub fn square(input: Interval) -> Interval {
        if input.nai {
            return NAI;
        }
        let (a, b) = (input.min * input.min, input.max * input.max);
        let max = fmax(a, b);
        if input.contains(0.0) {
            Interval::of(0.0, max)
        } else {
            Interval::of(fmin(a, b), max)
        }
    }

    pub fn map_monotonic(input: Interval, op: impl Fn(f32) -> f32) -> Interval {
        if input.nai {
            return NAI;
        }
        let (a, b) = (op(input.min), op(input.max));
        if a.is_nan() || b.is_nan() {
            NAI
        } else {
            Interval::of(fmin(a, b), fmax(a, b))
        }
    }

    pub fn lerp(alpha: Interval, first: Interval, second: Interval) -> Interval {
        if alpha.nai || first.nai || second.nai {
            return NAI;
        }
        Interval::encapsulating(&[
            Interval::lerp_bounds(alpha, first.min, second.min),
            Interval::lerp_bounds(alpha, first.max, second.min),
            Interval::lerp_bounds(alpha, first.min, second.max),
            Interval::lerp_bounds(alpha, first.max, second.max),
        ])
    }

    fn lerp_bounds(alpha: Interval, first: f32, second: f32) -> Interval {
        if alpha.nai || first.is_nan() || second.is_nan() {
            NAI
        } else if first.is_finite() && second.is_finite() {
            Interval::encapsulating_values(
                first + mul_bound(alpha.min, second - first),
                first + mul_bound(alpha.max, second - first),
            )
        } else if first == second {
            Interval::exact(first)
        } else {
            let a = Interval::lerp_infinite(alpha.min, first, second);
            let b = Interval::lerp_infinite(alpha.max, first, second);
            if a.is_nan() || b.is_nan() {
                NAI
            } else {
                Interval::encapsulating_values(a, b)
            }
        }
    }

    fn lerp_infinite(alpha: f32, first: f32, second: f32) -> f32 {
        let first_part = mul_bound(1.0 - alpha, first);
        let second_part = mul_bound(alpha, second);
        if !first_part.is_infinite() || !second_part.is_infinite() {
            first_part + second_part
        } else if alpha <= 0.0 {
            if second > first {
                f32::NEG_INFINITY
            } else {
                f32::INFINITY
            }
        } else if alpha >= 1.0 {
            if second > first {
                f32::INFINITY
            } else {
                f32::NEG_INFINITY
            }
        } else {
            f32::NAN
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic() {
        let a = Interval::of(-1.0, 2.0);
        let b = Interval::of(3.0, 4.0);
        let s = Interval::add(a, b);
        assert_eq!((s.min, s.max), (2.0, 6.0));
        let m = Interval::mul(a, b);
        assert_eq!((m.min, m.max), (-4.0, 8.0));
        let r = Interval::reciprocal(Interval::of(0.0, 2.0));
        assert_eq!((r.min, r.max), (0.5, f32::INFINITY));
        assert!(Interval::reciprocal(Interval::exact(0.0)).is_nai());
        let c = Interval::clamp(Interval::of(-5.0, 0.5), -1.0, 1.0);
        assert_eq!((c.min, c.max), (-1.0, 0.5));
        let q = Interval::square(a);
        assert_eq!((q.min, q.max), (0.0, 4.0));
        assert!(Interval::encapsulating(&[NAI]).is_nai());
    }

    #[test]
    fn lerp_of_ranges() {
        let l = Interval::lerp(
            Interval::of(0.0, 1.0),
            Interval::exact(0.0),
            Interval::of(-2.0, 3.0),
        );
        assert_eq!((l.min, l.max), (-2.0, 3.0));
        let inf = Interval::lerp(Interval::of(0.0, 1.0), INFINITE, Interval::exact(1.0));
        assert_eq!((inf.min, inf.max), (f32::NEG_INFINITY, f32::INFINITY));
    }
}
