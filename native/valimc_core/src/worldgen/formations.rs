//! Rock and ice formations (VMC-025c): icebergs, ice spikes, geodes,
//! underwater magma and monster rooms (`IcebergFeature`, `SpikeFeature`,
//! `GeodeFeature`, `UnderwaterMagmaFeature`, `MonsterRoomFeature`), in
//! vanilla's order of reads, writes and random draws.

use std::sync::{Arc, Mutex};

use super::blocks::{BlockSet, BlockTable, OCCLUDES, SOLID, SOLID_RENDER};
use super::feature::Decoration;
use super::json::Json;
use super::noise::{NormalNoise, Stack};
use super::predicate::{offset, BlockPredicate};
use super::providers::IntProvider;
use super::random::Random;
use super::region::Region;
use super::speleothem::Column;
use super::state_provider::StateProvider;

const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];
const UP: usize = 1;
const NORTH: usize = 2;
const SOUTH: usize = 3;
const WEST: usize = 4;
const EAST: usize = 5;
/// `Direction.Plane.HORIZONTAL`.
const HORIZONTAL: [usize; 4] = [NORTH, EAST, SOUTH, WEST];
const FACING: [&str; 6] = ["down", "up", "north", "south", "west", "east"];

/// `Feature.safeSetBlock` with a "not in this set" predicate.
fn safe_set(
    table: &BlockTable,
    region: &mut Region,
    pos: [i32; 3],
    state: u16,
    protected: &BlockSet,
) {
    let current = region.get(pos);
    if !table.in_tag(current, protected) {
        region.set(pos, state, 2);
    }
}

/// `IcebergFeature`.
#[derive(Debug)]
pub struct Iceberg {
    state: u16,
    packed_ice: u16,
    blue_ice: u16,
    ice: u16,
    snow_block: u16,
    snow: u16,
    water: u16,
    snow_block_state: u16,
    air: u16,
    water_state: u16,
}

/// An iceberg's shape, drawn once.
struct Shape {
    origin: [i32; 3],
    snow_on_top: bool,
    angle: f64,
    ellipse_a: i32,
    ellipse_c: i32,
    ellipse: bool,
}

/// `signedDist < 0.0`: a NaN distance (an ellipse axis of 0) is outside.
fn inside(signed: f64) -> bool {
    signed < 0.0
}

/// `Math.pow(v, 2.0)`, which is exactly `v * v`.
fn square(v: f64) -> f64 {
    v * v
}

impl Iceberg {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Iceberg, String> {
        Ok(Iceberg {
            state: table.state(json.field("state")?)?,
            packed_ice: table.block("packed_ice")?,
            blue_ice: table.block("blue_ice")?,
            ice: table.block("ice")?,
            snow_block: table.block("snow_block")?,
            snow: table.block("snow")?,
            water: table.block("water")?,
            snow_block_state: table.default_state("snow_block")?,
            air: table.default_state("air")?,
            water_state: table.default_state("water")?,
        })
    }

