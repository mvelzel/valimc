//! Carvers (VMC-024c): vanilla's cave and canyon carvers, which mark a
//! chunk's carving mask from the carvers started in the chunks around it,
//! drawing their shapes from value providers (`providers`). Applying the mask
//! to the chunk is `Worldgen::build_terrain`'s last step.

use std::sync::OnceLock;

use super::json::Json;
use super::random::Random;

/// `Mth.SIN`: 65,536 sines of a full turn, as floats.
fn sin_table() -> &'static [f32] {
    static TABLE: OnceLock<Vec<f32>> = OnceLock::new();
    TABLE.get_or_init(|| {
        (0..65536)
            .map(|i| (i as f64 / 10430.378350470453).sin() as f32)
            .collect()
    })
}

/// `Mth.sin`.
pub fn sin(v: f64) -> f32 {
    sin_table()[((v * 10430.378350470453) as i64 & 65535) as usize]
}

/// `Mth.cos`.
pub fn cos(v: f64) -> f32 {
    sin_table()[((v * 10430.378350470453 + 16384.0) as i64 & 65535) as usize]
}

const PI_F: f32 = std::f64::consts::PI as f32;
const TAU_F: f32 = (std::f64::consts::PI * 2.0) as f32;
const HALF_PI_F: f32 = (std::f64::consts::PI / 2.0) as f32;

pub use super::providers::{FloatProvider, GenContext, HeightProvider, IntProvider};

#[derive(Clone, Debug)]
pub struct Cave {
    pub probability: f32,
    pub y: HeightProvider,
    pub count: IntProvider,
    pub thickness: FloatProvider,
    pub weird_thickness_bias: bool,
    pub room_vertical_radius_multiplier: FloatProvider,
    pub horizontal_radius_multiplier: FloatProvider,
    pub vertical_radius_multiplier: FloatProvider,
    pub start_vertical_radius_multiplier: FloatProvider,
    pub floor_level: FloatProvider,
}

#[derive(Clone, Debug)]
pub struct Canyon {
    pub probability: f32,
    pub y: HeightProvider,
    pub vertical_rotation: FloatProvider,
    pub distance_factor: FloatProvider,
    pub thickness: FloatProvider,
    pub width_smoothness: i32,
    pub horizontal_radius_factor: FloatProvider,
    pub vertical_radius_default_factor: f32,
    pub vertical_radius_center_factor: f32,
    pub y_scale: FloatProvider,
}

#[derive(Clone, Debug)]
pub enum Carver {
    Cave(Box<Cave>),
    Canyon(Box<Canyon>),
}

impl Carver {
    pub fn parse(json: &Json) -> Result<Carver, String> {
        let float = |k: &str| FloatProvider::parse(json.field(k)?);
        let probability = json.field("probability")?.as_f64()? as f32;
        let y = HeightProvider::parse(json.field("y")?)?;
        match json.field("type")?.as_str()? {
            "minecraft:cave" | "minecraft:nether_cave" => Ok(Carver::Cave(Box::new(Cave {
                probability,
                y,
                count: IntProvider::parse(json.field("count")?)?,
                thickness: float("thickness")?,
                weird_thickness_bias: json
                    .get("weird_thickness_bias")
                    .map_or(Ok(false), Json::as_bool)?,
                room_vertical_radius_multiplier: float("room_vertical_radius_multiplier")?,
                horizontal_radius_multiplier: float("horizontal_radius_multiplier")?,
                vertical_radius_multiplier: float("vertical_radius_multiplier")?,
                start_vertical_radius_multiplier: match json.get("start_vertical_radius_multiplier")
                {
                    Some(j) => FloatProvider::parse(j)?,
                    None => FloatProvider::Constant(1.0),
                },
                floor_level: float("floor_level")?,
            }))),
            "minecraft:canyon" => {
                let shape = json.field("shape")?;
                let sf = |k: &str| FloatProvider::parse(shape.field(k)?);
                Ok(Carver::Canyon(Box::new(Canyon {
                    probability,
                    y,
                    vertical_rotation: float("vertical_rotation")?,
                    distance_factor: sf("distance_factor")?,
                    thickness: sf("thickness")?,
                    width_smoothness: shape.field("width_smoothness")?.as_i32()?,
                    horizontal_radius_factor: sf("horizontal_radius_factor")?,
                    vertical_radius_default_factor: shape
                        .field("vertical_radius_default_factor")?
                        .as_f64()? as f32,
                    vertical_radius_center_factor: shape
                        .field("vertical_radius_center_factor")?
                        .as_f64()? as f32,
                    y_scale: sf("y_scale")?,
                })))
            }
            other => Err(format!("unsupported carver {other}")),
        }
    }

