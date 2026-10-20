//! Dripstone and sulfur speleothems (VMC-025c): large dripstone, speleothem
//! clusters and single speleothems (`LargeDripstoneFeature`,
//! `SpeleothemClusterFeature`, `SpeleothemFeature`, `SpeleothemUtils`), the
//! vertical column scan they share (`Column.scan`), and `SpeleothemBlock`'s
//! shape update, which reads scheduled ticks and so is code rather than shape
//! facts.

use super::blocks::{BlockSet, BlockTable, Heightmap, FLUID_WATER, STURDY};
use super::feature::Decoration;
use super::json::Json;
use super::predicate::offset;
use super::providers::{between_inclusive, normal, FloatProvider, IntProvider};
use super::random::Random;
use super::region::Region;

const DOWN: usize = 0;
const UP: usize = 1;
/// North, east, south, west.
const HORIZONTAL: [[i32; 3]; 4] = [[0, 0, -1], [1, 0, 0], [0, 0, 1], [-1, 0, 0]];
const DIRECTIONS: [[i32; 3]; 6] = [
    [0, -1, 0],
    [0, 1, 0],
    [0, 0, -1],
    [0, 0, 1],
    [-1, 0, 0],
    [1, 0, 0],
];

/// Blocks the speleothem features test by identity.
#[derive(Debug)]
struct Kinds {
    water: u16,
    lava: u16,
    dripstone_block: u16,
    base_stone: BlockSet,
}

impl Kinds {
    fn new(table: &BlockTable) -> Result<Kinds, String> {
        Ok(Kinds {
            water: table.block("water")?,
            lava: table.block("lava")?,
            dripstone_block: table.block("dripstone_block")?,
            base_stone: table.tag("minecraft:base_stone_overworld")?.clone(),
        })
    }

    fn empty_or_water(&self, table: &BlockTable, s: u16) -> bool {
        table.is_air(s) || table.block_of(s) == self.water
    }

    fn empty_or_water_or_lava(&self, table: &BlockTable, s: u16) -> bool {
        self.empty_or_water(table, s) || table.block_of(s) == self.lava
    }
}

/// A speleothem's blocks: the base it grows from, the pointed block and
/// what the base may replace.
#[derive(Debug)]
struct Blocks {
    base: u16,
    base_state: u16,
    pointed: u16,
    replaceable: BlockSet,
}

impl Blocks {
    fn is_base(&self, table: &BlockTable, s: u16) -> bool {
        table.block_of(s) == self.base || table.in_tag(s, &self.replaceable)
    }

    /// `SpeleothemUtils.placeBaseBlockIfPossible`.
    fn place_base(&self, d: &Decoration, region: &mut Region, pos: [i32; 3]) -> bool {
        let s = region.get(pos);
        if d.table.in_tag(s, &self.replaceable) {
            region.set(pos, self.base_state, 2);
            true
        } else {
            false
        }
    }

    /// `SpeleothemUtils.growSpeleothem`: from the base to the tip.
    #[allow(clippy::too_many_arguments)]
    fn grow(
        &self,
        d: &Decoration,
        region: &mut Region,
        start: [i32; 3],
        tip: usize,
        height: i32,
        merged: bool,
    ) -> Result<(), String> {
        let table = d.table.as_ref();
        let behind = region.get(offset(start, DIRECTIONS[tip ^ 1]));
        if !self.is_base(table, behind) {
            return Ok(());
        }
        let direction = if tip == UP { "up" } else { "down" };
        let mut column = Vec::new();
        if height >= 3 {
            column.push("base");
            column.extend(std::iter::repeat_n("middle", (height - 3) as usize));
        }
        if height >= 2 {
            column.push("frustum");
        }
        if height >= 1 {
            column.push(if merged { "tip_merge" } else { "tip" });
        }
        let pointed = table.default[self.pointed as usize];
        let mut pos = start;
        for thickness in column {
            let mut s = table
                .with(pointed, "vertical_direction", direction)
                .and_then(|s| table.with(s, "thickness", thickness))
                .ok_or("speleothem state")?;
            // `level.isWaterAt`.
            let water = table.fluid(region.get(pos)) == FLUID_WATER
                || table.fluid(region.get(pos)) == super::blocks::FLUID_FLOWING_WATER;
            s = table
                .with(s, "waterlogged", if water { "true" } else { "false" })
                .ok_or("speleothem waterlogged")?;
            region.set(pos, s, 2);
            pos = offset(pos, DIRECTIONS[tip]);
        }
        Ok(())
    }

