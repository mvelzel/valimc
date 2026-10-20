//! Noise terrain (VMC-024a): vanilla's `NoiseBasedChunkGenerator.doFill` with
//! its aquifer. A chunk's final density is sampled over the whole chunk at
//! block resolution through one cached sampling context, then each column is
//! filled top-down with what the aquifer chooses: nothing (the default block),
//! a fluid or air. The aquifer point-samples its noises through the same
//! context, after the surface-level volume and the density volume, so the
//! sampling order follows vanilla's exactly.

use std::collections::HashMap;
use std::sync::Arc;

use super::java::floor_f32;
use super::random::Positional;
use super::sampler::{Context, Sampler};
use super::volume::Volume;

/// `DimensionType.WAY_BELOW_MIN_Y`: the fluid level of a dry aquifer.
const WAY_BELOW_MIN_Y: i32 = -32512;
/// Below this level the global fluid is lava.
const LAVA_LEVEL: i32 = -54;

/// The block states terrain places, as global state ids.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerrainBlocks {
    pub air: u16,
    pub water: u16,
    pub lava: u16,
    pub default_block: u16,
    pub default_fluid: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FluidStatus {
    level: i32,
    fluid: u16,
}

impl FluidStatus {
    fn at(&self, y: i32, air: u16) -> u16 {
        if y < self.level {
            self.fluid
        } else {
            air
        }
    }
}

/// The global fluid: lava below -54 (or below sea level, if that is lower),
/// the default fluid below sea level.
#[derive(Clone, Copy, Debug)]
struct FluidPicker {
    sea_level: i32,
    blocks: TerrainBlocks,
}

impl FluidPicker {
    fn at(&self, y: i32) -> FluidStatus {
        if y < LAVA_LEVEL.min(self.sea_level) {
            FluidStatus {
                level: LAVA_LEVEL,
                fluid: self.blocks.lava,
            }
        } else {
            FluidStatus {
                level: self.sea_level,
                fluid: self.blocks.default_fluid,
            }
        }
    }
}

/// The aquifer functions of noise settings, compiled.
#[derive(Clone, Debug)]
pub struct AquiferSamplers {
    pub barrier: Arc<Sampler>,
    pub floodedness: Arc<Sampler>,
    pub spread: Arc<Sampler>,
    pub lava: Arc<Sampler>,
    pub exclusion: Arc<Sampler>,
    pub surface_level: Arc<Sampler>,
}

fn grid_xz(block: i32) -> i32 {
    block >> 4
}

fn from_grid_xz(grid: i32, offset: i32) -> i32 {
    (grid << 4) + offset
}

fn grid_y(block: i32) -> i32 {
    block.div_euclid(12)
}

fn from_grid_y(grid: i32, offset: i32) -> i32 {
    grid * 12 + offset
}

fn quart_floor(block: i32) -> i32 {
    (block >> 2) << 2
}

fn similarity(d1: i32, d2: i32) -> f64 {
    1.0 - (d2 - d1) as f64 / 25.0
}

/// `similarity(10², 12²)`: closer aquifer pairs may flow into each other.
fn flowing_update_similarity() -> f64 {
    similarity(100, 144)
}

const SURFACE_OFFSETS: [(i32, i32); 13] = [
    (0, 0),
    (-2, -1),
    (-1, -1),
    (0, -1),
    (1, -1),
    (-3, 0),
    (-2, 0),
    (-1, 0),
    (1, 0),
    (-2, 1),
    (-1, 1),
    (0, 1),
    (1, 1),
];

/// Vanilla's `NoiseBasedAquifer` for one noise chunk.
struct NoiseAquifer<'a> {
    samplers: &'a AquiferSamplers,
    positional: Positional,
    picker: FluidPicker,
    status_cache: Vec<Option<FluidStatus>>,
    location_cache: Vec<Option<(i32, i32, i32)>>,
    min_grid: [i32; 3],
    grid_size_x: i32,
    grid_size_z: i32,
    skip_sampling_above_y: i32,
    surface_levels: HashMap<(i32, i32), i32>,
    should_schedule_fluid_update: bool,
}

