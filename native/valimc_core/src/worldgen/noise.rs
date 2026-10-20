//! Gradient noises of 26.3 world generation (VMC-023b): the float Perlin noise
//! (`PerlinNoise` over `GradientNoise`) and its smeared variant
//! (`SmearedPerlinNoise`), octave stacks (`NoiseStack`), normal noises built from
//! noise parameters (`NormalNoise`, including the legacy nether initialiser) and
//! the octave sets of blended terrain noise (`BlendedNoise`).
//!
//! Every value matches vanilla bit for bit, so the arithmetic follows vanilla's
//! exactly: which operations run in `f32` and which in `f64`, in what order, and
//! the separate point (`get`) and volume (`add_to_volume`) paths, which round
//! differently.

use super::java::{clamp, fmax};
use super::json::Json;
use super::random::Random;
use super::volume::{Volume, X, Y, Z};

/// The 16 gradient directions, indexed by the low four bits of a hash.
const GRADIENTS: [[f32; 3]; 16] = [
    [1.0, 1.0, 0.0],
    [-1.0, 1.0, 0.0],
    [1.0, -1.0, 0.0],
    [-1.0, -1.0, 0.0],
    [1.0, 0.0, 1.0],
    [-1.0, 0.0, 1.0],
    [1.0, 0.0, -1.0],
    [-1.0, 0.0, -1.0],
    [0.0, 1.0, 1.0],
    [0.0, -1.0, 1.0],
    [0.0, 1.0, -1.0],
    [0.0, -1.0, -1.0],
    [1.0, 1.0, 0.0],
    [0.0, -1.0, 1.0],
    [-1.0, 1.0, 0.0],
    [0.0, -1.0, -1.0],
];

/// Input coordinates wrap with this period, so far-away samples stay precise.
const ROUND_OFF: f64 = 33_554_432.0;
/// The largest double below 2^24.
const HALF_ROUND_OFF: f64 = f64::from_bits(0x416F_FFFF_FFFF_FFFF);
/// Smeared noise nudges the fudge limit up by this float epsilon.
const SHIFT_UP_EPSILON: f64 = 1.0e-7_f32 as f64;
/// A normal noise's second octave set runs at this frequency factor.
const INPUT_FACTOR: f64 = 1.0181268882175227;
/// The standard deviation of one Perlin octave.
const STANDARD_DEVIATION: f64 = 0.2702247831245211;
const TARGET_DEVIATION: f64 = 0.3333333333333333;
/// The legacy nether initialiser skips the random draws of a dropped octave.
const LEGACY_OCTAVE_DRAWS: i32 = 262;

fn wrap(x: f64) -> f64 {
    if (-HALF_ROUND_OFF..HALF_ROUND_OFF).contains(&x) {
        x
    } else {
        x - (x / ROUND_OFF + 0.5).floor() * ROUND_OFF
    }
}

/// `Mth.floor`: Java's saturating double-to-int cast.
fn floor(x: f64) -> i32 {
    x.floor() as i32
}

/// 2^n for -1022 <= n <= 1023, exactly as `Math.pow(2.0, n)`.
fn pow2(n: i32) -> f64 {
    f64::from_bits(((n + 1023) as u64) << 52)
}

fn smoothstep(x: f32) -> f32 {
    x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
}

pub(crate) fn lerp(alpha: f32, p0: f32, p1: f32) -> f32 {
    p0 + alpha * (p1 - p0)
}

fn lerp2(a1: f32, a2: f32, x00: f32, x10: f32, x01: f32, x11: f32) -> f32 {
    lerp(a2, lerp(a1, x00, x10), lerp(a1, x01, x11))
}

/// `Mth.lerp3`; corners in the order 000, 100, 010, 110, 001, 101, 011, 111.
pub(crate) fn lerp3(a1: f32, a2: f32, a3: f32, c: [f32; 8]) -> f32 {
    lerp(
        a3,
        lerp2(a1, a2, c[0], c[1], c[2], c[3]),
        lerp2(a1, a2, c[4], c[5], c[6], c[7]),
    )
}