    fn is_iceberg(&self, table: &BlockTable, s: u16) -> bool {
        let b = table.block_of(s);
        b == self.packed_ice || b == self.snow_block || b == self.blue_ice
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let origin = [origin[0], d.context().sea_level, origin[2]];
        let snow_on_top = random.next_double() > 0.7;
        let angle = random.next_double() * 2.0 * std::f64::consts::PI;
        let ellipse_a = 11 - random.next_int_bounded(5);
        let ellipse_c = 3 + random.next_int_bounded(3);
        let ellipse = random.next_double() > 0.7;
        let mut over = if ellipse {
            random.next_int_bounded(6) + 6
        } else {
            random.next_int_bounded(15) + 3
        };
        if !ellipse && random.next_double() > 0.9 {
            over += random.next_int_bounded(19) + 7;
        }
        let under = (over + random.next_int_bounded(11)).min(18);
        let width = (over + random.next_int_bounded(7) - random.next_int_bounded(5)).min(11);
        let a = if ellipse { ellipse_a } else { 11 };
        let shape = Shape {
            origin,
            snow_on_top,
            angle,
            ellipse_a,
            ellipse_c,
            ellipse,
        };
        for xo in -a..a {
            for zo in -a..a {
                for y in 0..over {
                    let radius = if ellipse {
                        Self::radius_ellipse(y, over, width)
                    } else {
                        Self::radius_round(random, y, over, width)
                    };
                    if ellipse || xo < radius {
                        self.generate_block(
                            d,
                            region,
                            random,
                            &shape,
                            over,
                            [xo, y, zo],
                            radius,
                            a,
                        );
                    }
                }
            }
        }
        self.smooth(d, region, origin, width, over, ellipse, ellipse_a);
        for xo in -a..a {
            for zo in -a..a {
                let mut y = -1;
                while y > -under {
                    let new_a = if ellipse {
                        (a as f32 * (1.0 - (y * y) as f64 as f32 / (under as f32 * 8.0))).ceil()
                            as i32
                    } else {
                        a
                    };
                    let radius = Self::radius_steep(random, -y, under, width);
                    if xo < radius {
                        self.generate_block(
                            d,
                            region,
                            random,
                            &shape,
                            under,
                            [xo, y, zo],
                            radius,
                            new_a,
                        );
                    }
                    y -= 1;
                }
            }
        }
        let cut = if ellipse {
            random.next_double() > 0.1
        } else {
            random.next_double() > 0.7
        };
        if cut {
            self.cut_out(d, region, random, width, over, &shape);
        }
        Ok(true)
    }