    fn parse(json: &Json, table: &BlockTable) -> Result<Blocks, String> {
        let base_state = table.state(json.field("base_block")?)?;
        Ok(Blocks {
            base: table.block_of(base_state),
            base_state: table.default[table.block_of(base_state) as usize],
            pointed: table.block_of(table.state(json.field("pointed_block")?)?),
            replaceable: table.block_set(json.field("replaceable_blocks")?)?,
        })
    }
}

/// `Column`: a floor and a ceiling, either missing.
#[derive(Clone, Copy, Debug)]
pub struct Column {
    pub floor: Option<i32>,
    pub ceiling: Option<i32>,
}

impl Column {
    /// The height of a column with both ends.
    pub fn height(&self) -> Option<i32> {
        Some(self.ceiling? - self.floor? - 1)
    }

    /// `Column.scan`: from `pos` (which must be inside) up and down while
    /// inside, each end kept when it is a valid edge.
    pub fn scan(
        region: &mut Region,
        pos: [i32; 3],
        range: i32,
        inside: &dyn Fn(u16) -> bool,
        edge: &dyn Fn(u16) -> bool,
    ) -> Option<Column> {
        if !inside(region.get(pos)) {
            return None;
        }
        let mut end = |dy: i32| {
            let mut p = pos;
            let mut i = 1;
            while i < range && inside(region.get(p)) {
                p[1] += dy;
                i += 1;
            }
            edge(region.get(p)).then_some(p[1])
        };
        let ceiling = end(1);
        let floor = end(-1);
        Some(Column { floor, ceiling })
    }
}

/// `SpeleothemUtils.getSpeleothemHeight`.
fn speleothem_height(xz: f64, radius: f64, scale: f64, bluntness: f64) -> f64 {
    let xz = if xz < bluntness { bluntness } else { xz };
    let r = xz / radius * 0.384;
    let part1 = 0.75 * r.powf(1.3333333333333333);
    let part2 = r.powf(0.6666666666666666);
    let part3 = 0.3333333333333333 * r.ln();
    let height = scale * (part1 - part2 - part3);
    let height = if height > 0.0 { height } else { 0.0 };
    height / 0.384 * radius
}

/// `LargeDripstoneFeature`.
#[derive(Debug)]
pub struct LargeDripstone {
    kinds: Kinds,
    replaceable: BlockSet,
    search_range: i32,
    column_radius: IntProvider,
    height_scale: FloatProvider,
    max_ratio: f32,
    stalactite_bluntness: FloatProvider,
    stalagmite_bluntness: FloatProvider,
    wind_speed: FloatProvider,
    min_radius_for_wind: i32,
    min_bluntness_for_wind: f32,
    dripstone: u16,
}

struct Dripstone {
    root: [i32; 3],
    up: bool,
    radius: i32,
    bluntness: f64,
    scale: f64,
}

/// `LargeDripstoneFeature.WindOffsetter`.
struct Wind {
    origin_y: i32,
    speed: Option<(f64, f64)>,
    max_offset: i32,
}

impl Wind {
    fn offset(&self, pos: [i32; 3]) -> [i32; 3] {
        let Some((sx, sz)) = self.speed else {
            return pos;
        };
        let dy = (self.origin_y - pos[1]) as f64;
        let m = self.max_offset;
        let dx = ((sx * dy).floor() as i32).max(-m).min(m);
        let dz = ((sz * dy).floor() as i32).max(-m).min(m);
        [pos[0] + dx, pos[1], pos[2] + dz]
    }
}