fn dot(g: [f32; 3], x: f32, y: f32, z: f32) -> f32 {
    g[0] * x + g[1] * y + g[2] * z
}

fn dot_xz(g: [f32; 3], x: f32, z: f32) -> f32 {
    g[0] * x + g[2] * z
}

/// `DoubleStream.sum` (JDK 18+): Kahan summation with negated compensation.
fn stream_sum(values: impl Iterator<Item = f64>) -> f64 {
    let (mut sum, mut compensation, mut simple) = (0.0f64, 0.0f64, 0.0f64);
    for value in values {
        let tmp = value - compensation;
        let next = sum + tmp;
        compensation = (next - sum) - tmp;
        sum = next;
        simple += value;
    }
    let total = sum - compensation;
    if total.is_nan() && simple.is_infinite() {
        simple
    } else {
        total
    }
}

/// `GradientNoise`'s state: a random offset per axis, then a shuffled
/// permutation.
fn gradient_base(random: &mut Random, offset_scale: f64) -> ([u8; 256], [f64; 3]) {
    let ox = random.next_double() * offset_scale;
    let oy = random.next_double() * offset_scale;
    let oz = random.next_double() * offset_scale;
    let mut perms = [0u8; 256];
    for (i, p) in perms.iter_mut().enumerate() {
        *p = i as u8;
    }
    for i in 0..256 {
        let offset = random.next_int_bounded(256 - i as i32) as usize;
        perms.swap(i, i + offset);
    }
    (perms, [ox, oy, oz])
}

/// One Perlin octave: a permutation and a random offset. With `smear`, it is
/// vanilla's `SmearedPerlinNoise`, whose Y gradients use a fudged relative Y.
#[derive(Clone, Debug)]
pub struct Perlin {
    perms: [u8; 256],
    offset: [f64; 3],
    smear: Option<f64>,
}

impl Perlin {
    pub fn new(random: &mut Random) -> Self {
        Self::build(random, None)
    }

    pub fn smeared(random: &mut Random, fudge_y_scale: f64) -> Self {
        Self::build(random, Some(fudge_y_scale))
    }

    fn build(random: &mut Random, smear: Option<f64>) -> Self {
        let (perms, offset) = gradient_base(random, 256.0);
        Perlin {
            perms,
            offset,
            smear,
        }
    }

    fn permute(&self, x: i32) -> i32 {
        self.perms[(x & 0xFF) as usize] as i32
    }

    fn gradient(&self, x: i32) -> [f32; 3] {
        GRADIENTS[(self.permute(x) & 15) as usize]
    }

    fn fudge_y(scale: f64, original_y: f64, relative_y: f64) -> f64 {
        let limit = if original_y >= 0.0 && original_y < relative_y {
            original_y
        } else {
            relative_y
        };
        floor(limit / scale + SHIFT_UP_EPSILON) as f64 * scale
    }

    /// The relative Y the Y gradients use: smeared noise subtracts the fudge.
    fn gradient_y(&self, original_y: f64, relative_y: f64) -> f32 {
        match self.smear {
            None => relative_y as f32,
            Some(scale) => (relative_y - Self::fudge_y(scale, original_y, relative_y)) as f32,
        }
    }

    pub fn get(&self, x: f64, y: f64, z: f64) -> f32 {
        let wx = wrap(x) + self.offset[X];
        let wy = wrap(y) + self.offset[Y];
        let wz = wrap(z) + self.offset[Z];
        let (fx, fy, fz) = (floor(wx), floor(wy), floor(wz));
        let rx = (wx - fx as f64) as f32;
        let ry = wy - fy as f64;
        let rz = (wz - fz as f64) as f32;
        self.sample(fx, fy, fz, rx, self.gradient_y(y, ry), rz, ry as f32)
    }

    /// The two-dimensional sample: X and Z, at Y 0.
    pub fn get_2d(&self, x: f64, z: f64) -> f32 {
        self.get(wrap(x), 0.0, wrap(z))
    }