    fn cut_out(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        width: i32,
        height: i32,
        shape: &Shape,
    ) {
        let sign_x = if random.next_bool() { -1 } else { 1 };
        let sign_z = if random.next_bool() { -1 } else { 1 };
        let mut x_off = random.next_int_bounded((width / 2 - 2).max(1));
        if random.next_bool() {
            x_off = width / 2 + 1 - random.next_int_bounded((width - width / 2 - 1).max(1));
        }
        let mut z_off = random.next_int_bounded((width / 2 - 2).max(1));
        if random.next_bool() {
            z_off = width / 2 + 1 - random.next_int_bounded((width - width / 2 - 1).max(1));
        }
        if shape.ellipse {
            x_off = random.next_int_bounded((shape.ellipse_a - 5).max(1));
            z_off = x_off;
        }
        let local = [sign_x * x_off, 0, sign_z * z_off];
        let angle = if shape.ellipse {
            shape.angle + std::f64::consts::PI / 2.0
        } else {
            random.next_double() * 2.0 * std::f64::consts::PI
        };
        for y in 0..height - 3 {
            let radius = Self::radius_round(random, y, height, width);
            self.carve(d, region, radius, y, shape, false, angle, local);
        }
        let mut y = -1;
        while y > -height + random.next_int_bounded(5) {
            let radius = Self::radius_steep(random, -y, height, width);
            self.carve(d, region, radius, y, shape, true, angle, local);
            y -= 1;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn carve(
        &self,
        d: &Decoration,
        region: &mut Region,
        radius: i32,
        y: i32,
        shape: &Shape,
        under_water: bool,
        angle: f64,
        local: [i32; 3],
    ) {
        let table = d.table.as_ref();
        let a = radius + 1 + shape.ellipse_a / 3;
        let c = (radius - 3).min(3) + shape.ellipse_c / 2 - 1;
        for xo in -a..a {
            for zo in -a..a {
                if !inside(Self::signed_ellipse(xo, zo, local, a, c, angle)) {
                    continue;
                }
                let pos = offset(shape.origin, [xo, y, zo]);
                let s = region.get(pos);
                if self.is_iceberg(table, s) || table.block_of(s) == self.snow_block {
                    if under_water {
                        region.set(pos, self.water_state, 3);
                    } else {
                        region.set(pos, self.air, 3);
                        let above = offset(pos, [0, 1, 0]);
                        if table.block_of(region.get(above)) == self.snow {
                            region.set(above, self.air, 3);
                        }
                    }
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn generate_block(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        shape: &Shape,
        height: i32,
        [xo, y, zo]: [i32; 3],
        radius: i32,
        a: i32,
    ) {
        let signed = if shape.ellipse {
            let mut c = shape.ellipse_c;
            if y > 0 && height - y <= 3 {
                c -= 4 - (height - y);
            }
            Self::signed_ellipse(xo, zo, [0, 0, 0], a, c, shape.angle)
        } else {
            let off = 10.0f32 * super::java::clamp(random.next_float(), 0.2, 0.8) / radius as f32;
            off as f64 + square(xo as f64) + square(zo as f64) - square(radius as f64)
        };
        if !inside(signed) {
            return;
        }
        let pos = offset(shape.origin, [xo, y, zo]);
        let compare = if shape.ellipse {
            -0.5
        } else {
            (-6 - random.next_int_bounded(3)) as f64
        };
        if signed > compare && random.next_double() > 0.9 {
            return;
        }
        self.set_block(d, region, random, pos, height - y, height, shape);
    }

    #[allow(clippy::too_many_arguments)]
    fn set_block(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
        h_diff: i32,
        height: i32,
        shape: &Shape,
    ) {
        let table = d.table.as_ref();
        let s = region.get(pos);
        let b = table.block_of(s);
        if !(table.is_air(s) || b == self.snow_block || b == self.ice || b == self.water) {
            return;
        }
        let randomness = !shape.ellipse || random.next_double() > 0.05;
        let divisor = if shape.ellipse { 3 } else { 2 };
        if shape.snow_on_top
            && b != self.water
            && (h_diff as f64)
                <= (random.next_int_bounded((height / divisor).max(1)) as f64) + height as f64 * 0.6
            && randomness
        {
            region.set(pos, self.snow_block_state, 3);
        } else {
            region.set(pos, self.state, 3);
        }
    }

    fn signed_ellipse(xo: i32, zo: i32, origin: [i32; 3], a: i32, c: i32, angle: f64) -> f64 {
        let (dx, dz) = ((xo - origin[0]) as f64, (zo - origin[2]) as f64);
        let (cos, sin) = (angle.cos(), angle.sin());
        square((dx * cos - dz * sin) / a as f64) + square((dx * sin + dz * cos) / c as f64) - 1.0
    }

    fn radius_round(random: &mut Random, y: i32, height: i32, width: i32) -> i32 {
        let k = 3.5f32 - random.next_float();
        let mut scale = (1.0 - (y * y) as f64 as f32 / (height as f32 * k)) * width as f32;
        if height > 15 + random.next_int_bounded(5) {
            let temp = if y < 3 + random.next_int_bounded(6) {
                y / 2
            } else {
                y
            };
            scale = (1.0 - temp as f32 / (height as f32 * k * 0.4)) * width as f32;
        }
        (scale / 2.0).ceil() as i32
    }

    fn radius_ellipse(y: i32, height: i32, width: i32) -> i32 {
        let scale = (1.0 - (y * y) as f64 as f32 / (height as f32 * 1.0)) * width as f32;
        (scale / 2.0).ceil() as i32
    }

    fn radius_steep(random: &mut Random, y: i32, height: i32, width: i32) -> i32 {
        let k = 1.0f32 + random.next_float() / 2.0;
        let scale = (1.0 - y as f32 / (height as f32 * k)) * width as f32;
        (scale / 2.0).ceil() as i32
    }

    #[allow(clippy::too_many_arguments)]
    fn smooth(
        &self,
        d: &Decoration,
        region: &mut Region,
        origin: [i32; 3],
        width: i32,
        height: i32,
        ellipse: bool,
        ellipse_a: i32,
    ) {
        let table = d.table.as_ref();
        let a = if ellipse { ellipse_a } else { width / 2 };
        for x in -a..=a {
            for z in -a..=a {
                for y in 0..=height {
                    let pos = offset(origin, [x, y, z]);
                    let s = region.get(pos);
                    let iceberg = self.is_iceberg(table, s);
                    if !iceberg && table.block_of(s) != self.snow {
                        continue;
                    }
                    if region.is_air_at(offset(pos, [0, -1, 0])) {
                        region.set(pos, self.air, 3);
                        region.set(offset(pos, [0, 1, 0]), self.air, 3);
                    } else if iceberg {
                        let mut open = 0;
                        for side in [WEST, EAST, NORTH, SOUTH] {
                            let n = region.get(offset(pos, DIRECTIONS[side]));
                            if !self.is_iceberg(table, n) {
                                open += 1;
                            }
                        }
                        if open >= 3 {
                            region.set(pos, self.air, 3);
                        }
                    }
                }
            }
        }
    }
}

/// `SpikeFeature` (ice spikes).
#[derive(Debug)]
pub struct Spike {
    state: u16,
    can_place_on: BlockPredicate,
    can_replace: BlockPredicate,
}

impl Spike {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Spike, String> {
        Ok(Spike {
            state: table.state(json.field("state")?)?,
            can_place_on: BlockPredicate::parse(json.field("can_place_on")?, table)?,
            can_replace: BlockPredicate::parse(json.field("can_replace")?, table)?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let mut origin = origin;
        while region.is_air_at(origin) && origin[1] > region.min_y() + 2 {
            origin[1] -= 1;
        }
        if !self.can_place_on.test(d, region, origin) {
            return Ok(false);
        }
        origin[1] += random.next_int_bounded(4);
        let height = random.next_int_bounded(4) + 7;
        let width = height / 4 + random.next_int_bounded(2);
        if width > 1 && random.next_int_bounded(60) == 0 {
            origin[1] += 10 + random.next_int_bounded(30);
        }
        for y in 0..height {
            let scale = (1.0 - y as f32 / height as f32) * width as f32;
            let new_width = scale.ceil() as i32;
            for xo in -new_width..=new_width {
                let dx = xo.abs() as f32 - 0.25;
                for zo in -new_width..=new_width {
                    let dz = zo.abs() as f32 - 0.25;
                    let inside = xo == 0 && zo == 0 || dx * dx + dz * dz <= scale * scale;
                    if !inside {
                        continue;
                    }
                    let edge =
                        xo == -new_width || xo == new_width || zo == -new_width || zo == new_width;
                    if edge && random.next_float() > 0.75 {
                        continue;
                    }
                    let above = offset(origin, [xo, y, zo]);
                    let s = region.get(above);
                    if table.is_air(s) || self.can_replace.test(d, region, above) {
                        region.set(above, self.state, 3);
                    }
                    if y != 0 && new_width > 1 {
                        let below = offset(origin, [xo, -y, zo]);
                        let s = region.get(below);
                        if table.is_air(s) || self.can_replace.test(d, region, below) {
                            region.set(below, self.state, 3);
                        }
                    }
                }
            }
        }
        let pillar = (width - 1).clamp(0, 1);
        for xo in -pillar..=pillar {
            for zo in -pillar..=pillar {
                let mut cursor = offset(origin, [xo, -1, zo]);
                let mut run = 50;
                if xo.abs() == 1 && zo.abs() == 1 {
                    run = random.next_int_bounded(5);
                }
                while cursor[1] > 50 {
                    let s = region.get(cursor);
                    if !table.is_air(s)
                        && !self.can_replace.test(d, region, cursor)
                        && s != self.state
                    {
                        break;
                    }
                    region.set(cursor, self.state, 3);
                    cursor[1] -= 1;
                    run -= 1;
                    if run <= 0 {
                        cursor[1] -= random.next_int_bounded(5) + 1;
                        run = random.next_int_bounded(5);
                    }
                }
            }
        }
        Ok(true)
    }
}

/// `GeodeFeature` with its block, layer and crack settings.
pub struct Geode {
    filling: Arc<StateProvider>,
    inner: Arc<StateProvider>,
    alternate_inner: Arc<StateProvider>,
    middle: Arc<StateProvider>,
    outer: Arc<StateProvider>,
    inner_placements: Vec<u16>,
    cannot_replace: BlockSet,
    invalid: BlockSet,
    layers: [f64; 4],
    crack_chance: f64,
    crack_size: f64,
    crack_point_offset: i32,
    potential_chance: f64,
    alternate_chance: f64,
    require_alternate: bool,
    outer_wall_distance: IntProvider,
    distribution_points: IntProvider,
    point_offset: IntProvider,
    min_offset: i32,
    max_offset: i32,
    noise_multiplier: f64,
    invalid_threshold: i32,
    air: u16,
    water: u16,
    /// `NormalNoise.createParity(-4, 1.0)` seeded from the world seed, built
    /// once per seed.
    noise: Mutex<Option<(i64, Arc<Stack>)>>,
}

impl std::fmt::Debug for Geode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Geode")
    }
}

impl Geode {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<Geode, String> {
        let blocks = json.field("blocks")?;
        let layers = json.field("layers")?;
        let crack = json.field("crack")?;
        let number = |j: &Json, k: &str, default: f64| j.get(k).map_or(Ok(default), Json::as_f64);
        let int = |k: &str, default: i32| json.get(k).map_or(Ok(default), Json::as_i32);
        let ints = |k: &str, min: i32, max: i32| match json.get(k) {
            Some(j) => IntProvider::parse(j),
            None => Ok(IntProvider::Uniform(min, max)),
        };
        Ok(Geode {
            filling: provider(blocks.field("filling_provider")?)?,
            inner: provider(blocks.field("inner_layer_provider")?)?,
            alternate_inner: provider(blocks.field("alternate_inner_layer_provider")?)?,
            middle: provider(blocks.field("middle_layer_provider")?)?,
            outer: provider(blocks.field("outer_layer_provider")?)?,
            inner_placements: blocks
                .field("inner_placements")?
                .as_array()?
                .iter()
                .map(|s| table.state(s))
                .collect::<Result<_, _>>()?,
            cannot_replace: table.block_set(blocks.field("cannot_replace")?)?,
            invalid: table.block_set(blocks.field("invalid_blocks")?)?,
            layers: [
                number(layers, "filling", 1.7)?,
                number(layers, "inner_layer", 2.2)?,
                number(layers, "middle_layer", 3.2)?,
                number(layers, "outer_layer", 4.2)?,
            ],
            crack_chance: number(crack, "generate_crack_chance", 1.0)?,
            crack_size: number(crack, "base_crack_size", 2.0)?,
            crack_point_offset: crack
                .get("crack_point_offset")
                .map_or(Ok(2), Json::as_i32)?,
            potential_chance: number(json, "use_potential_placements_chance", 0.35)?,
            alternate_chance: number(json, "use_alternate_layer0_chance", 0.0)?,
            require_alternate: json
                .get("placements_require_layer0_alternate")
                .map_or(Ok(true), Json::as_bool)?,
            outer_wall_distance: ints("outer_wall_distance", 4, 5)?,
            distribution_points: ints("distribution_points", 3, 4)?,
            point_offset: ints("point_offset", 1, 2)?,
            min_offset: int("min_gen_offset", -16)?,
            max_offset: int("max_gen_offset", 16)?,
            noise_multiplier: number(json, "noise_multiplier", 0.05)?,
            invalid_threshold: json.field("invalid_blocks_threshold")?.as_i32()?,
            air: table.default_state("air")?,
            water: table.block("water")?,
            noise: Mutex::new(None),
        })
    }

    fn noise(&self, seed: i64) -> Result<Arc<Stack>, String> {
        let mut cache = self.noise.lock().map_err(|_| "geode noise poisoned")?;
        if let Some((s, noise)) = cache.as_ref() {
            if *s == seed {
                return Ok(noise.clone());
            }
        }
        let parameters = NormalNoise::create_parity(-4, &[1.0])?;
        let noise = Arc::new(parameters.create(&mut Random::legacy(seed)));
        *cache = Some((seed, noise.clone()));
        Ok(noise)
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let inv_sqrt = |v: f64| 1.0 / v.sqrt();
        let dist_sqr = |a: [i32; 3], b: [i32; 3]| {
            let (dx, dy, dz) = (
                (a[0] - b[0]) as f64,
                (a[1] - b[1]) as f64,
                (a[2] - b[2]) as f64,
            );
            dx * dx + dy * dy + dz * dz
        };
        let mut points: Vec<([i32; 3], i32)> = Vec::new();
        let count = self.distribution_points.sample(random);
        let noise = self.noise(region.seed)?;
        let adjustment = count as f64 / self.outer_wall_distance.max_inclusive() as f64;
        let [filling, inner, middle, outer] = self.layers;
        let inner_air = 1.0 / filling.sqrt();
        let innermost = 1.0 / (inner + adjustment).sqrt();
        let inner_crust = 1.0 / (middle + adjustment).sqrt();
        let outer_crust = 1.0 / (outer + adjustment).sqrt();
        let crack_size = 1.0
            / (self.crack_size
                + random.next_double() / 2.0
                + if count > 3 { adjustment } else { 0.0 })
            .sqrt();
        let crack = (random.next_float() as f64) < self.crack_chance;
        let mut invalid = 0;
        for _ in 0..count {
            let x = self.outer_wall_distance.sample(random);
            let y = self.outer_wall_distance.sample(random);
            let z = self.outer_wall_distance.sample(random);
            let pos = offset(origin, [x, y, z]);
            let s = region.get(pos);
            if table.is_air(s) || table.in_tag(s, &self.invalid) {
                invalid += 1;
                if invalid > self.invalid_threshold {
                    return Ok(false);
                }
            }
            points.push((pos, self.point_offset.sample(random)));
        }
        let mut crack_points = Vec::new();
        if crack {
            let index = random.next_int_bounded(4);
            let o = count * 2 + 1;
            let (cx, cz) = match index {
                0 => (o, 0),
                1 => (0, o),
                2 => (o, o),
                _ => (0, 0),
            };
            for y in [7, 5, 1] {
                crack_points.push(offset(origin, [cx, y, cz]));
            }
        }
        let mut potential = Vec::new();
        let (lo, hi) = (self.min_offset, self.max_offset);
        for z in lo..=hi {
            for y in lo..=hi {
                for x in lo..=hi {
                    let p = offset(origin, [x, y, z]);
                    let noise_offset = noise.get(p[0] as f64, p[1] as f64, p[2] as f64) as f64
                        * self.noise_multiplier;
                    let mut shell = 0.0;
                    for (point, off) in &points {
                        shell += inv_sqrt(dist_sqr(p, *point) + *off as f64) + noise_offset;
                    }
                    if shell < outer_crust {
                        continue;
                    }
                    if shell >= inner_air {
                        let s = self.filling.state(d, region, random, p);
                        safe_set(table, region, p, s, &self.cannot_replace);
                        continue;
                    }
                    let mut crack_sum = 0.0;
                    for point in &crack_points {
                        crack_sum += inv_sqrt(dist_sqr(p, *point) + self.crack_point_offset as f64)
                            + noise_offset;
                    }
                    if crack && crack_sum >= crack_size {
                        safe_set(table, region, p, self.air, &self.cannot_replace);
                        for dir in DIRECTIONS {
                            let adjacent = offset(p, dir);
                            let fluid = table.fluid(region.get(adjacent));
                            if fluid != super::blocks::FLUID_EMPTY {
                                region.schedule_fluid_tick(adjacent, fluid);
                            }
                        }
                    } else if shell >= innermost {
                        let alternate = (random.next_float() as f64) < self.alternate_chance;
                        let provider = if alternate {
                            &self.alternate_inner
                        } else {
                            &self.inner
                        };
                        let s = provider.state(d, region, random, p);
                        safe_set(table, region, p, s, &self.cannot_replace);
                        if (!self.require_alternate || alternate)
                            && (random.next_float() as f64) < self.potential_chance
                        {
                            potential.push(p);
                        }
                    } else if shell >= inner_crust {
                        let s = self.middle.state(d, region, random, p);
                        safe_set(table, region, p, s, &self.cannot_replace);
                    } else if shell >= outer_crust {
                        let s = self.outer.state(d, region, random, p);
                        safe_set(table, region, p, s, &self.cannot_replace);
                    }
                }
            }
        }
        for crystal in potential {
            let index = random.next_int_bounded(self.inner_placements.len() as i32) as usize;
            let mut state = self.inner_placements[index];
            for (dir, step) in DIRECTIONS.iter().enumerate() {
                if let Some(s) = table.with(state, "facing", FACING[dir]) {
                    state = s;
                }
                let place = offset(crystal, *step);
                let place_state = region.get(place);
                let source = matches!(
                    table.fluid(place_state),
                    super::blocks::FLUID_WATER | super::blocks::FLUID_LAVA
                );
                if let Some(s) =
                    table.with(state, "waterlogged", if source { "true" } else { "false" })
                {
                    state = s;
                }
                // `BuddingAmethystBlock.canClusterGrowAtState`.
                let grows = table.is_air(place_state)
                    || (table.block_of(place_state) == self.water
                        && table.fluid_level[place_state as usize] & 15 == 8);
                if grows {
                    safe_set(table, region, place, state, &self.cannot_replace);
                    break;
                }
            }
        }
        Ok(true)
    }
}

/// `UnderwaterMagmaFeature`.
#[derive(Debug)]
pub struct UnderwaterMagma {
    search_range: i32,
    radius: i32,
    probability: f32,
    water: u16,
    magma: u16,
}

impl UnderwaterMagma {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<UnderwaterMagma, String> {
        Ok(UnderwaterMagma {
            search_range: json.field("floor_search_range")?.as_i32()?,
            radius: json.field("placement_radius_around_floor")?.as_i32()?,
            probability: json
                .field("placement_probability_per_valid_position")?
                .as_f64()? as f32,
            water: table.block("water")?,
            magma: table.default_state("magma_block")?,
        })
    }

    /// `isVisibleFromOutside`: the face toward `covered` does not occlude
    /// fully.
    fn visible(table: &BlockTable, region: &mut Region, pos: [i32; 3], covered: usize) -> bool {
        !table.flag(region.get(pos), OCCLUDES << covered)
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let water = self.water;
        let Some(column) = Column::scan(
            region,
            origin,
            self.search_range,
            &|s| table.block_of(s) == water,
            &|s| table.block_of(s) != water,
        ) else {
            return Ok(false);
        };
        let Some(floor) = column.floor else {
            return Ok(false);
        };
        let r = self.radius;
        let mut placed = false;
        for z in origin[2] - r..=origin[2] + r {
            for y in floor - r..=floor + r {
                for x in origin[0] - r..=origin[0] + r {
                    let pos = [x, y, z];
                    if random.next_float() >= self.probability {
                        continue;
                    }
                    let s = region.get(pos);
                    let water_or_air = table.block_of(s) == water || table.is_air(s);
                    if water_or_air || Self::visible(table, region, offset(pos, [0, -1, 0]), UP) {
                        continue;
                    }
                    let open = HORIZONTAL
                        .iter()
                        .any(|&h| Self::visible(table, region, offset(pos, DIRECTIONS[h]), h ^ 1));
                    if open {
                        continue;
                    }
                    region.set(pos, self.magma, 2);
                    placed = true;
                }
            }
        }
        Ok(placed)
    }
}

/// `MonsterRoomFeature`: a cobblestone room with a spawner and up to two
/// chests.
#[derive(Debug)]
pub struct MonsterRoom {
    protected: BlockSet,
    cave_air: u16,
    cobblestone: u16,
    mossy_cobblestone: u16,
    chest: u16,
    chest_state: u16,
    spawner: u16,
    spawner_state: u16,
}

const MOBS: [&str; 4] = [
    "minecraft:skeleton",
    "minecraft:zombie",
    "minecraft:zombie",
    "minecraft:spider",
];

impl MonsterRoom {
    pub fn new(table: &BlockTable) -> Result<MonsterRoom, String> {
        Ok(MonsterRoom {
            protected: table.tag("minecraft:features_cannot_replace")?.clone(),
            cave_air: table.default_state("cave_air")?,
            cobblestone: table.default_state("cobblestone")?,
            mossy_cobblestone: table.default_state("mossy_cobblestone")?,
            chest: table.block("chest")?,
            chest_state: table.default_state("chest")?,
            spawner: table.block("spawner")?,
            spawner_state: table.default_state("spawner")?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let solid = |region: &mut Region, p: [i32; 3]| table.flag(region.get(p), SOLID);
        let xr = random.next_int_bounded(2) + 2;
        let (min_x, max_x) = (-xr - 1, xr + 1);
        let zr = random.next_int_bounded(2) + 2;
        let (min_z, max_z) = (-zr - 1, zr + 1);
        let mut holes = 0;
        for dx in min_x..=max_x {
            for dy in -1..=4 {
                for dz in min_z..=max_z {
                    let p = offset(origin, [dx, dy, dz]);
                    let is_solid = solid(region, p);
                    if (dy == -1 || dy == 4) && !is_solid {
                        return Ok(false);
                    }
                    if (dx == min_x || dx == max_x || dz == min_z || dz == max_z)
                        && dy == 0
                        && region.is_air_at(p)
                        && region.is_air_at(offset(p, [0, 1, 0]))
                    {
                        holes += 1;
                    }
                }
            }
        }
        if !(1..=5).contains(&holes) {
            return Ok(false);
        }
        for dx in min_x..=max_x {
            for dy in (-1..=3).rev() {
                for dz in min_z..=max_z {
                    let p = offset(origin, [dx, dy, dz]);
                    let wall = region.get(p);
                    let block = table.block_of(wall);
                    if dx == min_x
                        || dy == -1
                        || dz == min_z
                        || dx == max_x
                        || dy == 4
                        || dz == max_z
                    {
                        if p[1] >= region.min_y() && !solid(region, offset(p, [0, -1, 0])) {
                            region.set(p, self.cave_air, 2);
                        } else if table.flag(wall, SOLID) && block != self.chest {
                            if dy == -1 && random.next_int_bounded(4) != 0 {
                                safe_set(table, region, p, self.mossy_cobblestone, &self.protected);
                            } else {
                                safe_set(table, region, p, self.cobblestone, &self.protected);
                            }
                        }
                    } else if block != self.chest && block != self.spawner {
                        safe_set(table, region, p, self.cave_air, &self.protected);
                    }
                }
            }
        }
        for _ in 0..2 {
            for _ in 0..3 {
                let xc = origin[0] + random.next_int_bounded(xr * 2 + 1) - xr;
                let zc = origin[2] + random.next_int_bounded(zr * 2 + 1) - zr;
                let chest_pos = [xc, origin[1], zc];
                if !region.is_air_at(chest_pos) {
                    continue;
                }
                let walls = HORIZONTAL
                    .iter()
                    .filter(|&&h| solid(region, offset(chest_pos, DIRECTIONS[h])))
                    .count();
                if walls == 1 {
                    let state = self.reorient(table, region, chest_pos)?;
                    safe_set(table, region, chest_pos, state, &self.protected);
                    if let Some(be) = region.block_entity(chest_pos)? {
                        if matches!(be.kind, "minecraft:chest" | "minecraft:trapped_chest") {
                            be.loot_table = Some("minecraft:chests/simple_dungeon".into());
                            be.loot_seed = random.next_long();
                        }
                    }
                    break;
                }
            }
        }
        safe_set(table, region, origin, self.spawner_state, &self.protected);
        if let Some(be) = region.block_entity(origin)? {
            if be.kind == "minecraft:mob_spawner" {
                let mob = MOBS[random.next_int_bounded(4) as usize];
                be.spawner_entity = Some(mob.into());
            }
        }
        Ok(true)
    }

    /// `StructurePiece.reorient` of the default chest.
    fn reorient(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
    ) -> Result<u16, String> {
        let state = self.chest_state;
        let mut solid_neighbour = None;
        for h in HORIZONTAL {
            let s = region.get(offset(pos, DIRECTIONS[h]));
            if table.block_of(s) == self.chest {
                return Ok(state);
            }
            if table.flag(s, SOLID_RENDER) {
                if solid_neighbour.is_some() {
                    solid_neighbour = None;
                    break;
                }
                solid_neighbour = Some(h);
            }
        }
        let facing = |dir: usize| {
            table
                .with(state, "facing", FACING[dir])
                .ok_or_else(|| "chest facing".to_string())
        };
        if let Some(h) = solid_neighbour {
            return facing(h ^ 1);
        }
        let current = table.value(state, "facing").unwrap_or("north");
        let mut lock = FACING.iter().position(|f| *f == current).unwrap_or(NORTH);
        let render = |region: &mut Region, dir: usize| {
            table.flag(region.get(offset(pos, DIRECTIONS[dir])), SOLID_RENDER)
        };
        if render(region, lock) {
            lock ^= 1;
        }
        if render(region, lock) {
            lock = super::tree::clockwise(lock);
        }
        if render(region, lock) {
            lock ^= 1;
        }
        facing(lock)
    }
}