impl<'a> NoiseAquifer<'a> {
    fn new(
        ctx: &mut Context,
        samplers: &'a AquiferSamplers,
        positional: Positional,
        volume: &Volume,
        picker: FluidPicker,
    ) -> Self {
        let min_grid_x = grid_xz(volume.min[0] - 5);
        let max_grid_x = grid_xz(volume.max_block(0) - 5) + 1;
        let min_grid_y = grid_y(volume.min[1] + 1) - 1;
        let max_grid_y = grid_y(volume.max_block(1) + 1) + 1;
        let min_grid_z = grid_xz(volume.min[2] - 5);
        let max_grid_z = grid_xz(volume.max_block(2) - 5) + 1;
        let (gx, gy, gz) = (
            max_grid_x - min_grid_x + 1,
            max_grid_y - min_grid_y + 1,
            max_grid_z - min_grid_z + 1,
        );
        let total = (gx * gy * gz) as usize;
        let mut aquifer = NoiseAquifer {
            samplers,
            positional,
            picker,
            status_cache: vec![None; total],
            location_cache: vec![None; total],
            min_grid: [min_grid_x, min_grid_y, min_grid_z],
            grid_size_x: gx,
            grid_size_z: gz,
            skip_sampling_above_y: 0,
            surface_levels: HashMap::new(),
            should_schedule_fluid_update: false,
        };
        let max_surface = aquifer.max_surface_level(
            ctx,
            from_grid_xz(min_grid_x, 0),
            from_grid_xz(min_grid_z, 0),
            from_grid_xz(max_grid_x, 9),
            from_grid_xz(max_grid_z, 9),
        );
        let skip_grid_y = grid_y(max_surface + 8 + 12) + 1;
        aquifer.skip_sampling_above_y = from_grid_y(skip_grid_y, 11) - 1;
        aquifer
    }

    /// Samples the surface level over the aquifer's quarts and caches it.
    fn max_surface_level(
        &mut self,
        ctx: &mut Context,
        min_x: i32,
        min_z: i32,
        max_x: i32,
        max_z: i32,
    ) -> i32 {
        let (min_qx, max_qx, min_qz, max_qz) = (min_x >> 2, max_x >> 2, min_z >> 2, max_z >> 2);
        let volume = Volume {
            size: [max_qx - min_qx + 1, 1, max_qz - min_qz + 1],
            min: [min_qx << 2, 0, min_qz << 2],
            step: [4, 1, 4],
        };
        let mut buffer = vec![0.0f32; volume.len()];
        self.samplers.surface_level.fill(ctx, &mut buffer, &volume);
        let mut max_y = i32::MIN;
        for z in 0..volume.size[2] {
            for x in 0..volume.size[0] {
                let level = floor_f32(buffer[volume.index(x, 0, z)]);
                self.surface_levels
                    .insert((volume.block(0, x), volume.block(2, z)), level);
                max_y = max_y.max(level);
            }
        }
        max_y
    }

    fn surface_level(&mut self, ctx: &mut Context, x: i32, z: i32) -> i32 {
        let key = (quart_floor(x), quart_floor(z));
        if let Some(&level) = self.surface_levels.get(&key) {
            return level;
        }
        let level = floor_f32(self.samplers.surface_level.value(ctx, key.0, 0, key.1));
        self.surface_levels.insert(key, level);
        level
    }

    fn index(&self, gx: i32, gy: i32, gz: i32) -> usize {
        let (x, y, z) = (
            gx - self.min_grid[0],
            gy - self.min_grid[1],
            gz - self.min_grid[2],
        );
        ((y * self.grid_size_z + z) * self.grid_size_x + x) as usize
    }