    #[allow(clippy::too_many_arguments)]
    fn sample(&self, x: i32, y: i32, z: i32, rx: f32, ry: f32, rz: f32, alpha_ry: f32) -> f32 {
        let x0 = self.permute(x);
        let x1 = self.permute(x.wrapping_add(1));
        let xy00 = self.permute(x0.wrapping_add(y));
        let xy01 = self.permute(x0.wrapping_add(y).wrapping_add(1));
        let xy10 = self.permute(x1.wrapping_add(y));
        let xy11 = self.permute(x1.wrapping_add(y).wrapping_add(1));
        let g = |xy: i32, dz: i32| self.gradient(xy.wrapping_add(z).wrapping_add(dz));
        let corners = [
            dot(g(xy00, 0), rx, ry, rz),
            dot(g(xy10, 0), rx - 1.0, ry, rz),
            dot(g(xy01, 0), rx, ry - 1.0, rz),
            dot(g(xy11, 0), rx - 1.0, ry - 1.0, rz),
            dot(g(xy00, 1), rx, ry, rz - 1.0),
            dot(g(xy10, 1), rx - 1.0, ry, rz - 1.0),
            dot(g(xy01, 1), rx, ry - 1.0, rz - 1.0),
            dot(g(xy11, 1), rx - 1.0, ry - 1.0, rz - 1.0),
        ];
        lerp3(
            smoothstep(rx),
            smoothstep(alpha_ry),
            smoothstep(rz),
            corners,
        )
    }