    /// `isStartChunk`.
    pub fn is_start(&self, random: &mut Random) -> bool {
        let p = match self {
            Carver::Cave(c) => c.probability,
            Carver::Canyon(c) => c.probability,
        };
        random.next_float() <= p
    }

    /// `carve`: marks `mask` for the chunk `(chunk_x, chunk_z)` from a carver
    /// started in `source`.
    pub fn carve(
        &self,
        c: GenContext,
        random: &mut Random,
        chunk: (i32, i32),
        source: (i32, i32),
        mask: &mut CarvingMask,
    ) {
        match self {
            Carver::Cave(cave) => cave.carve(c, random, chunk, source, mask),
            Carver::Canyon(canyon) => canyon.carve(c, random, chunk, source, mask),
        }
    }
}

/// `WorldgenRandom.setLargeFeatureSeed`.
pub fn set_large_feature_seed(random: &mut Random, seed: i64, x: i32, z: i32) {
    random.set_seed(seed);
    let a = random.next_long();
    let b = random.next_long();
    random.set_seed((x as i64).wrapping_mul(a) ^ (z as i64).wrapping_mul(b) ^ seed);
}

/// The carving mask (vanilla's `CarvingMask`): one bit per position of the
/// chunk between `min_y` and `max_y`.
pub struct CarvingMask {
    pub min_y: i32,
    pub max_y: i32,
    height: i32,
    bits: Vec<bool>,
}

impl CarvingMask {
    pub fn new(min_y: i32, max_y: i32) -> CarvingMask {
        let height = max_y - min_y + 1;
        CarvingMask {
            min_y,
            max_y,
            height,
            bits: vec![false; (256 * height.max(0)) as usize],
        }
    }

    fn set(&mut self, x: i32, y: i32, z: i32) {
        self.bits[(y - self.min_y + (z + (x << 4)) * self.height) as usize] = true;
    }

    pub fn is_empty(&self) -> bool {
        !self.bits.contains(&true)
    }

    /// `visit`: each run of set bits, column by column in index order, as
    /// (x, z, bottom y, top y).
    pub fn segments(&self) -> Vec<(i32, i32, i32, i32)> {
        let mut out = Vec::new();
        let n = self.bits.len();
        let mut i = 0;
        while i < n {
            if !self.bits[i] {
                i += 1;
                continue;
            }
            let start = i;
            while i < n && self.bits[i] {
                i += 1;
            }
            let end = i - 1;
            let h = self.height as usize;
            for column in start / h..=end / h {
                let base = column * h;
                let bottom = (start.max(base) - base) as i32 + self.min_y;
                let top = (end - base).min(h - 1) as i32 + self.min_y;
                out.push((
                    ((column >> 4) & 15) as i32,
                    (column & 15) as i32,
                    bottom,
                    top,
                ));
            }
        }
        out
    }
}