    fn location(&mut self, gx: i32, gy: i32, gz: i32) -> (usize, (i32, i32, i32)) {
        let index = self.index(gx, gy, gz);
        if let Some(location) = self.location_cache[index] {
            return (index, location);
        }
        let mut random = self.positional.at(gx, gy, gz);
        let x = from_grid_xz(gx, random.next_int_bounded(10));
        let y = from_grid_y(gy, random.next_int_bounded(9));
        let z = from_grid_xz(gz, random.next_int_bounded(10));
        // Stored packed as a block position in vanilla; positions here stay in range.
        self.location_cache[index] = Some((x, y, z));
        (index, (x, y, z))
    }

    fn status(&mut self, ctx: &mut Context, index: usize) -> FluidStatus {
        if let Some(status) = self.status_cache[index] {
            return status;
        }
        let (x, y, z) = self.location_cache[index].expect("located before its status");
        let status = self.compute_fluid(ctx, x, y, z);
        self.status_cache[index] = Some(status);
        status
    }

    fn compute_substance(
        &mut self,
        ctx: &mut Context,
        x: i32,
        y: i32,
        z: i32,
        density: f64,
    ) -> Option<u16> {
        let air = self.picker.blocks.air;
        let lava = self.picker.blocks.lava;
        let water = self.picker.blocks.water;
        if density > 0.0 {
            self.should_schedule_fluid_update = false;
            return None;
        }
        let global = self.picker.at(y);
        if y > self.skip_sampling_above_y {
            self.should_schedule_fluid_update = false;
            return Some(global.at(y, air));
        }
        if global.at(y, air) == lava {
            self.should_schedule_fluid_update = false;
            return Some(lava);
        }
        let (ax, ay, az) = (grid_xz(x - 5), grid_y(y + 1), grid_xz(z - 5));
        let mut distances = [i32::MAX; 4];
        let mut closest = [0usize; 4];
        for x1 in 0..=1 {
            for y1 in -1..=1 {
                for z1 in 0..=1 {
                    let (index, (lx, ly, lz)) = self.location(ax + x1, ay + y1, az + z1);
                    let (dx, dy, dz) = (lx - x, ly - y, lz - z);
                    let d = dx * dx + dy * dy + dz * dz;
                    if let Some(slot) = distances.iter().position(|&existing| existing >= d) {
                        for k in (slot + 1..4).rev() {
                            distances[k] = distances[k - 1];
                            closest[k] = closest[k - 1];
                        }
                        distances[slot] = d;
                        closest[slot] = index;
                    }
                }
            }
        }
        let flowing = flowing_update_similarity();
        let status1 = self.status(ctx, closest[0]);
        let similarity12 = similarity(distances[0], distances[1]);
        let fluid = status1.at(y, air);
        if similarity12 <= 0.0 {
            self.should_schedule_fluid_update = if similarity12 >= flowing {
                status1 != self.status(ctx, closest[1])
            } else {
                false
            };
            return Some(fluid);
        }
        if fluid == water && self.picker.at(y - 1).at(y - 1, air) == lava {
            self.should_schedule_fluid_update = true;
            return Some(fluid);
        }
        let mut barrier = f64::NAN;
        let status2 = self.status(ctx, closest[1]);
        let barrier12 = similarity12 * self.pressure(ctx, x, y, z, &mut barrier, status1, status2);
        if density + barrier12 > 0.0 {
            self.should_schedule_fluid_update = false;
            return None;
        }
        let status3 = self.status(ctx, closest[2]);
        let similarity13 = similarity(distances[0], distances[2]);
        if similarity13 > 0.0 {
            let barrier13 = similarity12
                * similarity13
                * self.pressure(ctx, x, y, z, &mut barrier, status1, status3);
            if density + barrier13 > 0.0 {
                self.should_schedule_fluid_update = false;
                return None;
            }
        }
        let similarity23 = similarity(distances[1], distances[2]);
        if similarity23 > 0.0 {
            let barrier23 = similarity12
                * similarity23
                * self.pressure(ctx, x, y, z, &mut barrier, status2, status3);
            if density + barrier23 > 0.0 {
                self.should_schedule_fluid_update = false;
                return None;
            }
        }
        let may_flow12 = status1 != status2;
        let may_flow23 = similarity23 >= flowing && status2 != status3;
        let may_flow13 = similarity13 >= flowing && status1 != status3;
        self.should_schedule_fluid_update = if may_flow12 || may_flow23 || may_flow13 {
            true
        } else {
            similarity13 >= flowing
                && similarity(distances[0], distances[3]) >= flowing
                && status1 != self.status(ctx, closest[3])
        };
        Some(fluid)
    }

