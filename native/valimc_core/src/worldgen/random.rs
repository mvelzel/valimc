//! Vanilla's random sources (VMC-023a), from `javap -c` of the pinned jar:
//! `XoroshiroRandomSource` (Xoroshiro128++ seeded through Stafford13 mixing),
//! `LegacyRandomSource` (Java's 48-bit LCG), their positional factories, and the
//! Marsaglia polar Gaussian both share.

const GOLDEN_RATIO_64: u64 = 0x9E37_79B9_7F4A_7C15;
const SILVER_RATIO_64: u64 = 0x6A09_E667_F3BC_C909;

pub fn mix_stafford13(seed: u64) -> u64 {
    let mut s = (seed ^ (seed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    s = (s ^ (s >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    s ^ (s >> 31)
}

/// A 64-bit seed as 128 bits: `seed ^ silver`, `+ golden`, each Stafford13-mixed.
pub fn upgrade_seed(seed: i64) -> (u64, u64) {
    let lo = seed as u64 ^ SILVER_RATIO_64;
    let hi = lo.wrapping_add(GOLDEN_RATIO_64);
    (mix_stafford13(lo), mix_stafford13(hi))
}

/// MD5 of `text` (UTF-8) as two big-endian halves (`RandomSupport.seedFromHashOf`).
pub fn seed_from_hash(text: &str) -> (u64, u64) {
    let digest = md5(text.as_bytes());
    (
        u64::from_be_bytes(digest[..8].try_into().unwrap()),
        u64::from_be_bytes(digest[8..].try_into().unwrap()),
    )
}

/// Java `String.hashCode` over UTF-16 code units.
pub fn java_string_hash(text: &str) -> i32 {
    text.encode_utf16()
        .fold(0i32, |h, unit| h.wrapping_mul(31).wrapping_add(unit as i32))
}

/// `Mth.getSeed`: the legacy position hash.
pub fn position_seed(x: i32, y: i32, z: i32) -> i64 {
    let mut l =
        (x.wrapping_mul(3_129_871) as i64) ^ (z as i64).wrapping_mul(116_129_781) ^ y as i64;
    l = l
        .wrapping_mul(l)
        .wrapping_mul(42_317_861)
        .wrapping_add(l.wrapping_mul(11));
    l >> 16
}

#[derive(Clone, Debug)]
struct Gaussian {
    next: f64,
    have_next: bool,
}

impl Gaussian {
    fn new() -> Self {
        Gaussian {
            next: 0.0,
            have_next: false,
        }
    }
}

#[derive(Clone, Debug)]
enum State {
    /// Xoroshiro128++ (lo, hi).
    Xoroshiro(u64, u64),
    /// The 48-bit LCG seed.
    Legacy(u64),
    /// `WorldgenRandom` over a Xoroshiro source (lo, hi): the legacy
    /// algorithms on `next(bits)`, the top bits of Xoroshiro's `nextLong`.
    Worldgen(u64, u64),
}

/// A random source, as vanilla's `RandomSource` implementations behave.
#[derive(Clone, Debug)]
pub struct Random {
    state: State,
    gaussian: Gaussian,
}

const LCG_MULTIPLIER: u64 = 0x5_DEEC_E66D;
const LCG_MASK: u64 = (1 << 48) - 1;

impl Random {
    /// `new XoroshiroRandomSource(seed)`.
    pub fn xoroshiro(seed: i64) -> Self {
        let (lo, hi) = upgrade_seed(seed);
        Self::xoroshiro128(lo, hi)
    }

    /// `new XoroshiroRandomSource(lo, hi)`; an all-zero state takes vanilla's fallback.
    pub fn xoroshiro128(lo: u64, hi: u64) -> Self {
        let (lo, hi) = if lo | hi == 0 {
            (GOLDEN_RATIO_64, SILVER_RATIO_64)
        } else {
            (lo, hi)
        };
        Random {
            state: State::Xoroshiro(lo, hi),
            gaussian: Gaussian::new(),
        }
    }

    /// `new LegacyRandomSource(seed)`.
    pub fn legacy(seed: i64) -> Self {
        Random {
            state: State::Legacy((seed as u64 ^ LCG_MULTIPLIER) & LCG_MASK),
            gaussian: Gaussian::new(),
        }
    }

    /// A legacy random at its 48-bit state (as `legacy_state` gave it).
    pub fn legacy_at(state: u64) -> Self {
        Random {
            state: State::Legacy(state & LCG_MASK),
            gaussian: Gaussian::new(),
        }
    }

    /// A legacy random's 48-bit state, `None` for the other kinds.
    pub fn legacy_state(&self) -> Option<u64> {
        match self.state {
            State::Legacy(seed) => Some(seed),
            _ => None,
        }
    }

    /// `new WorldgenRandom(new XoroshiroRandomSource(seed))`.
    pub fn worldgen(seed: i64) -> Self {
        let (lo, hi) = upgrade_seed(seed);
        Random {
            state: State::Worldgen(lo, hi),
            gaussian: Gaussian::new(),
        }
    }

    pub fn set_seed(&mut self, seed: i64) {
        *self = match self.state {
            State::Xoroshiro(..) => Self::xoroshiro(seed),
            State::Legacy(_) => Self::legacy(seed),
            // Vanilla reseeds the inner source only; the Gaussian state stays.
            State::Worldgen(..) => {
                let (lo, hi) = upgrade_seed(seed);
                Random {
                    state: State::Worldgen(lo, hi),
                    gaussian: self.gaussian.clone(),
                }
            }
        };
    }

    /// `WorldgenRandom.setDecorationSeed`: reseeds for a chunk origin and
    /// returns the decoration seed.
    pub fn set_decoration_seed(&mut self, seed: i64, x: i32, z: i32) -> i64 {
        self.set_seed(seed);
        let a = self.next_long() | 1;
        let b = self.next_long() | 1;
        let result = ((x as i64).wrapping_mul(a)).wrapping_add((z as i64).wrapping_mul(b)) ^ seed;
        self.set_seed(result);
        result
    }

    /// `WorldgenRandom.setFeatureSeed`.
    pub fn set_feature_seed(&mut self, seed: i64, index: i32, step: i32) {
        self.set_seed(
            seed.wrapping_add(index as i64)
                .wrapping_add(10000i32.wrapping_mul(step) as i64),
        );
    }

    /// The legacy `next(bits)` of a `WorldgenRandom` over Xoroshiro.
    fn next_bits_worldgen(lo: &mut u64, hi: &mut u64, bits: u32) -> i32 {
        (Self::xoroshiro_next(lo, hi) >> (64 - bits)) as i32
    }

    fn xoroshiro_next(lo: &mut u64, hi: &mut u64) -> u64 {
        let (l, mut h) = (*lo, *hi);
        let result = l.wrapping_add(h).rotate_left(17).wrapping_add(l);
        h ^= l;
        *lo = l.rotate_left(49) ^ h ^ (h << 21);
        *hi = h.rotate_left(28);
        result
    }

    /// The legacy `next(bits)`: the top `bits` of the advanced 48-bit seed.
    fn next_bits_legacy(seed: &mut u64, bits: u32) -> i32 {
        *seed = seed.wrapping_mul(LCG_MULTIPLIER).wrapping_add(11) & LCG_MASK;
        ((*seed as i64) >> (48 - bits)) as i32
    }

    pub fn next_long(&mut self) -> i64 {
        match &mut self.state {
            State::Xoroshiro(lo, hi) => Self::xoroshiro_next(lo, hi) as i64,
            State::Legacy(seed) => {
                let high = Self::next_bits_legacy(seed, 32) as i64;
                let low = Self::next_bits_legacy(seed, 32) as i64;
                (high << 32).wrapping_add(low)
            }
            State::Worldgen(lo, hi) => {
                let high = Self::next_bits_worldgen(lo, hi, 32) as i64;
                let low = Self::next_bits_worldgen(lo, hi, 32) as i64;
                (high << 32).wrapping_add(low)
            }
        }
    }

    pub fn next_int(&mut self) -> i32 {
        match &mut self.state {
            State::Xoroshiro(lo, hi) => Self::xoroshiro_next(lo, hi) as i32,
            State::Legacy(seed) => Self::next_bits_legacy(seed, 32),
            State::Worldgen(lo, hi) => Self::next_bits_worldgen(lo, hi, 32),
        }
    }

    /// `nextInt(bound)`, `bound > 0`: Lemire's method for Xoroshiro, Java's for legacy.
    pub fn next_int_bounded(&mut self, bound: i32) -> i32 {
        assert!(bound > 0, "bound must be positive");
        match &mut self.state {
            State::Xoroshiro(..) => {
                let mut product = (self.next_int() as u32 as u64) * bound as u64;
                let mut low = product & 0xFFFF_FFFF;
                if low < bound as u64 {
                    let threshold = (bound.wrapping_neg() as u32 % bound as u32) as u64;
                    while low < threshold {
                        product = (self.next_int() as u32 as u64) * bound as u64;
                        low = product & 0xFFFF_FFFF;
                    }
                }
                (product >> 32) as i32
            }
            State::Legacy(seed) => {
                if bound & (bound - 1) == 0 {
                    return ((bound as i64 * Self::next_bits_legacy(seed, 31) as i64) >> 31) as i32;
                }
                loop {
                    let bits = Self::next_bits_legacy(seed, 31);
                    let value = bits % bound;
                    if bits.wrapping_sub(value).wrapping_add(bound - 1) >= 0 {
                        return value;
                    }
                }
            }
            State::Worldgen(lo, hi) => {
                if bound & (bound - 1) == 0 {
                    return ((bound as i64 * Self::next_bits_worldgen(lo, hi, 31) as i64) >> 31)
                        as i32;
                }
                loop {
                    let bits = Self::next_bits_worldgen(lo, hi, 31);
                    let value = bits % bound;
                    if bits.wrapping_sub(value).wrapping_add(bound - 1) >= 0 {
                        return value;
                    }
                }
            }
        }
    }

    pub fn next_bool(&mut self) -> bool {
        match &mut self.state {
            State::Xoroshiro(lo, hi) => Self::xoroshiro_next(lo, hi) & 1 != 0,
            State::Legacy(seed) => Self::next_bits_legacy(seed, 1) != 0,
            State::Worldgen(lo, hi) => Self::next_bits_worldgen(lo, hi, 1) != 0,
        }
    }

    pub fn next_float(&mut self) -> f32 {
        match &mut self.state {
            State::Xoroshiro(lo, hi) => {
                (Self::xoroshiro_next(lo, hi) >> 40) as f32 * 5.960_464_5e-8_f32
            }
            State::Legacy(seed) => Self::next_bits_legacy(seed, 24) as f32 * 5.960_464_5e-8_f32,
            State::Worldgen(lo, hi) => {
                Self::next_bits_worldgen(lo, hi, 24) as f32 * 5.960_464_5e-8_f32
            }
        }
    }

    pub fn next_double(&mut self) -> f64 {
        match &mut self.state {
            State::Xoroshiro(lo, hi) => {
                (Self::xoroshiro_next(lo, hi) >> 11) as f64 * 1.110_223_024_625_156_5e-16
            }
            State::Legacy(seed) => {
                let high = Self::next_bits_legacy(seed, 26) as i64;
                let low = Self::next_bits_legacy(seed, 27) as i64;
                ((high << 27) + low) as f64 * 1.110_223_024_625_156_5e-16
            }
            State::Worldgen(lo, hi) => {
                let high = Self::next_bits_worldgen(lo, hi, 26) as i64;
                let low = Self::next_bits_worldgen(lo, hi, 27) as i64;
                ((high << 27) + low) as f64 * 1.110_223_024_625_156_5e-16
            }
        }
    }

    pub fn next_gaussian(&mut self) -> f64 {
        if self.gaussian.have_next {
            self.gaussian.have_next = false;
            return self.gaussian.next;
        }
        loop {
            let a = 2.0 * self.next_double() - 1.0;
            let b = 2.0 * self.next_double() - 1.0;
            let s = a * a + b * b;
            if s < 1.0 && s != 0.0 {
                let multiplier = (-2.0 * s.ln() / s).sqrt();
                self.gaussian.next = b * multiplier;
                self.gaussian.have_next = true;
                return a * multiplier;
            }
        }
    }

    pub fn consume_count(&mut self, count: i32) {
        for _ in 0..count.max(0) {
            match &mut self.state {
                State::Xoroshiro(lo, hi) => {
                    Self::xoroshiro_next(lo, hi);
                }
                State::Legacy(_) | State::Worldgen(..) => {
                    self.next_int();
                }
            }
        }
    }

    pub fn fork(&mut self) -> Random {
        match self.state {
            // `WorldgenRandom` forks its inner Xoroshiro source.
            State::Xoroshiro(..) | State::Worldgen(..) => {
                let (lo, hi) = self.inner_longs();
                Random::xoroshiro128(lo, hi)
            }
            State::Legacy(_) => Random::legacy(self.next_long()),
        }
    }

    /// Two longs of the (inner) Xoroshiro source, for its forks.
    fn inner_longs(&mut self) -> (u64, u64) {
        match &mut self.state {
            State::Xoroshiro(lo, hi) | State::Worldgen(lo, hi) => {
                let a = Self::xoroshiro_next(lo, hi);
                let b = Self::xoroshiro_next(lo, hi);
                (a, b)
            }
            State::Legacy(_) => unreachable!("legacy sources fork from their own longs"),
        }
    }

    pub fn fork_positional(&mut self) -> Positional {
        match self.state {
            State::Xoroshiro(..) | State::Worldgen(..) => {
                let (lo, hi) = self.inner_longs();
                Positional::Xoroshiro(lo, hi)
            }
            State::Legacy(_) => Positional::Legacy(self.next_long()),
        }
    }
}

/// A `PositionalRandomFactory`.
#[derive(Clone, Copy, Debug)]
pub enum Positional {
    Xoroshiro(u64, u64),
    Legacy(i64),
}

impl Positional {
    pub fn at(&self, x: i32, y: i32, z: i32) -> Random {
        let seed = position_seed(x, y, z);
        match *self {
            Positional::Xoroshiro(lo, hi) => Random::xoroshiro128(seed as u64 ^ lo, hi),
            Positional::Legacy(s) => Random::legacy(seed ^ s),
        }
    }

    pub fn from_hash_of(&self, text: &str) -> Random {
        match *self {
            Positional::Xoroshiro(lo, hi) => {
                let (a, b) = seed_from_hash(text);
                Random::xoroshiro128(a ^ lo, b ^ hi)
            }
            Positional::Legacy(s) => Random::legacy(java_string_hash(text) as i64 ^ s),
        }
    }

    pub fn from_seed(&self, seed: i64) -> Random {
        match *self {
            Positional::Xoroshiro(lo, hi) => {
                Random::xoroshiro128(seed as u64 ^ lo, seed as u64 ^ hi)
            }
            Positional::Legacy(_) => Random::legacy(seed),
        }
    }
}

/// SHA-256 (FIPS 180-4).
pub fn sha256(input: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut message = input.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((input.len() as u64) * 8).to_be_bytes());
    for block in message.chunks(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [
                t1.wrapping_add(t2),
                v[0],
                v[1],
                v[2],
                v[3].wrapping_add(t1),
                v[4],
                v[5],
                v[6],
            ];
        }
        for (a, b) in h.iter_mut().zip(v) {
            *a = a.wrapping_add(b);
        }
    }
    let mut out = [0u8; 32];
    for (chunk, word) in out.chunks_mut(4).zip(h) {
        chunk.copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// MD5 (RFC 1321).
pub fn md5(input: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    let k: Vec<u32> = (0..64)
        .map(|i| ((i as f64 + 1.0).sin().abs() * 4_294_967_296.0) as u32)
        .collect();
    let mut message = input.to_vec();
    let bit_length = (input.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend(bit_length.to_le_bytes());
    let (mut a0, mut b0, mut c0, mut d0) = (
        0x6745_2301u32,
        0xEFCD_AB89u32,
        0x98BA_DCFEu32,
        0x1032_5476u32,
    );
    for chunk in message.as_chunks::<64>().0 {
        let m: Vec<u32> = chunk
            .as_chunks::<4>()
            .0
            .iter()
            .map(|w| u32::from_le_bytes(*w))
            .collect();
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    let mut out = [0u8; 16];
    for (i, word) in [a0, b0, c0, d0].iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_reference_digests() {
        let hex = |d: [u8; 16]| d.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(hex(md5(b"")), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(hex(md5(b"abc")), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            hex(md5(b"The quick brown fox jumps over the lazy dog")),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn sha256_reference_digests() {
        let hex = |d: [u8; 32]| d.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(
            hex(sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let long = vec![b'a'; 1000];
        assert_eq!(
            hex(sha256(&long)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        );
    }

    #[test]
    fn java_lcg_matches_java_util_random() {
        // new java.util.Random(42).nextInt() == -1170105035, nextInt(10) twice: 0, 3.
        let mut r = Random::legacy(42);
        assert_eq!(r.next_int(), -1_170_105_035);
        let mut r = Random::legacy(42);
        assert_eq!((r.next_int_bounded(10), r.next_int_bounded(10)), (0, 3));
        assert_eq!(java_string_hash("hello"), 99_162_322);
    }
}