/// `WorldCarver.carveEllipsoid`.
#[allow(clippy::too_many_arguments)]
fn carve_ellipsoid(
    chunk: (i32, i32),
    x: f64,
    y: f64,
    z: f64,
    horizontal: f64,
    vertical: f64,
    mask: &mut CarvingMask,
    skip: &dyn Fn(f64, f64, f64, i32) -> bool,
) {
    let (min_x, min_z) = (chunk.0 * 16, chunk.1 * 16);
    let (center_x, center_z) = ((min_x + 8) as f64, (min_z + 8) as f64);
    let max_delta = 16.0 + horizontal * 2.0;
    if (x - center_x).abs() > max_delta || (z - center_z).abs() > max_delta {
        return;
    }
    let floor = |v: f64| v.floor() as i32;
    let min_xi = (floor(x - horizontal) - min_x - 1).max(0);
    let max_xi = (floor(x + horizontal) - min_x).min(15);
    let min_y = (floor(y - vertical) - 1).max(mask.min_y);
    let max_y = (floor(y + vertical) + 1).min(mask.max_y);
    let min_zi = (floor(z - horizontal) - min_z - 1).max(0);
    let max_zi = (floor(z + horizontal) - min_z).min(15);
    for xi in min_xi..=max_xi {
        let xd = ((min_x + xi) as f64 + 0.5 - x) / horizontal;
        for zi in min_zi..=max_zi {
            let zd = ((min_z + zi) as f64 + 0.5 - z) / horizontal;
            if xd * xd + zd * zd >= 1.0 {
                continue;
            }
            let mut wy = max_y;
            while wy > min_y {
                let yd = (wy as f64 - 0.5 - y) / vertical;
                if !skip(xd, yd, zd, wy) {
                    mask.set(xi, wy, zi);
                }
                wy -= 1;
            }
        }
    }
}

/// `WorldCarver.canReach`.
fn can_reach(chunk: (i32, i32), x: f64, z: f64, step: i32, total: i32, thickness: f32) -> bool {
    let xd = x - (chunk.0 * 16 + 8) as f64;
    let zd = z - (chunk.1 * 16 + 8) as f64;
    let remaining = (total - step) as f64;
    let rr = (thickness + 2.0 + 16.0) as f64;
    xd * xd + zd * zd - remaining * remaining <= rr * rr
}

impl Cave {
    fn carve(
        &self,
        c: GenContext,
        random: &mut Random,
        chunk: (i32, i32),
        source: (i32, i32),
        mask: &mut CarvingMask,
    ) {
        let max_distance = (4 * 2 - 1) * 16;
        let count = self.count.sample(random);
        for _ in 0..count {
            let x = (source.0 * 16 + random.next_int_bounded(16)) as f64;
            let y = self.y.sample(random, c) as f64;
            let z = (source.1 * 16 + random.next_int_bounded(16)) as f64;
            let horizontal = self.horizontal_radius_multiplier.sample(random) as f64;
            let vertical = self.vertical_radius_multiplier.sample(random) as f64;
            let start_vertical = self.start_vertical_radius_multiplier.sample(random) as f64;
            let floor_level = self.floor_level.sample(random) as f64;
            let skip = move |xd: f64, yd: f64, zd: f64, _y: i32| {
                yd <= floor_level || xd * xd + yd * yd + zd * zd >= 1.0
            };
            let mut tunnels = 1;
            if random.next_int_bounded(4) == 0 {
                let y_scale = self.room_vertical_radius_multiplier.sample(random) as f64;
                let thickness = 1.0 + random.next_float() * 6.0;
                let radius = 1.5 + (sin(HALF_PI_F as f64) * thickness) as f64;
                carve_ellipsoid(chunk, x + 1.0, y, z, radius, radius * y_scale, mask, &skip);
                tunnels += random.next_int_bounded(4);
            }
            for _ in 0..tunnels {
                let horizontal_rotation = random.next_float() * TAU_F;
                let vertical_rotation = (random.next_float() - 0.5) / 4.0;
                let thickness = self.thickness_sample(random);
                let distance = max_distance - random.next_int_bounded(max_distance / 4);
                let seed = random.next_long();
                self.tunnel(
                    chunk,
                    seed,
                    (x, y, z),
                    (horizontal, vertical),
                    thickness,
                    horizontal_rotation,
                    vertical_rotation,
                    0,
                    distance,
                    start_vertical,
                    mask,
                    &skip,
                );
            }
        }
    }

