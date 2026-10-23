//! What the spawner reads of a level (VMC-042a): block states, light,
//! heightmaps and biomes. A group's sections (`Live`) or an oracle's scene
//! (`Scene`) supply them.

use crate::column::{ColumnStore, HEIGHT, MIN_Y};
use crate::flags::BlockFlags;
use crate::physics::source::BlockSource;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

/// `Heightmap.Types` indexes the spawner reads.
pub const WORLD_SURFACE: usize = 1;
pub const MOTION_BLOCKING: usize = 4;

pub trait Level {
    /// The state at a position, `None` where it cannot be read (outside the
    /// held chunks or the build height).
    fn state(&self, p: [i32; 3]) -> Option<u16>;
    /// Sky and block light at a position (0, 0 where unknown).
    fn light(&self, p: [i32; 3]) -> (u8, u8);
    /// `getHeight(type, x, z)`: one above the highest matching block, MIN_Y
    /// for none.
    fn height(&self, map: usize, x: i32, z: i32) -> i32;
    /// The biome registry id at a block (`BiomeManager.getBiome`).
    fn biome(&self, p: [i32; 3]) -> u16;
}

/// The physics kernel's view of a level's blocks: unreadable cells fail a
/// collision test closed.
pub struct Source<'a>(pub &'a dyn Level);

impl BlockSource for Source<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        if !(MIN_Y..MIN_Y + HEIGHT as i32).contains(&y) {
            return Some(0);
        }
        self.0.state([x, y, z])
    }
}

/// A chunk's heights for one heightmap (`Column::heights`).
type Heights = [u16; 256];

/// Heights computed this call, by chunk and heightmap.
type HeightCache = RefCell<HashMap<((i32, i32), usize), Heights>>;

/// A group's sections: the store holding each chunk, not the absent ones.
pub struct Live<'s> {
    pub stores: &'s [&'s ColumnStore],
    pub absent: &'s HashSet<(i32, i32)>,
    pub flags: &'s BlockFlags,
    pub zoom_seed: i64,
    pub plains: u16,
    heights: HeightCache,
}

impl<'s> Live<'s> {
    pub fn new(
        stores: &'s [&'s ColumnStore],
        absent: &'s HashSet<(i32, i32)>,
        flags: &'s BlockFlags,
        zoom_seed: i64,
        plains: u16,
    ) -> Self {
        Live {
            stores,
            absent,
            flags,
            zoom_seed,
            plains,
            heights: RefCell::new(HashMap::new()),
        }
    }

    pub fn store(&self, chunk: (i32, i32)) -> Option<&ColumnStore> {
        if self.absent.contains(&chunk) {
            return None;
        }
        self.stores.iter().copied().find(|s| {
            let (min, size) = (s.chunk_min, s.chunk_size);
            (min.0..min.0 + size).contains(&chunk.0) && (min.1..min.1 + size).contains(&chunk.1)
        })
    }

    /// Whether a chunk is held (in a store, generated).
    pub fn holds(&self, chunk: (i32, i32)) -> bool {
        self.store(chunk).is_some()
    }
}

impl Level for Live<'_> {
    fn state(&self, p: [i32; 3]) -> Option<u16> {
        self.store((p[0] >> 4, p[2] >> 4))?
            .get(p[0], p[1], p[2])
            .ok()
    }

    fn light(&self, p: [i32; 3]) -> (u8, u8) {
        self.store((p[0] >> 4, p[2] >> 4))
            .and_then(|s| s.light_at(p[0], p[1], p[2]))
            .unwrap_or((0, 0))
    }

    fn height(&self, map: usize, x: i32, z: i32) -> i32 {
        let chunk = (x >> 4, z >> 4);
        let Some(store) = self.store(chunk) else {
            return MIN_Y;
        };
        let mask = 1u8 << map;
        let mut cache = self.heights.borrow_mut();
        let heights =
            cache
                .entry((chunk, map))
                .or_insert_with(|| match store.columns.get(&chunk) {
                    Some(column) => column.heights(self.flags, mask),
                    None => {
                        let top = (0..HEIGHT)
                            .rev()
                            .find(|&y| self.flags.get(store.layers[y]) & mask != 0)
                            .map_or(0, |y| y as u16 + 1);
                        [top; 256]
                    }
                });
        MIN_Y + heights[((z & 15) * 16 + (x & 15)) as usize] as i32
    }

    fn biome(&self, p: [i32; 3]) -> u16 {
        let quart = crate::worldgen::surface::zoom(self.zoom_seed, p[0], p[1], p[2]);
        self.store((quart.0 >> 2, quart.2 >> 2))
            .and_then(|s| s.noise_biome(quart, self.plains))
            .unwrap_or(self.plains)
    }
}

/// An oracle scene (`NaturalSpawnOracle`): boxes of states over air, one
/// biome, sky light at and above the motion-blocking surface and none below
/// it, block light falling off by one per block of taxicab distance from its
/// sources.
pub struct Scene<'s> {
    /// `(min, max, state)`, later boxes over earlier ones.
    pub fills: Vec<([i32; 3], [i32; 3], u16)>,
    pub lights: Vec<([i32; 3], i32)>,
    pub sky: u8,
    pub biome: u16,
    pub flags: &'s BlockFlags,
    cache: RefCell<HashMap<(usize, i32, i32), i32>>,
}

impl<'s> Scene<'s> {
    pub fn new(
        fills: Vec<([i32; 3], [i32; 3], u16)>,
        lights: Vec<([i32; 3], i32)>,
        sky: u8,
        biome: u16,
        flags: &'s BlockFlags,
    ) -> Self {
        Scene {
            fills,
            lights,
            sky,
            biome,
            flags,
            cache: RefCell::new(HashMap::new()),
        }
    }

    fn at(&self, p: [i32; 3]) -> u16 {
        for (min, max, state) in self.fills.iter().rev() {
            if (0..3).all(|a| p[a] >= min[a] && p[a] <= max[a]) {
                return *state;
            }
        }
        0
    }
}

impl Level for Scene<'_> {
    fn state(&self, p: [i32; 3]) -> Option<u16> {
        Some(self.at(p))
    }

    fn light(&self, p: [i32; 3]) -> (u8, u8) {
        let sky = if p[1] >= self.height(MOTION_BLOCKING, p[0], p[2]) {
            self.sky
        } else {
            0
        };
        let block = self
            .lights
            .iter()
            .map(|(at, level)| level - (0..3).map(|a| (p[a] - at[a]).abs()).sum::<i32>())
            .fold(0, i32::max);
        (sky, block as u8)
    }

    fn height(&self, map: usize, x: i32, z: i32) -> i32 {
        if let Some(&h) = self.cache.borrow().get(&(map, x, z)) {
            return h;
        }
        let top = self
            .fills
            .iter()
            .filter(|(min, max, _)| x >= min[0] && x <= max[0] && z >= min[2] && z <= max[2])
            .map(|(_, max, _)| max[1])
            .max();
        let mask = 1u8 << map;
        let mut h = MIN_Y;
        if let Some(top) = top {
            let mut y = top.min(MIN_Y + HEIGHT as i32 - 1);
            while y >= MIN_Y {
                if self.flags.get(self.at([x, y, z])) & mask != 0 {
                    h = y + 1;
                    break;
                }
                y -= 1;
            }
        }
        self.cache.borrow_mut().insert((map, x, z), h);
        h
    }

    fn biome(&self, _p: [i32; 3]) -> u16 {
        self.biome
    }
}
