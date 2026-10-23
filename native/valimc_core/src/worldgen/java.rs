//! Java arithmetic that differs from Rust's: `Math.min`/`Math.max` on floats
//! (NaN wins, -0.0 is below 0.0), `Mth.clamp`, integer `floorDiv`/`floorMod`,
//! and `StrictMath.sin`/`cos`/`asin`.

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

// `StrictMath.sin` and `cos` (VMC-025f5): fdlibm 5.3's algorithms, which
// `Math` gives too where the JVM has no trigonometric intrinsics (the oracles
// run so, `-XX:DisableIntrinsic=_dsin,_dcos`). A platform's own functions and
// a JVM's intrinsics each differ from them in the last place for some inputs,
// which moves a block where a coordinate lands on a boundary.
//
// The algorithms and constants are fdlibm's: Copyright (C) 1993 by Sun
// Microsystems, Inc. All rights reserved. Developed at SunSoft, a Sun
// Microsystems, Inc. business. Permission to use, copy, modify, and
// distribute this software is freely granted, provided that this notice is
// preserved.

fn high(x: f64) -> i32 {
    (x.to_bits() >> 32) as i32
}

/// `__kernel_sin` on `[-pi/4, pi/4]`: `x + y` is the argument, `tail`
/// whether `y` counts.
fn kernel_sin(x: f64, y: f64, tail: bool) -> f64 {
    const S1: f64 = f64::from_bits(0xBFC5_5555_5555_5549);
    const S2: f64 = f64::from_bits(0x3F81_1111_1110_F8A6);
    const S3: f64 = f64::from_bits(0xBF2A_01A0_19C1_61D5);
    const S4: f64 = f64::from_bits(0x3EC7_1DE3_57B1_FE7D);
    const S5: f64 = f64::from_bits(0xBE5A_E5E6_8A2B_9CEB);
    const S6: f64 = f64::from_bits(0x3DE5_D93A_5ACF_D57C);
    if high(x) & 0x7fff_ffff < 0x3e40_0000 && x as i32 == 0 {
        return x;
    }
    let z = x * x;
    let v = z * x;
    let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
    if !tail {
        x + v * (S1 + z * r)
    } else {
        x - ((z * (0.5 * y - v * r) - y) - v * S1)
    }
}

/// `__kernel_cos` on `[-pi/4, pi/4]`.
fn kernel_cos(x: f64, y: f64) -> f64 {
    const C1: f64 = f64::from_bits(0x3FA5_5555_5555_554C);
    const C2: f64 = f64::from_bits(0xBF56_C16C_16C1_5177);
    const C3: f64 = f64::from_bits(0x3EFA_01A0_19CB_1590);
    const C4: f64 = f64::from_bits(0xBE92_7E4F_809C_52AD);
    const C5: f64 = f64::from_bits(0x3E21_EE9E_BDB4_B1C4);
    const C6: f64 = f64::from_bits(0xBDA8_FAE9_BE88_38D4);
    let ix = high(x) & 0x7fff_ffff;
    if ix < 0x3e40_0000 && x as i32 == 0 {
        return 1.0;
    }
    let z = x * x;
    let r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))));
    if ix < 0x3fd3_3333 {
        return 1.0 - (0.5 * z - (z * r - x * y));
    }
    let qx = if ix > 0x3fe9_0000 {
        0.28125
    } else {
        f64::from_bits(((ix - 0x0020_0000) as u32 as u64) << 32)
    };
    let hz = 0.5 * z - qx;
    let a = 1.0 - qx;
    a - (hz - (z * r - x * y))
}