    fn thickness_sample(&self, random: &mut Random) -> f32 {
        let mut thickness = self.thickness.sample(random);
        if self.weird_thickness_bias && random.next_int_bounded(10) == 0 {
            let a = random.next_float();
            let b = random.next_float();
            thickness *= a * b * 3.0 + 1.0;
        }
        thickness
    }

    #[allow(clippy::too_many_arguments)]
    fn tunnel(
        &self,
        chunk: (i32, i32),
        seed: i64,
        (mut x, mut y, mut z): (f64, f64, f64),
        (horizontal_mul, vertical_mul): (f64, f64),
        thickness: f32,
        mut horizontal_rotation: f32,
        mut vertical_rotation: f32,
        step: i32,
        distance: i32,
        y_scale: f64,
        mask: &mut CarvingMask,
        skip: &dyn Fn(f64, f64, f64, i32) -> bool,
    ) {
        let mut random = Random::legacy(seed);
        let split = random.next_int_bounded(distance / 2) + distance / 4;
        let steep = random.next_int_bounded(6) == 0;
        let (mut y_rota, mut x_rota) = (0.0f32, 0.0f32);
        for current in step..distance {
            let horizontal =
                1.5 + (sin((PI_F * current as f32 / distance as f32) as f64) * thickness) as f64;
            let vertical = horizontal * y_scale;
            let cos_x = cos(vertical_rotation as f64);
            x += (cos(horizontal_rotation as f64) * cos_x) as f64;
            y += sin(vertical_rotation as f64) as f64;
            z += (sin(horizontal_rotation as f64) * cos_x) as f64;
            vertical_rotation *= if steep { 0.92 } else { 0.7 };
            vertical_rotation += x_rota * 0.1;
            horizontal_rotation += y_rota * 0.1;
            x_rota *= 0.9;
            y_rota *= 0.75;
            let (a, b, c) = (
                random.next_float(),
                random.next_float(),
                random.next_float(),
            );
            x_rota += (a - b) * c * 2.0;
            let (a, b, c) = (
                random.next_float(),
                random.next_float(),
                random.next_float(),
            );
            y_rota += (a - b) * c * 4.0;
            if current == split && thickness > 1.0 {
                for turn in [-HALF_PI_F, HALF_PI_F] {
                    let seed = random.next_long();
                    let branch = random.next_float() * 0.5 + 0.5;
                    self.tunnel(
                        chunk,
                        seed,
                        (x, y, z),
                        (horizontal_mul, vertical_mul),
                        branch,
                        horizontal_rotation + turn,
                        vertical_rotation / 3.0,
                        current,
                        distance,
                        1.0,
                        mask,
                        skip,
                    );
                }
                return;
            }
            if random.next_int_bounded(4) != 0 {
                if !can_reach(chunk, x, z, current, distance, thickness) {
                    return;
                }
                carve_ellipsoid(
                    chunk,
                    x,
                    y,
                    z,
                    horizontal * horizontal_mul,
                    vertical * vertical_mul,
                    mask,
                    skip,
                );
            }
        }
    }
}