impl Dripstone {
    fn height_at(&self, r: f32) -> i32 {
        speleothem_height(r as f64, self.radius as f64, self.scale, self.bluntness) as i32
    }

    /// `SpeleothemUtils.isCircleMostlyEmbeddedInStone`.
    fn embedded(
        kinds: &Kinds,
        table: &BlockTable,
        region: &mut Region,
        center: [i32; 3],
        radius: i32,
    ) -> bool {
        if kinds.empty_or_water_or_lava(table, region.get(center)) {
            return false;
        }
        let increment = 6.0f32 / radius as f32;
        let mut angle = 0.0f32;
        while angle < (std::f64::consts::PI * 2.0) as f32 {
            let dx = (super::carver::cos(angle as f64) * radius as f32) as i32;
            let dz = (super::carver::sin(angle as f64) * radius as f32) as i32;
            if kinds.empty_or_water_or_lava(table, region.get(offset(center, [dx, 0, dz]))) {
                return false;
            }
            angle += increment;
        }
        true
    }

    fn move_into_stone(
        &mut self,
        kinds: &Kinds,
        table: &BlockTable,
        region: &mut Region,
        wind: &Wind,
    ) -> bool {
        while self.radius > 1 {
            let mut root = self.root;
            let tries = self.height_at(0.0).min(10);
            for _ in 0..tries {
                if table.block_of(region.get(root)) == kinds.lava {
                    return false;
                }
                if Self::embedded(kinds, table, region, wind.offset(root), self.radius) {
                    self.root = root;
                    return true;
                }
                root[1] += if self.up { -1 } else { 1 };
            }
            self.radius /= 2;
        }
        false
    }

    #[allow(clippy::too_many_arguments)]
    fn place(
        &self,
        kinds: &Kinds,
        table: &BlockTable,
        region: &mut Region,
        random: &mut Random,
        wind: &Wind,
        dripstone: u16,
    ) {
        for dx in -self.radius..=self.radius {
            for dz in -self.radius..=self.radius {
                let r = ((dx * dx + dz * dz) as f32 as f64).sqrt() as f32;
                if r > self.radius as f32 {
                    continue;
                }
                let mut height = self.height_at(r);
                if height <= 0 {
                    continue;
                }
                if (random.next_float() as f64) < 0.2 {
                    let factor = random.next_float() * (1.0 - 0.8) + 0.8;
                    height = (height as f32 * factor) as i32;
                }
                let mut pos = offset(self.root, [dx, 0, dz]);
                let mut out_of_stone = false;
                let max_y = if self.up {
                    region.height_at(Heightmap::WorldSurfaceWg, pos[0], pos[2])
                } else {
                    i32::MAX
                };
                let mut i = 0;
                while i < height && pos[1] < max_y {
                    let at = wind.offset(pos);
                    let s = region.get(at);
                    if kinds.empty_or_water_or_lava(table, s) {
                        out_of_stone = true;
                        region.set(at, dripstone, 2);
                    } else if out_of_stone && table.in_tag(s, &kinds.base_stone) {
                        break;
                    }
                    pos[1] += if self.up { 1 } else { -1 };
                    i += 1;
                }
            }
        }
    }
}