/// `__ieee754_rem_pio2` up to 2^19 pi/2: `x` less a multiple `n` of pi/2
/// as a head and tail, with `n`; `None` beyond.
fn rem_pio2(x: f64) -> Option<(i32, f64, f64)> {
    const NPIO2_HW: [i32; 32] = [
        0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, 0x4025FDBB,
        0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C, 0x40346B9C, 0x4035FDBB,
        0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A, 0x403DD85A, 0x403F6A7A, 0x40407E4C,
        0x4041475C, 0x4042106C, 0x4042D97C, 0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB,
        0x4046C6CB, 0x40478FDB, 0x404858EB, 0x404921FB,
    ];
    const INVPIO2: f64 = f64::from_bits(0x3FE4_5F30_6DC9_C883);
    const PIO2_1: f64 = f64::from_bits(0x3FF9_21FB_5440_0000);
    const PIO2_1T: f64 = f64::from_bits(0x3DD0_B461_1A62_6331);
    const PIO2_2: f64 = f64::from_bits(0x3DD0_B461_1A60_0000);
    const PIO2_2T: f64 = f64::from_bits(0x3BA3_198A_2E03_7073);
    const PIO2_3: f64 = f64::from_bits(0x3BA3_198A_2E00_0000);
    const PIO2_3T: f64 = f64::from_bits(0x397B_839A_2520_49C1);
    let hx = high(x);
    let ix = hx & 0x7fff_ffff;
    if ix <= 0x3fe9_21fb {
        return Some((0, x, 0.0));
    }
    if ix < 0x4002_d97c {
        // |x| < 3 pi/4: n is 1 or -1.
        let sign = if hx > 0 { 1.0 } else { -1.0 };
        let mut z = x - sign * PIO2_1;
        let (y0, y1) = if ix != 0x3ff9_21fb {
            let y0 = z - sign * PIO2_1T;
            (y0, (z - y0) - sign * PIO2_1T)
        } else {
            z -= sign * PIO2_2;
            let y0 = z - sign * PIO2_2T;
            (y0, (z - y0) - sign * PIO2_2T)
        };
        return Some((if hx > 0 { 1 } else { -1 }, y0, y1));
    }
    if ix > 0x4139_21fb {
        return None;
    }
    let t = x.abs();
    let n = (t * INVPIO2 + 0.5) as i32;
    let f = n as f64;
    let mut r = t - f * PIO2_1;
    let mut w = f * PIO2_1T;
    let mut y0 = r - w;
    if n >= 32 || ix == NPIO2_HW[n as usize - 1] {
        let j = ix >> 20;
        let mut i = j - ((high(y0) >> 20) & 0x7ff);
        if i > 16 {
            let t = r;
            w = f * PIO2_2;
            r = t - w;
            w = f * PIO2_2T - ((t - r) - w);
            y0 = r - w;
            i = j - ((high(y0) >> 20) & 0x7ff);
            if i > 49 {
                let t = r;
                w = f * PIO2_3;
                r = t - w;
                w = f * PIO2_3T - ((t - r) - w);
                y0 = r - w;
            }
        }
    }
    let y1 = (r - y0) - w;
    Some(if hx < 0 { (-n, -y0, -y1) } else { (n, y0, y1) })
}

/// `StrictMath.sin` (beyond 2^19 pi/2, which worldgen never reaches, the
/// platform's).
pub fn sin(x: f64) -> f64 {
    if high(x) & 0x7fff_ffff <= 0x3fe9_21fb {
        return kernel_sin(x, 0.0, false);
    }
    if !x.is_finite() {
        return f64::NAN;
    }
    match rem_pio2(x) {
        Some((n, y0, y1)) => match n & 3 {
            0 => kernel_sin(y0, y1, true),
            1 => kernel_cos(y0, y1),
            2 => -kernel_sin(y0, y1, true),
            _ => -kernel_cos(y0, y1),
        },
        None => x.sin(),
    }
}

/// `StrictMath.cos` (beyond 2^19 pi/2 the platform's).
pub fn cos(x: f64) -> f64 {
    if high(x) & 0x7fff_ffff <= 0x3fe9_21fb {
        return kernel_cos(x, 0.0);
    }
    if !x.is_finite() {
        return f64::NAN;
    }
    match rem_pio2(x) {
        Some((n, y0, y1)) => match n & 3 {
            0 => kernel_cos(y0, y1),
            1 => -kernel_sin(y0, y1, true),
            2 => -kernel_cos(y0, y1),
            _ => kernel_sin(y0, y1, true),
        },
        None => x.cos(),
    }
}