    #[allow(clippy::too_many_arguments)]
    fn pressure(
        &mut self,
        ctx: &mut Context,
        x: i32,
        y: i32,
        z: i32,
        barrier: &mut f64,
        first: FluidStatus,
        second: FluidStatus,
    ) -> f64 {
        let (air, lava, water) = (
            self.picker.blocks.air,
            self.picker.blocks.lava,
            self.picker.blocks.water,
        );
        let (a, b) = (first.at(y, air), second.at(y, air));
        if (a == lava && b == water) || (a == water && b == lava) {
            return 2.0;
        }
        let level_diff = (first.level - second.level).abs();
        if level_diff == 0 {
            return 0.0;
        }
        let average = 0.5 * (first.level + second.level) as f64;
        let above_average = y as f64 + 0.5 - average;
        let base = level_diff as f64 / 2.0;
        let towards_middle = base - above_average.abs();
        let gradient = if above_average > 0.0 {
            let center = 0.0 + towards_middle;
            if center > 0.0 {
                center / 1.5
            } else {
                center / 2.5
            }
        } else {
            let center = 3.0 + towards_middle;
            if center > 0.0 {
                center / 3.0
            } else {
                center / 10.0
            }
        };
        let noise = if !(-2.0..=2.0).contains(&gradient) {
            0.0
        } else {
            if barrier.is_nan() {
                *barrier = self.samplers.barrier.value(ctx, x, y, z) as f64;
            }
            *barrier
        };
        2.0 * (noise + gradient)
    }