impl LargeDripstone {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<LargeDripstone, String> {
        let f = |k: &str| json.field(k).and_then(FloatProvider::parse);
        Ok(LargeDripstone {
            kinds: Kinds::new(table)?,
            replaceable: table.block_set(json.field("replaceable_blocks")?)?,
            search_range: json
                .get("floor_to_ceiling_search_range")
                .map_or(Ok(30), Json::as_i32)?,
            column_radius: IntProvider::parse(json.field("column_radius")?)?,
            height_scale: f("height_scale")?,
            max_ratio: json
                .field("max_column_radius_to_cave_height_ratio")?
                .as_f64()? as f32,
            stalactite_bluntness: f("stalactite_bluntness")?,
            stalagmite_bluntness: f("stalagmite_bluntness")?,
            wind_speed: f("wind_speed")?,
            min_radius_for_wind: json.field("min_radius_for_wind")?.as_i32()?,
            min_bluntness_for_wind: json.field("min_bluntness_for_wind")?.as_f64()? as f32,
            dripstone: table.default_state("dripstone_block")?,
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
        let k = &self.kinds;
        if !k.empty_or_water(table, region.get(origin)) {
            return Ok(false);
        }
        let base_or_lava = |s: u16| {
            table.block_of(s) == k.dripstone_block
                || table.in_tag(s, &self.replaceable)
                || table.block_of(s) == k.lava
        };
        let Some(column) = Column::scan(
            region,
            origin,
            self.search_range,
            &|s| k.empty_or_water(table, s),
            &base_or_lava,
        ) else {
            return Ok(false);
        };
        let (Some(floor), Some(ceiling), Some(height)) =
            (column.floor, column.ceiling, column.height())
        else {
            return Ok(false);
        };
        if height < 4 {
            return Ok(false);
        }
        let by_height = (height as f32 * self.max_ratio) as i32;
        let (min, max) = (
            self.column_radius.min_inclusive(),
            self.column_radius.max_inclusive(),
        );
        let max_radius = by_height.max(min).min(max);
        let radius = between_inclusive(random, min, max_radius);
        let mut stalactite = Dripstone {
            root: [origin[0], ceiling - 1, origin[2]],
            up: false,
            radius,
            bluntness: self.stalactite_bluntness.sample(random) as f64,
            scale: self.height_scale.sample(random) as f64,
        };
        let mut stalagmite = Dripstone {
            root: [origin[0], floor + 1, origin[2]],
            up: true,
            radius,
            bluntness: self.stalagmite_bluntness.sample(random) as f64,
            scale: self.height_scale.sample(random) as f64,
        };
        let suits = |s: &Dripstone| {
            s.radius >= self.min_radius_for_wind
                && s.bluntness >= self.min_bluntness_for_wind as f64
        };
        let wind = if suits(&stalactite) && suits(&stalagmite) {
            let speed = self.wind_speed.sample(random);
            let direction = random.next_float() * (std::f64::consts::PI as f32 - 0.0) + 0.0;
            Wind {
                origin_y: origin[1],
                speed: Some((
                    (super::carver::cos(direction as f64) * speed) as f64,
                    (super::carver::sin(direction as f64) * speed) as f64,
                )),
                max_offset: 16 - radius,
            }
        } else {
            Wind {
                origin_y: 0,
                speed: None,
                max_offset: 0,
            }
        };
        let stalactite_in = stalactite.move_into_stone(k, table, region, &wind);
        let stalagmite_in = stalagmite.move_into_stone(k, table, region, &wind);
        if stalactite_in {
            stalactite.place(k, table, region, random, &wind, self.dripstone);
        }
        if stalagmite_in {
            stalagmite.place(k, table, region, random, &wind, self.dripstone);
        }
        Ok(true)
    }
}

/// `SpeleothemClusterFeature`.
#[derive(Debug)]
pub struct SpeleothemCluster {
    kinds: Kinds,
    blocks: Blocks,
    search_range: i32,
    height: IntProvider,
    radius: IntProvider,
    max_height_diff: i32,
    height_deviation: i32,
    layer_thickness: IntProvider,
    density: FloatProvider,
    wetness: FloatProvider,
    edge_chance: f32,
    edge_distance: i32,
    center_distance: i32,
    water: u16,
}

impl SpeleothemCluster {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<SpeleothemCluster, String> {
        let i = |k: &str| json.field(k)?.as_i32();
        Ok(SpeleothemCluster {
            kinds: Kinds::new(table)?,
            blocks: Blocks::parse(json, table)?,
            search_range: i("floor_to_ceiling_search_range")?,
            height: IntProvider::parse(json.field("height")?)?,
            radius: IntProvider::parse(json.field("radius")?)?,
            max_height_diff: i("max_stalagmite_stalactite_height_diff")?,
            height_deviation: i("height_deviation")?,
            layer_thickness: IntProvider::parse(json.field("speleothem_block_layer_thickness")?)?,
            density: FloatProvider::parse(json.field("density")?)?,
            wetness: FloatProvider::parse(json.field("wetness")?)?,
            edge_chance: json
                .field("chance_of_speleothem_at_max_distance_from_center")?
                .as_f64()? as f32,
            edge_distance: i("max_distance_from_edge_affecting_chance_of_speleothem")?,
            center_distance: i("max_distance_from_center_affecting_height_bias")?,
            water: table.default_state("water")?,
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
        if !self.kinds.empty_or_water(table, region.get(origin)) {
            return Ok(false);
        }
        let height = self.height.sample(random);
        let wetness = self.wetness.sample(random);
        let density = self.density.sample(random);
        let x_radius = self.radius.sample(random);
        let z_radius = self.radius.sample(random);
        for dx in -x_radius..=x_radius {
            for dz in -z_radius..=z_radius {
                // `getChanceOfStalagmiteOrStalactite`: `Mth.clampedMap` on floats.
                let from_edge = (x_radius - dx.abs()).min(z_radius - dz.abs());
                let t = (from_edge as f32 - 0.0) / (self.edge_distance as f32 - 0.0);
                let chance = if t < 0.0 {
                    self.edge_chance
                } else if t > 1.0 {
                    1.0
                } else {
                    self.edge_chance + t * (1.0 - self.edge_chance)
                } as f64;
                let pos = offset(origin, [dx, 0, dz]);
                self.place_column(
                    d, region, random, pos, dx, dz, wetness, chance, height, density,
                )?;
            }
        }
        Ok(true)
    }

    #[allow(clippy::too_many_arguments)]
    fn place_column(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        pos: [i32; 3],
        dx: i32,
        dz: i32,
        wetness: f32,
        chance: f64,
        cluster_height: i32,
        density: f32,
    ) -> Result<(), String> {
        let table = d.table.as_ref();
        let k = &self.kinds;
        let Some(base) = Column::scan(
            region,
            pos,
            self.search_range,
            &|s| k.empty_or_water(table, s),
            &|s| !k.empty_or_water(table, s),
        ) else {
            return Ok(());
        };
        let ceiling = base.ceiling;
        if ceiling.is_none() && base.floor.is_none() {
            return Ok(());
        }
        let want_pool = random.next_float() < wetness;
        let column = match base.floor {
            Some(floor)
                if want_pool && self.can_place_pool(table, region, [pos[0], floor, pos[2]]) =>
            {
                region.set([pos[0], floor, pos[2]], self.water, 2);
                Column {
                    floor: Some(floor - 1),
                    ceiling,
                }
            }
            _ => base,
        };
        let floor = column.floor;
        let lava =
            |region: &mut Region, y: i32| table.block_of(region.get([pos[0], y, pos[2]])) == k.lava;
        let want_stalactite = random.next_double() < chance;
        let stalactite_height = match ceiling {
            Some(c) if want_stalactite && !lava(region, c) => {
                let thickness = self.layer_thickness.sample(random);
                self.replace_with_base(d, region, [pos[0], c, pos[2]], thickness, UP);
                let max = match floor {
                    Some(f) => cluster_height.min(c - f),
                    None => cluster_height,
                };
                self.speleothem_height(random, dx, dz, density, max)
            }
            _ => 0,
        };
        let want_stalagmite = random.next_double() < chance;
        let stalagmite_height = match floor {
            Some(f) if want_stalagmite && !lava(region, f) => {
                let thickness = self.layer_thickness.sample(random);
                self.replace_with_base(d, region, [pos[0], f, pos[2]], thickness, DOWN);
                if ceiling.is_some() {
                    (stalactite_height
                        + between_inclusive(random, -self.max_height_diff, self.max_height_diff))
                    .max(0)
                } else {
                    self.speleothem_height(random, dx, dz, density, cluster_height)
                }
            }
            _ => 0,
        };
        let (actual_stalactite, actual_stalagmite) = match (ceiling, floor) {
            (Some(c), Some(f)) if c - stalactite_height <= f + stalagmite_height => {
                let lowest = (c - stalactite_height).max(f + 1);
                let highest = (f + stalagmite_height).min(c - 1);
                let bottom = between_inclusive(random, lowest, highest + 1);
                (c - bottom, bottom - 1 - f)
            }
            _ => (stalactite_height, stalagmite_height),
        };
        let merge = random.next_bool()
            && actual_stalactite > 0
            && actual_stalagmite > 0
            && column
                .height()
                .is_some_and(|h| actual_stalactite + actual_stalagmite == h);
        if let Some(c) = ceiling {
            self.blocks.grow(
                d,
                region,
                [pos[0], c - 1, pos[2]],
                DOWN,
                actual_stalactite,
                merge,
            )?;
        }
        if let Some(f) = floor {
            self.blocks.grow(
                d,
                region,
                [pos[0], f + 1, pos[2]],
                UP,
                actual_stalagmite,
                merge,
            )?;
        }
        Ok(())
    }

    fn speleothem_height(
        &self,
        random: &mut Random,
        dx: i32,
        dz: i32,
        density: f32,
        max_height: i32,
    ) -> i32 {
        if random.next_float() > density {
            return 0;
        }
        let distance = dx.abs() + dz.abs();
        // `Mth.clampedMap` on doubles.
        let t = (distance as f64 - 0.0) / (self.center_distance as f64 - 0.0);
        let to_min = max_height as f64 / 2.0;
        let mean = if t < 0.0 {
            to_min
        } else if t > 1.0 {
            0.0
        } else {
            to_min + t * (0.0 - to_min)
        } as f32;
        let sample = normal(random, mean, self.height_deviation as f32);
        super::java::clamp(sample, 0.0, max_height as f32) as i32
    }

    fn can_place_pool(&self, table: &BlockTable, region: &mut Region, pos: [i32; 3]) -> bool {
        let s = region.get(pos);
        let b = table.block_of(s);
        if b == self.kinds.water || b == self.blocks.base || b == self.blocks.pointed {
            return false;
        }
        let above = region.get(offset(pos, [0, 1, 0]));
        let water = |s: u16| {
            table.fluid(s) == FLUID_WATER || table.fluid(s) == super::blocks::FLUID_FLOWING_WATER
        };
        if water(above) {
            return false;
        }
        let adjacent = |region: &mut Region, p: [i32; 3]| {
            let s = region.get(p);
            table.in_tag(s, &self.kinds.base_stone) || water(s)
        };
        for h in HORIZONTAL {
            if !adjacent(region, offset(pos, h)) {
                return false;
            }
        }
        adjacent(region, offset(pos, [0, -1, 0]))
    }

    fn replace_with_base(
        &self,
        d: &Decoration,
        region: &mut Region,
        first: [i32; 3],
        count: i32,
        direction: usize,
    ) {
        let mut pos = first;
        for _ in 0..count {
            if !self.blocks.place_base(d, region, pos) {
                return;
            }
            pos = offset(pos, DIRECTIONS[direction]);
        }
    }
}

/// `SpeleothemFeature`: one pointed block (or two) under a ceiling or on a
/// floor, with a patch of base blocks behind it.
#[derive(Debug)]
pub struct Speleothem {
    kinds: Kinds,
    blocks: Blocks,
    taller: f32,
    directional: f32,
    radius2: f32,
    radius3: f32,
}

impl Speleothem {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Speleothem, String> {
        let f = |k: &str, default: f32| -> Result<f32, String> {
            json.get(k).map_or(Ok(default), |v| Ok(v.as_f64()? as f32))
        };
        Ok(Speleothem {
            kinds: Kinds::new(table)?,
            blocks: Blocks::parse(json, table)?,
            taller: f("chance_of_taller_generation", 0.2)?,
            directional: f("chance_of_directional_spread", 0.7)?,
            radius2: f("chance_of_spread_radius2", 0.5)?,
            radius3: f("chance_of_spread_radius3", 0.5)?,
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
        let above = self
            .blocks
            .is_base(table, region.get(offset(origin, [0, 1, 0])));
        let below = self
            .blocks
            .is_base(table, region.get(offset(origin, [0, -1, 0])));
        let tip = match (above, below) {
            (true, true) => {
                if random.next_bool() {
                    DOWN
                } else {
                    UP
                }
            }
            (true, false) => DOWN,
            (false, true) => UP,
            (false, false) => return Ok(false),
        };
        let root = offset(origin, DIRECTIONS[tip ^ 1]);
        self.blocks.place_base(d, region, root);
        for h in HORIZONTAL {
            if random.next_float() > self.directional {
                continue;
            }
            let p1 = offset(root, h);
            self.blocks.place_base(d, region, p1);
            if random.next_float() > self.radius2 {
                continue;
            }
            let p2 = offset(p1, DIRECTIONS[random.next_int_bounded(6) as usize]);
            self.blocks.place_base(d, region, p2);
            if random.next_float() > self.radius3 {
                continue;
            }
            let p3 = offset(p2, DIRECTIONS[random.next_int_bounded(6) as usize]);
            self.blocks.place_base(d, region, p3);
        }
        let height = if random.next_float() < self.taller
            && self
                .kinds
                .empty_or_water(table, region.get(offset(origin, DIRECTIONS[tip])))
        {
            2
        } else {
            1
        };
        self.blocks.grow(d, region, origin, tip, height, false)?;
        Ok(true)
    }
}

/// `SpeleothemBlock.updateShape` (pointed dripstone, sulfur spikes): a
/// waterlogged block schedules water; only vertical neighbours matter; a
/// stalactite with a scheduled tick of its own keeps its state; a block that
/// lost its support schedules its fall, else its thickness follows the
/// neighbours. It reads the level, not the neighbour it is handed.
pub fn update_shape(
    table: &BlockTable,
    region: &mut Region,
    state: u16,
    pos: [i32; 3],
    d: usize,
) -> Result<u16, String> {
    let speleothems = table.tag("minecraft:speleothems")?;
    let block = table.block_of(state);
    if table.value(state, "waterlogged") == Some("true") {
        region.schedule_fluid_tick(pos, FLUID_WATER);
    }
    if d != UP && d != DOWN {
        return Ok(state);
    }
    let tip = if table.value(state, "vertical_direction") == Some("down") {
        DOWN
    } else {
        UP
    };
    if tip == DOWN && region.has_block_tick(pos, block) {
        return Ok(state);
    }
    let with_direction = |s: u16, dir: usize| {
        table.in_tag(s, speleothems)
            && table.value(s, "vertical_direction") == Some(if dir == UP { "up" } else { "down" })
    };
    if d == tip ^ 1 {
        // `canSurvive`: a sturdy face behind, or a speleothem of this block
        // pointing the same way.
        let behind_pos = offset(pos, DIRECTIONS[tip ^ 1]);
        let behind = region.get(behind_pos);
        let survives = table.flag(behind, STURDY << tip)
            || (with_direction(behind, tip) && table.block_of(behind) == block);
        if !survives {
            region.schedule_block_tick(pos, block);
            return Ok(state);
        }
    }
    let merge = table.value(state, "thickness") == Some("tip_merge");
    let front = region.get(offset(pos, DIRECTIONS[tip]));
    let thickness = if with_direction(front, tip ^ 1) && table.block_of(front) == block {
        if !merge && table.value(front, "thickness") != Some("tip_merge") {
            "tip"
        } else {
            "tip_merge"
        }
    } else if !with_direction(front, tip) {
        "tip"
    } else {
        match table.value(front, "thickness") {
            Some("tip") | Some("tip_merge") => "frustum",
            _ => {
                let behind = region.get(offset(pos, DIRECTIONS[tip ^ 1]));
                if with_direction(behind, tip) {
                    "middle"
                } else {
                    "base"
                }
            }
        }
    };
    table
        .with(state, "thickness", thickness)
        .ok_or_else(|| "speleothem thickness".to_string())
}