/// `StrictMath.asin` (fdlibm's `__ieee754_asin`).
pub fn asin(x: f64) -> f64 {
    const PIO2_HI: f64 = f64::from_bits(0x3FF9_21FB_5444_2D18);
    const PIO2_LO: f64 = f64::from_bits(0x3C91_A626_3314_5C07);
    const PIO4_HI: f64 = f64::from_bits(0x3FE9_21FB_5444_2D18);
    const PS0: f64 = f64::from_bits(0x3FC5_5555_5555_5555);
    const PS1: f64 = f64::from_bits(0xBFD4_D612_03EB_6F7D);
    const PS2: f64 = f64::from_bits(0x3FC9_C155_0E88_4455);
    const PS3: f64 = f64::from_bits(0xBFA4_8228_B568_8F3B);
    const PS4: f64 = f64::from_bits(0x3F49_EFE0_7501_B288);
    const PS5: f64 = f64::from_bits(0x3F02_3DE1_0DFD_F709);
    const QS1: f64 = f64::from_bits(0xC003_3A27_1C8A_2D4B);
    const QS2: f64 = f64::from_bits(0x4000_2AE5_9C59_8AC8);
    const QS3: f64 = f64::from_bits(0xBFE6_066C_1B8D_0159);
    const QS4: f64 = f64::from_bits(0x3FB3_B8C5_B12E_9282);
    let hx = high(x);
    let ix = hx & 0x7fff_ffff;
    let rational = |t: f64| {
        let p = t * (PS0 + t * (PS1 + t * (PS2 + t * (PS3 + t * (PS4 + t * PS5)))));
        let q = 1.0 + t * (QS1 + t * (QS2 + t * (QS3 + t * QS4)));
        (p, q)
    };
    if ix >= 0x3ff0_0000 {
        if (ix - 0x3ff0_0000) as u32 | x.to_bits() as u32 == 0 {
            return x * PIO2_HI + x * PIO2_LO;
        }
        return f64::NAN;
    }
    if ix < 0x3fe0_0000 {
        if ix < 0x3e40_0000 {
            return x;
        }
        let t = x * x;
        let (p, q) = rational(t);
        return x + x * (p / q);
    }
    let w = 1.0 - x.abs();
    let t = w * 0.5;
    let (p, q) = rational(t);
    let s = t.sqrt();
    let t = if ix >= 0x3FEF_3333 {
        let w = p / q;
        PIO2_HI - (2.0 * (s + s * w) - PIO2_LO)
    } else {
        let w = f64::from_bits(s.to_bits() & 0xffff_ffff_0000_0000);
        let c = (t - w * w) / (s + w);
        let r = p / q;
        let p = 2.0 * s * r - (PIO2_LO - 2.0 * c);
        let q = PIO4_HI - 2.0 * w;
        PIO4_HI - (p - q)
    };
    if hx > 0 {
        t
    } else {
        -t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asin_equals_strict_math() {
        // (i, StrictMath.asin(i / 256), StrictMath.cos of it) as bits, from
        // Java 25: Mth.atan2's table, where the platform's asin differs.
        const CASES: [(u32, u64, u64); 8] = [
            (0, 0x0000000000000000, 0x3ff0000000000000),
            (27, 0x3fbb0ce107d3f690, 0x3fefd24f61ba0590),
            (28, 0x3fbc0e5e80f7172d, 0x3fefceda421efdb5),
            (58, 0x3fcd4106cba45b08, 0x3fef2afafa9380f9),
            (61, 0x3fcecbd75b6cd8f0, 0x3fef140a0a086af0),
            (128, 0x3fe0c152382d7366, 0x3febb67ae8584caa),
            (249, 0x3ff561ebd9c18cd3, 0x3fcdba59d10bfe0a),
            (256, 0x3ff921fb54442d18, 0x3c91a62633145c07),
        ];
        for (i, a, c) in CASES {
            let v = asin(i as f64 / 256.0);
            assert_eq!(v.to_bits(), a, "asin({i}/256)");
            assert_eq!(cos(v).to_bits(), c, "cos(asin({i}/256))");
        }
    }

    #[test]
    fn sin_and_cos_equal_strict_math() {
        // (x, StrictMath.sin(x), StrictMath.cos(x)) as bits, from Java 25:
        // small arguments, the thresholds, quadrants, an iceberg's angle on
        // which a JVM intrinsic's cosine differs, and medium arguments
        // (millions more of each kind agree, see VMC-025).
        const CASES: [(u64, u64, u64); 16] = [
            (0x0000000000000000, 0x0000000000000000, 0x3ff0000000000000),
            (0x3e112e0be826d695, 0x3e112e0be826d695, 0x3ff0000000000000),
            (0x3fd3333333333333, 0x3fd2e9cd95baba33, 0x3fee921dd42f09ba),
            (0x3fe921fb54442d18, 0x3fe6a09e667f3bcc, 0x3fe6a09e667f3bcd),
            (0x3fe999999999999a, 0x3fe6f494c2bffecd, 0x3fe64b6bde719865),
            (0x3ff921fb54442d18, 0x3ff0000000000000, 0x3c91a62633145c07),
            (0x4000000000000000, 0x3fed18f6ead1b446, 0xbfdaa22657537205),
            (0x400921fb54442d18, 0x3ca1a62633145c07, 0xbff0000000000000),
            (0xc004000000000000, 0xbfe326af0dcfcab0, 0xbfe9a2f7ef858b7d),
            (0x4017f59617ce0033, 0xbfd281afd43c7969, 0x3feea207d952d9e3),
            (0x401921fb54442d18, 0xbcb1a62633145c07, 0x3ff0000000000000),
            (0x4059000000000000, 0xbfe03425b78c4db8, 0x3feb981dbf665fdf),
            (0xc0934a456d5cfaad, 0xbfb3fa00084ee3dd, 0xbfefe7053dc31387),
            (0x4127f7ec00000000, 0xbfc4d26a0e83f7e1, 0x3fef92e296a78ec8),
            (0x40d2efdec30a2e8a, 0x3ff0000000000000, 0x3d77a454a054c327),
            (0x4012d97c7f3321d2, 0xbff0000000000000, 0xbcaa79394c9e8a0a),
        ];
        for (x, s, c) in CASES {
            let x = f64::from_bits(x);
            assert_eq!(sin(x).to_bits(), s, "sin {x}");
            assert_eq!(cos(x).to_bits(), c, "cos {x}");
        }
    }

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