    fn compute_fluid(&mut self, ctx: &mut Context, x: i32, y: i32, z: i32) -> FluidStatus {
        let air = self.picker.blocks.air;
        let global = self.picker.at(y);
        let mut lowest = i32::MAX;
        let (top, bottom) = (y + 12, y - 12);
        let mut center_under_fluid = false;
        for (ox, oz) in SURFACE_OFFSETS {
            let (sx, sz) = (x + (ox << 4), z + (oz << 4));
            let level = self.surface_level(ctx, sx, sz);
            let adjusted = level + 8;
            let start = ox == 0 && oz == 0;
            if start && bottom > adjusted {
                return global;
            }
            let pokes_above = top > adjusted;
            if pokes_above || start {
                let at_surface = self.picker.at(adjusted);
                if at_surface.at(adjusted, air) != air {
                    if start {
                        center_under_fluid = true;
                    }
                    if pokes_above {
                        return at_surface;
                    }
                }
            }
            lowest = lowest.min(level);
        }
        let level = self.fluid_surface_level(ctx, x, y, z, global, lowest, center_under_fluid);
        FluidStatus {
            level,
            fluid: self.fluid_type(ctx, x, y, z, global, level),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn fluid_surface_level(
        &mut self,
        ctx: &mut Context,
        x: i32,
        y: i32,
        z: i32,
        global: FluidStatus,
        lowest: i32,
        center_under_fluid: bool,
    ) -> i32 {
        let (partially, fully) = if self.samplers.exclusion.value(ctx, x, y, z) as f64 > 0.0 {
            (-1.0, -1.0)
        } else {
            let below_surface = (lowest + 8 - y) as f64;
            let factor = if center_under_fluid {
                let t = below_surface / 64.0;
                if t < 0.0 {
                    1.0
                } else if t > 1.0 {
                    0.0
                } else {
                    1.0 + t * (0.0 - 1.0)
                }
            } else {
                0.0
            };
            let noise = self.samplers.floodedness.value(ctx, x, y, z) as f64;
            let noise = if noise < -1.0 { -1.0 } else { noise.min(1.0) };
            let map = |to_min: f64, to_max: f64| {
                let t = (factor - 1.0) / (0.0 - 1.0);
                to_min + t * (to_max - to_min)
            };
            (noise - map(-0.8, 0.4), noise - map(-0.3, 0.8))
        };
        if fully > 0.0 {
            global.level
        } else if partially > 0.0 {
            self.randomized_fluid_level(ctx, x, y, z, lowest)
        } else {
            WAY_BELOW_MIN_Y
        }
    }

    fn randomized_fluid_level(
        &mut self,
        ctx: &mut Context,
        x: i32,
        y: i32,
        z: i32,
        lowest: i32,
    ) -> i32 {
        let (cx, cy, cz) = (x.div_euclid(16), y.div_euclid(40), z.div_euclid(16));
        let middle = cy * 40 + 20;
        let spread = (self.samplers.spread.value(ctx, cx, cy, cz) * 10.0) as f64;
        let quantized = (spread / 3.0).floor() as i32 * 3;
        lowest.min(middle + quantized)
    }

    #[allow(clippy::too_many_arguments)]
    fn fluid_type(
        &mut self,
        ctx: &mut Context,
        x: i32,
        y: i32,
        z: i32,
        global: FluidStatus,
        level: i32,
    ) -> u16 {
        let lava = self.picker.blocks.lava;
        if level <= -10 && level != WAY_BELOW_MIN_Y && global.fluid != lava {
            let (cx, cy, cz) = (x.div_euclid(64), y.div_euclid(40), z.div_euclid(64));
            let noise = self.samplers.lava.value(ctx, cx, cy, cz) as f64;
            if noise.abs() > 0.3 {
                return lava;
            }
        }
        global.fluid
    }
}

/// A chunk's noise terrain.
#[derive(Clone, Debug)]
pub struct FilledChunk {
    /// State ids, Y fastest from the volume's bottom, then X, then Z.
    pub blocks: Vec<u16>,
    /// Fluid positions the aquifer marks for a fluid update.
    pub fluid_updates: Vec<(i32, i32, i32)>,
}

/// Fills `volume` (one chunk, block steps) from `final_density` and the
/// aquifer, as `doFill` does.
pub fn fill(
    final_density: &Sampler,
    aquifer: Option<(&AquiferSamplers, Positional)>,
    volume: &Volume,
    sea_level: i32,
    blocks: TerrainBlocks,
) -> FilledChunk {
    let mut ctx = Context::cached();
    let picker = FluidPicker { sea_level, blocks };
    let mut noise_aquifer = aquifer.map(|(samplers, positional)| {
        NoiseAquifer::new(&mut ctx, samplers, positional, volume, picker)
    });
    let mut density = vec![0.0f32; volume.len()];
    final_density.fill(&mut ctx, &mut density, volume);
    let mut out = vec![blocks.air; volume.len()];
    let mut fluid_updates = Vec::new();
    let is_fluid = |state: u16| state == blocks.water || state == blocks.lava;
    for iz in 0..volume.size[2] {
        let z = volume.block(2, iz);
        for ix in 0..volume.size[0] {
            let x = volume.block(0, ix);
            for iy in (0..volume.size[1]).rev() {
                let y = volume.block(1, iy);
                let index = volume.index(ix, iy, iz);
                let d = density[index] as f64;
                let (substance, schedule) = match noise_aquifer.as_mut() {
                    Some(aquifer) => {
                        let s = aquifer.compute_substance(&mut ctx, x, y, z, d);
                        (s, aquifer.should_schedule_fluid_update)
                    }
                    None => (
                        if d > 0.0 {
                            None
                        } else {
                            Some(picker.at(y).at(y, blocks.air))
                        },
                        false,
                    ),
                };
                let state = substance.unwrap_or(blocks.default_block);
                if state != blocks.air {
                    out[index] = state;
                    if schedule && is_fluid(state) {
                        fluid_updates.push((x, y, z));
                    }
                }
            }
        }
    }
    FilledChunk {
        blocks: out,
        fluid_updates,
    }
}