impl Canyon {
    fn carve(
        &self,
        c: GenContext,
        random: &mut Random,
        chunk: (i32, i32),
        source: (i32, i32),
        mask: &mut CarvingMask,
    ) {
        let max_distance = (4 * 2 - 1) * 16;
        let x = (source.0 * 16 + random.next_int_bounded(16)) as f64;
        let y = self.y.sample(random, c) as f64;
        let z = (source.1 * 16 + random.next_int_bounded(16)) as f64;
        let horizontal_rotation = random.next_float() * TAU_F;
        let vertical_rotation = self.vertical_rotation.sample(random);
        let y_scale = self.y_scale.sample(random) as f64;
        let thickness = self.thickness.sample(random);
        let distance = (max_distance as f32 * self.distance_factor.sample(random)) as i32;
        let seed = random.next_long();
        self.tunnel(
            c,
            chunk,
            seed,
            (x, y, z),
            thickness,
            horizontal_rotation,
            vertical_rotation,
            distance,
            y_scale,
            mask,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn tunnel(
        &self,
        c: GenContext,
        chunk: (i32, i32),
        seed: i64,
        (mut x, mut y, mut z): (f64, f64, f64),
        thickness: f32,
        mut horizontal_rotation: f32,
        mut vertical_rotation: f32,
        distance: i32,
        y_scale: f64,
        mask: &mut CarvingMask,
    ) {
        let mut random = Random::legacy(seed);
        let mut widths = vec![0.0f32; c.height.max(0) as usize];
        let mut width = 1.0f32;
        for (i, w) in widths.iter_mut().enumerate() {
            if i == 0 || random.next_int_bounded(self.width_smoothness) == 0 {
                let a = random.next_float();
                width = 1.0 + a * random.next_float();
            }
            *w = width * width;
        }
        let min_y = c.min_y;
        let skip = |xd: f64, yd: f64, zd: f64, wy: i32| {
            let index = (wy - min_y) as usize;
            (xd * xd + zd * zd) * widths[index - 1] as f64 + yd * yd / 6.0 >= 1.0
        };
        let (mut y_rota, mut x_rota) = (0.0f32, 0.0f32);
        for current in 0..distance {
            let mut horizontal =
                1.5 + (sin((current as f32 * PI_F / distance as f32) as f64) * thickness) as f64;
            let vertical = horizontal * y_scale;
            horizontal *= self.horizontal_radius_factor.sample(&mut random) as f64;
            let multiplier = 1.0 - (0.5 - current as f32 / distance as f32).abs() * 2.0;
            let factor = self.vertical_radius_default_factor
                + self.vertical_radius_center_factor * multiplier;
            let between = random.next_float() * (1.0 - 0.75) + 0.75;
            let vertical = factor as f64 * vertical * between as f64;
            let xc = cos(vertical_rotation as f64);
            let xs = sin(vertical_rotation as f64);
            x += (cos(horizontal_rotation as f64) * xc) as f64;
            y += xs as f64;
            z += (sin(horizontal_rotation as f64) * xc) as f64;
            vertical_rotation *= 0.7;
            vertical_rotation += x_rota * 0.05;
            horizontal_rotation += y_rota * 0.05;
            x_rota *= 0.8;
            y_rota *= 0.5;
            let (a, b, d) = (
                random.next_float(),
                random.next_float(),
                random.next_float(),
            );
            x_rota += (a - b) * d * 2.0;
            let (a, b, d) = (
                random.next_float(),
                random.next_float(),
                random.next_float(),
            );
            y_rota += (a - b) * d * 4.0;
            if random.next_int_bounded(4) != 0 {
                if !can_reach(chunk, x, z, current, distance, thickness) {
                    return;
                }
                carve_ellipsoid(chunk, x, y, z, horizontal, vertical, mask, &skip);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worldgen::random::sha256;

    #[test]
    fn sine_table_equals_vanillas() {
        let bytes: Vec<u8> = sin_table()
            .iter()
            .flat_map(|v| v.to_bits().to_be_bytes())
            .collect();
        let hex: String = sha256(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        // SHA-256 of vanilla 26.3's Mth.SIN (big-endian float bits).
        assert_eq!(
            hex,
            "87a67a39fff59636acb04edcda4ef622831037291f11fb61586c57596771dac2"
        );
    }

    #[test]
    fn mask_segments_run_across_columns() {
        let mut mask = CarvingMask::new(0, 3);
        mask.set(0, 2, 0);
        mask.set(0, 3, 0);
        mask.set(0, 0, 1);
        mask.set(0, 2, 1);
        assert_eq!(
            mask.segments(),
            vec![(0, 0, 2, 3), (0, 1, 0, 0), (0, 1, 2, 2)]
        );
    }
}
