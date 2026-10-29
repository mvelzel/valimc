//! A mob's own random (VMC-081d): vanilla's `LegacyRandomSource`, Java's
//! 48-bit linear congruential generator, so a mob draws the sequence
//! vanilla's would from the same seed (`Valimc.AI.Random`). The state is the
//! saved integer; a new mob seeds it from its uuid's first eight bytes.

const MULTIPLIER: u64 = 0x5DEECE66D;
const MASK: u64 = (1 << 48) - 1;

/// A legacy random's 48-bit state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LegacyRandom {
    pub seed: u64,
}

impl LegacyRandom {
    /// `setSeed(seed)`.
    pub fn new(seed: i64) -> Self {
        LegacyRandom {
            seed: (seed as u64 ^ MULTIPLIER) & MASK,
        }
    }

    /// Seeded from a uuid's first eight bytes, as a new mob's is.
    pub fn from_uuid(uuid: &[u8; 16]) -> Self {
        let mut first = [0u8; 8];
        first.copy_from_slice(&uuid[..8]);
        Self::new(i64::from_be_bytes(first))
    }

    /// A saved state (`Random.valid?`).
    pub fn from_state(state: u64) -> Option<Self> {
        (state <= MASK).then_some(LegacyRandom { seed: state })
    }

    /// `next(bits)`.
    pub fn next(&mut self, bits: u32) -> i32 {
        self.seed = self.seed.wrapping_mul(MULTIPLIER).wrapping_add(0xB) & MASK;
        ((self.seed as i64) >> (48 - bits)) as i32
    }

    /// `nextInt(bound)`.
    pub fn int(&mut self, bound: i32) -> i32 {
        debug_assert!(bound > 0);
        if bound & (bound - 1) == 0 {
            return ((bound as i64 * self.next(31) as i64) >> 31) as i32;
        }
        loop {
            let bits = self.next(31);
            let value = bits % bound;
            if bits.wrapping_sub(value).wrapping_add(bound - 1) >= 0 {
                return value;
            }
        }
    }

    /// `nextFloat()`: 24 bits.
    pub fn float(&mut self) -> f32 {
        self.next(24) as f32 * 5.9604645E-8_f32
    }

    /// `nextDouble()`: 53 bits.
    pub fn double(&mut self) -> f64 {
        let upper = self.next(26) as i64;
        let lower = self.next(27) as i64;
        ((upper << 27) + lower) as f64 * 1.1102230246251565E-16
    }

    /// `nextBoolean()`.
    pub fn boolean(&mut self) -> bool {
        self.next(1) != 0
    }

    /// `nextLong()`.
    pub fn long(&mut self) -> i64 {
        let upper = self.next(32) as i64;
        let lower = self.next(32) as i64;
        upper.wrapping_shl(32).wrapping_add(lower)
    }

    /// `nextGaussian()` (`MarsagliaPolarGaussian`): the pair's second value is
    /// held in `held` for the next call, as the mind holds it.
    pub fn gaussian(&mut self, held: &mut Option<f64>) -> f64 {
        if let Some(value) = held.take() {
            return value;
        }
        loop {
            let v1 = 2.0 * self.double() - 1.0;
            let v2 = 2.0 * self.double() - 1.0;
            let s = v1 * v1 + v2 * v2;
            if s < 1.0 && s != 0.0 {
                let multiplier = (-2.0 * s.ln() / s).sqrt();
                *held = Some(v2 * multiplier);
                return v1 * multiplier;
            }
        }
    }

    /// `LivingEntity.getVoicePitch`: `(nextFloat() - nextFloat()) * 0.2 + base`.
    pub fn voice_pitch(&mut self, base: f32) -> f32 {
        let a = self.float();
        let b = self.float();
        (a - b) * 0.2 + base
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The same draws `Valimc.AI.Random` (checked against vanilla's) makes.
    #[test]
    fn draws_what_the_elixir_random_draws() {
        let mut r = LegacyRandom::new(42);
        assert_eq!(r.int(100), 30);
        assert_eq!(r.int(7), 5);
        assert_eq!(r.float() as f64, 0.6832234263420105);
        assert_eq!(r.double(), 0.047939305137387644);
        assert_eq!(r.long(), -1068554554583376509);
        assert!(r.boolean());
        assert_eq!(LegacyRandom::new(0).int(16), 11);
        assert_eq!(
            LegacyRandom::new(7).voice_pitch(1.0) as f64,
            1.0184322595596313
        );
    }
}