    /// Adds `amplitude` times the noise at every position of `volume`, scaled
    /// by `xz_scale` and `y_scale`, to `buffer`. Gradients split into their XZ
    /// dot product and Y component, as vanilla's volume path does.
    pub fn add_to_volume(
        &self,
        buffer: &mut [f32],
        volume: &Volume,
        xz_scale: f64,
        y_scale: f64,
        amplitude: f32,
    ) {
        let mut index = 0;
        let mut xz = [0.0f32; 8];
        let mut gy = [0.0f32; 8];
        for iz in 0..volume.size[Z] {
            let wz = wrap(volume.block(Z, iz) as f64 * xz_scale) + self.offset[Z];
            let fz = floor(wz);
            let rz = (wz - fz as f64) as f32;
            let alpha_z = smoothstep(rz);
            for ix in 0..volume.size[X] {
                let wx = wrap(volume.block(X, ix) as f64 * xz_scale) + self.offset[X];
                let fx = floor(wx);
                let rx = (wx - fx as f64) as f32;
                let x0 = self.permute(fx);
                let x1 = self.permute(fx.wrapping_add(1));
                let alpha_x = smoothstep(rx);
                let mut last_fy = None;
                for iy in 0..volume.size[Y] {
                    let original_y = volume.block(Y, iy) as f64 * y_scale;
                    let wy = wrap(original_y) + self.offset[Y];
                    let fy = floor(wy);
                    let ry = wy - fy as f64;
                    let alpha_y = smoothstep(ry as f32);
                    if last_fy != Some(fy) {
                        let xy00 = self.permute(x0.wrapping_add(fy));
                        let xy01 = self.permute(x0.wrapping_add(fy).wrapping_add(1));
                        let xy10 = self.permute(x1.wrapping_add(fy));
                        let xy11 = self.permute(x1.wrapping_add(fy).wrapping_add(1));
                        let corners = [
                            (xy00, 0, rx, rz),
                            (xy10, 0, rx - 1.0, rz),
                            (xy01, 0, rx, rz),
                            (xy11, 0, rx - 1.0, rz),
                            (xy00, 1, rx, rz - 1.0),
                            (xy10, 1, rx - 1.0, rz - 1.0),
                            (xy01, 1, rx, rz - 1.0),
                            (xy11, 1, rx - 1.0, rz - 1.0),
                        ];
                        for (c, (xy, dz, cx, cz)) in corners.into_iter().enumerate() {
                            let g = self.gradient(xy.wrapping_add(fz).wrapping_add(dz));
                            xz[c] = dot_xz(g, cx, cz);
                            gy[c] = g[1];
                        }
                        last_fy = Some(fy);
                    }
                    let ty = self.gradient_y(original_y, ry);
                    let corners = [
                        xz[0] + gy[0] * ty,
                        xz[1] + gy[1] * ty,
                        xz[2] + gy[2] * (ty - 1.0),
                        xz[3] + gy[3] * (ty - 1.0),
                        xz[4] + gy[4] * ty,
                        xz[5] + gy[5] * ty,
                        xz[6] + gy[6] * (ty - 1.0),
                        xz[7] + gy[7] * (ty - 1.0),
                    ];
                    buffer[index] += amplitude * lerp3(alpha_x, alpha_y, alpha_z, corners);
                    index += 1;
                }
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Octave {
    pub noise: Perlin,
    pub frequency: f64,
    pub amplitude: f32,
}

/// Octaves summed in order (vanilla's `NoiseStack`).
#[derive(Clone, Debug, Default)]
pub struct Stack {
    pub octaves: Vec<Octave>,
}

impl Stack {
    fn add(&mut self, noise: Perlin, frequency: f64, amplitude: f32) {
        self.octaves.push(Octave {
            noise,
            frequency,
            amplitude,
        });
    }

    pub fn get(&self, x: f64, y: f64, z: f64) -> f32 {
        let mut value = 0.0f32;
        for o in &self.octaves {
            let f = o.frequency;
            value += o.amplitude * o.noise.get(x * f, y * f, z * f);
        }
        value
    }

    pub fn get_2d(&self, x: f64, z: f64) -> f32 {
        let mut value = 0.0f32;
        for o in &self.octaves {
            let f = o.frequency;
            value += o.amplitude * o.noise.get_2d(x * f, z * f);
        }
        value
    }

    pub fn add_to_volume(
        &self,
        buffer: &mut [f32],
        volume: &Volume,
        xz_scale: f64,
        y_scale: f64,
        amplitude: f32,
    ) {
        for o in &self.octaves {
            let f = o.frequency;
            o.noise.add_to_volume(
                buffer,
                volume,
                xz_scale * f,
                y_scale * f,
                amplitude * o.amplitude,
            );
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Normalization {
    Disabled,
    Enabled,
    /// Earlier releases' normalisation, kept for worlds that depend on it.
    Legacy,
}

/// A normal noise's parameters (the `worldgen/noise` registry entries).
#[derive(Clone, Debug, PartialEq)]
pub struct NoiseParameters {
    pub base_amplitude: f64,
    pub base_octave: i32,
    pub octave_count: i32,
    pub normalize: Normalization,
    /// Empty, or one modifier per octave.
    pub amplitude_modifiers: Vec<f64>,
}

impl NoiseParameters {
    fn modifier(&self, i: i32) -> f64 {
        if self.amplitude_modifiers.is_empty() {
            1.0
        } else {
            self.amplitude_modifiers[i as usize]
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct OctaveInfo {
    index: i32,
    frequency: f64,
    amplitude: f64,
}

/// A normal noise: two sets of Perlin octaves, the second at a slightly
/// higher frequency, scaled so the sum has a target deviation.
#[derive(Clone, Debug)]
pub struct NormalNoise {
    parameters: NoiseParameters,
    octaves: Vec<OctaveInfo>,
    normalization: f64,
    target_amplitude: f64,
}

impl NormalNoise {
    pub fn new(parameters: NoiseParameters) -> Result<Self, String> {
        let p = &parameters;
        if !(-32..=32).contains(&p.base_octave) || !(1..=32).contains(&p.octave_count) {
            return Err(format!("noise octaves out of range: {p:?}"));
        }
        if !p.amplitude_modifiers.is_empty()
            && p.amplitude_modifiers.len() != p.octave_count as usize
        {
            return Err(format!(
                "amplitude modifiers do not match the octave count: {p:?}"
            ));
        }
        let octaves = Self::octaves(p, p.normalize != Normalization::Disabled);
        let mut target = stream_sum(octaves.iter().map(|o| o.amplitude.abs()));
        let mut normalization = Self::normalization(target, &octaves);
        if p.normalize == Normalization::Legacy && normalization != 0.0 {
            let parity = Self::parity_normalization(p);
            target *= parity / normalization;
            normalization = parity;
        }
        Ok(NormalNoise {
            parameters,
            octaves,
            normalization,
            target_amplitude: target,
        })
    }

    fn octaves(p: &NoiseParameters, normalize: bool) -> Vec<OctaveInfo> {
        let mut frequency = pow2(p.base_octave);
        let mut amplitude = p.base_amplitude;
        if normalize {
            amplitude *= pow2(p.octave_count - 1) / (pow2(p.octave_count) - 1.0);
        }
        let mut octaves = Vec::with_capacity(p.octave_count as usize);
        for i in 0..p.octave_count {
            let modifier = p.modifier(i);
            if modifier != 0.0 {
                octaves.push(OctaveInfo {
                    index: p.base_octave + i,
                    frequency,
                    amplitude: amplitude * modifier,
                });
            }
            frequency *= 2.0;
            amplitude *= 0.5;
        }
        octaves
    }

    fn normalization(target: f64, octaves: &[OctaveInfo]) -> f64 {
        let mut variance = 0.0f64;
        for o in octaves {
            let deviation = STANDARD_DEVIATION * o.amplitude.abs();
            variance += deviation * deviation;
        }
        let deviation = variance.sqrt();
        if deviation == 0.0 {
            return 0.0;
        }
        let input_sum_deviation = deviation * 2.0f64.sqrt();
        target * TARGET_DEVIATION / input_sum_deviation
    }

    fn parity_normalization(p: &NoiseParameters) -> f64 {
        let used: Vec<i32> = (0..p.octave_count)
            .filter(|&i| p.modifier(i) != 0.0)
            .collect();
        let span = used
            .last()
            .unwrap_or(&i32::MIN)
            .wrapping_sub(*used.first().unwrap_or(&i32::MAX));
        let expected_deviation = 0.1 * (1.0 + 1.0 / span.wrapping_add(1) as f64);
        p.base_amplitude * 0.5 * TARGET_DEVIATION / expected_deviation
    }

    pub fn parameters(&self) -> &NoiseParameters {
        &self.parameters
    }

    /// The bound of the noise's symmetric value range (vanilla's `range()`).
    pub fn range_bound(&self) -> f32 {
        (self.target_amplitude * TARGET_DEVIATION * 6.0) as f32
    }

    /// Parses vanilla's codec encoding of noise parameters (defaults omitted).
    pub fn parse(json: &Json) -> Result<NormalNoise, String> {
        let number = |key: &str, default: f64| json.get(key).map_or(Ok(default), Json::as_f64);
        let normalize = match json.get("normalize") {
            None | Some(Json::Bool(true)) => Normalization::Enabled,
            Some(Json::Bool(false)) => Normalization::Disabled,
            Some(Json::String(s)) if s == "legacy" => Normalization::Legacy,
            Some(other) => return Err(format!("unknown normalization {other:?}")),
        };
        let amplitude_modifiers = match json.get("amplitude_modifiers") {
            None => vec![],
            Some(list) => list
                .as_array()?
                .iter()
                .map(Json::as_f64)
                .collect::<Result<_, _>>()?,
        };
        NormalNoise::new(NoiseParameters {
            base_amplitude: number("base_amplitude", 1.0)?,
            base_octave: json.field("base_octave")?.as_i32()?,
            octave_count: json.get("octave_count").map_or(Ok(1), Json::as_i32)?,
            normalize,
            amplitude_modifiers,
        })
    }

    /// The octave stack for `random` (vanilla's `NormalNoise.create`): two
    /// positional factories, each octave seeded from the hash of its name.
    pub fn create(&self, random: &mut Random) -> Stack {
        let first = random.fork_positional();
        let second = random.fork_positional();
        let mut stack = Stack::default();
        for o in &self.octaves {
            let name = format!("octave_{}", o.index);
            let a = Perlin::new(&mut first.from_hash_of(&name));
            let b = Perlin::new(&mut second.from_hash_of(&name));
            let value_factor = (self.normalization * o.amplitude) as f32;
            stack.add(a, o.frequency, value_factor);
            stack.add(b, o.frequency * INPUT_FACTOR, value_factor);
        }
        stack
    }

    /// The octave stack of the legacy nether climate noises, drawn in sequence
    /// from one random (vanilla's `createForLegacyNetherBiome`).
    pub fn create_legacy_nether(&self, random: &mut Random) -> Result<Stack, String> {
        let p = &self.parameters;
        let amplitudes = if p.amplitude_modifiers.is_empty() {
            vec![1.0; p.octave_count as usize]
        } else {
            p.amplitude_modifiers.clone()
        };
        let first = legacy_fbm(random, p.base_octave, &amplitudes)?;
        let second = legacy_fbm(random, p.base_octave, &amplitudes)?;
        let value_factor = (self.normalization * p.base_amplitude) as f32;
        let mut stack = Stack::default();
        for (set, factor) in [(first, 1.0), (second, INPUT_FACTOR)] {
            for o in set.octaves {
                stack.add(o.noise, o.frequency * factor, o.amplitude * value_factor);
            }
        }
        Ok(stack)
    }
}

fn legacy_fbm(random: &mut Random, first_octave: i32, amplitudes: &[f64]) -> Result<Stack, String> {
    let octaves = amplitudes.len() as i32;
    let zero_index = -first_octave;
    let mut levels: Vec<Option<Perlin>> = vec![None; amplitudes.len()];
    let zero = Perlin::new(random);
    if (0..octaves).contains(&zero_index) && amplitudes[zero_index as usize] != 0.0 {
        levels[zero_index as usize] = Some(zero);
    }
    for i in (0..zero_index).rev() {
        if i < octaves && amplitudes[i as usize] != 0.0 {
            levels[i as usize] = Some(Perlin::new(random));
        } else {
            random.consume_count(LEGACY_OCTAVE_DRAWS);
        }
    }
    let made = levels.iter().filter(|l| l.is_some()).count();
    if made != amplitudes.iter().filter(|&&a| a != 0.0).count() {
        return Err("legacy noise levels do not match the non-zero amplitudes".into());
    }
    if zero_index < octaves - 1 {
        return Err("legacy noise has positive octaves".into());
    }
    let mut factor = pow2(-zero_index);
    let mut value_factor = pow2(octaves - 1) / (pow2(octaves) - 1.0);
    let mut stack = Stack::default();
    for (level, amplitude) in levels.into_iter().zip(amplitudes) {
        if let Some(noise) = level {
            stack.add(noise, factor, (value_factor * amplitude) as f32);
        }
        factor *= 2.0;
        value_factor /= 2.0;
    }
    Ok(stack)
}

/// Blended terrain noise's parameters (`minecraft:old_blended_noise`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlendedParameters {
    pub xz_scale: f64,
    pub y_scale: f64,
    pub xz_factor: f64,
    pub y_factor: f64,
    pub smear_scale_multiplier: f64,
}

/// The three smeared octave stacks of blended noise.
#[derive(Clone, Debug)]
pub struct FbmSet {
    pub min_limit: Stack,
    pub max_limit: Stack,
    pub main: Stack,
}

const BLENDED_BASE_SCALE: f64 = 684.412;
const BLENDED_LIMIT_FACTOR: f64 = 0.99998474_f32 as f64;
const BLENDED_MAIN_FACTOR: f64 = 12.75;

impl BlendedParameters {
    pub fn xz_multiplier(&self) -> f64 {
        BLENDED_BASE_SCALE * self.xz_scale
    }

    pub fn y_multiplier(&self) -> f64 {
        BLENDED_BASE_SCALE * self.y_scale
    }

    pub fn fbm_set(&self, random: &mut Random) -> FbmSet {
        let limit_smear_y = self.y_multiplier() * self.smear_scale_multiplier;
        let main_smear_y = limit_smear_y / self.y_factor;
        let min_limit = smeared_fbm(random, -15, limit_smear_y, BLENDED_LIMIT_FACTOR);
        let max_limit = smeared_fbm(random, -15, limit_smear_y, BLENDED_LIMIT_FACTOR);
        let main = smeared_fbm(random, -7, main_smear_y, BLENDED_MAIN_FACTOR);
        FbmSet {
            min_limit,
            max_limit,
            main,
        }
    }
}

/// Octaves from the finest down, each drawn from `random` in sequence.
fn smeared_fbm(random: &mut Random, first_octave: i32, smear_y: f64, value_factor: f64) -> Stack {
    let octaves = -first_octave + 1;
    let mut factor = 1.0f64;
    let mut value_factor = value_factor / (pow2(octaves) - 1.0);
    let mut stack = Stack::default();
    for _ in 0..octaves {
        stack.add(
            Perlin::smeared(random, smear_y * factor),
            factor,
            value_factor as f32,
        );
        factor /= 2.0;
        value_factor *= 2.0;
    }
    stack
}

/// Two-dimensional simplex noise (vanilla's `SimplexNoise.get(x, y)`), used
/// by the End's outer islands.
#[derive(Clone, Debug)]
pub struct Simplex {
    perms: [u8; 256],
    offset: [f64; 3],
}

impl Simplex {
    /// `discard_offset` draws the offsets but scales them to zero, as the End
    /// island noise does.
    pub fn new(random: &mut Random, discard_offset: bool) -> Self {
        let (perms, offset) = gradient_base(random, if discard_offset { 0.0 } else { 256.0 });
        Simplex { perms, offset }
    }

    fn permute(&self, x: i32) -> i32 {
        self.perms[(x & 0xFF) as usize] as i32
    }

    fn corner(index: i32, x: f64, y: f64, base: f64) -> f64 {
        let mut t = base - x * x - y * y - 0.0 * 0.0;
        if t < 0.0 {
            return 0.0;
        }
        t *= t;
        let g = GRADIENTS[index as usize];
        t * t * (g[0] as f64 * x + g[1] as f64 * y + g[2] as f64 * 0.0)
    }

    pub fn get_2d(&self, x: f64, y: f64) -> f32 {
        let sqrt3 = 3.0f64.sqrt();
        let f2 = 0.5 * (sqrt3 - 1.0);
        let g2 = (3.0 - sqrt3) / 6.0;
        let xin = x + self.offset[X];
        let yin = y + self.offset[Y];
        let s = (xin + yin) * f2;
        let i = floor(xin + s);
        let j = floor(yin + s);
        let t = i.wrapping_add(j) as f64 * g2;
        let x0 = xin - (i as f64 - t);
        let y0 = yin - (j as f64 - t);
        let (i1, j1) = if x0 > y0 { (1, 0) } else { (0, 1) };
        let x1 = x0 - i1 as f64 + g2;
        let y1 = y0 - j1 as f64 + g2;
        let x2 = x0 - 1.0 + 2.0 * g2;
        let y2 = y0 - 1.0 + 2.0 * g2;
        let (ii, jj) = (i & 0xFF, j & 0xFF);
        let gi0 = self.permute(ii + self.permute(jj)) % 12;
        let gi1 = self.permute(ii + i1 + self.permute(jj + j1)) % 12;
        let gi2 = self.permute(ii + 1 + self.permute(jj + 1)) % 12;
        let n0 = Self::corner(gi0, x0, y0, 0.5);
        let n1 = Self::corner(gi1, x1, y1, 0.5);
        let n2 = Self::corner(gi2, x2, y2, 0.5);
        (70.0 * (n0 + n1 + n2)) as f32
    }
}

/// The End's island height at a 8-block section (`EndIslandFunction`).
pub fn end_island_height(noise: &Simplex, section_x: i32, section_z: i32) -> f32 {
    let (chunk_x, chunk_z) = (section_x / 2, section_z / 2);
    let (sub_x, sub_z) = (section_x % 2, section_z % 2);
    let mut height = -100.0f32;
    for xo in -12..=12 {
        for zo in -12..=12 {
            let tx = chunk_x.wrapping_add(xo) as i64;
            let tz = chunk_z.wrapping_add(zo) as i64;
            if tx * tx + tz * tz > 4096 && noise.get_2d(tx as f64, tz as f64) < -0.9 {
                let size = ((tx as f32).abs() * 3439.0 + (tz as f32).abs() * 147.0) % 13.0 + 9.0;
                let xd = (sub_x - xo * 2) as f32;
                let zd = (sub_z - zo * 2) as f32;
                let candidate = 100.0 - ((xd * xd + zd * zd) as f64).sqrt() as f32 * size;
                height = fmax(height, clamp(candidate, -100.0, 80.0));
            }
        }
    }
    height
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_keeps_near_values_and_folds_far_ones() {
        assert_eq!(wrap(12.5), 12.5);
        assert_eq!(wrap(-16_777_215.5), -16_777_215.5);
        assert_eq!(wrap(16_777_216.0), -16_777_216.0);
        assert_eq!(wrap(33_554_432.0 + 3.25), 3.25);
        assert_eq!(wrap(-33_554_432.0 * 5.0 - 1.0), -1.0);
    }

    #[test]
    fn pow2_is_exact() {
        for n in -40..=40 {
            assert_eq!(pow2(n), 2.0f64.powi(n));
        }
    }

    #[test]
    fn stream_sum_compensates() {
        assert_eq!(stream_sum([0.5, 0.25, 0.125].into_iter()), 0.875);
        assert_eq!(stream_sum(std::iter::empty()), 0.0);
        // Compensation recovers the 0.1s a plain sum loses (Java gives 1.0).
        assert_eq!(stream_sum(std::iter::repeat_n(0.1, 10)), 1.0);
    }

    #[test]
    fn permutation_is_a_permutation() {
        let noise = Perlin::new(&mut Random::xoroshiro(7));
        let mut seen = [false; 256];
        for &p in &noise.perms {
            seen[p as usize] = true;
        }
        assert!(seen.iter().all(|&s| s));
    }

    #[test]
    fn volume_and_point_paths_agree_closely() {
        let noise = Perlin::new(&mut Random::xoroshiro(20261020));
        let volume = Volume::new([3, 9, 2], [-5, -64, 17], [4, 8, 4]).unwrap();
        let mut buffer = vec![0.0f32; volume.len()];
        noise.add_to_volume(&mut buffer, &volume, 0.25, 0.125, 1.0);
        for iz in 0..2 {
            for ix in 0..3 {
                for iy in 0..9 {
                    let point = noise.get(
                        volume.block(X, ix) as f64 * 0.25,
                        volume.block(Y, iy) as f64 * 0.125,
                        volume.block(Z, iz) as f64 * 0.25,
                    );
                    let v = buffer[volume.index(ix, iy, iz)];
                    assert!((v - point).abs() < 1.0e-5, "{v} vs {point}");
                }
            }
        }
    }

    #[test]
    fn legacy_normalisation_changes_the_factor() {
        let mut p = NoiseParameters {
            base_amplitude: 1.0,
            base_octave: -7,
            octave_count: 2,
            normalize: Normalization::Enabled,
            amplitude_modifiers: vec![],
        };
        let enabled = NormalNoise::new(p.clone()).unwrap().normalization;
        p.normalize = Normalization::Legacy;
        let legacy = NormalNoise::new(p).unwrap().normalization;
        assert!(enabled > 0.0 && legacy > 0.0 && enabled != legacy);
    }
}
