//! Live light over an area of chunks (VMC-022c): sky and block light stored per
//! section as one uniform level or a vanilla nibble array, kept equal to the
//! fixpoint of `light`'s rules when blocks change.
//!
//! An update works like vanilla's decrease and increase queues: light that may
//! have depended on the changed cells (or on sky sources a column lost) is
//! cleared outward while it is dimmer than what removed it, brighter cells met
//! on the way and every source in the cleared region are queued again, and the
//! increase pass spreads them back to the fixpoint.

use crate::light::{LightFacts, HEIGHT};

/// Block states of the area, `x` and `z` in `0..wx`/`0..wz`, `y` in `0..HEIGHT`.
pub trait LightBlocks {
    fn wx(&self) -> usize;
    fn wz(&self) -> usize;
    fn state(&self, x: usize, y: usize, z: usize) -> u16;
    /// Whether the dimension has sky light (the Nether has none, VMC-026b).
    fn has_sky(&self) -> bool {
        true
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Layer {
    Uniform(u8),
    Nibbles(Box<[u8; 2048]>),
}

impl Layer {
    #[inline]
    fn get(&self, i: usize) -> u8 {
        match self {
            Layer::Uniform(level) => *level,
            Layer::Nibbles(bytes) => (bytes[i >> 1] >> ((i & 1) * 4)) & 15,
        }
    }

    fn set(&mut self, i: usize, level: u8) {
        if let Layer::Uniform(current) = *self {
            if current == level {
                return;
            }
            let fill = current | current << 4;
            *self = Layer::Nibbles(Box::new([fill; 2048]));
        }
        if let Layer::Nibbles(bytes) = self {
            let shift = (i & 1) * 4;
            bytes[i >> 1] = (bytes[i >> 1] & !(15 << shift)) | (level << shift);
        }
    }

    /// The vanilla nibble array of this layer.
    pub fn nibbles(&self) -> [u8; 2048] {
        match self {
            Layer::Uniform(level) => [level | level << 4; 2048],
            Layer::Nibbles(bytes) => **bytes,
        }
    }

    /// Collapse to `Uniform` when every cell holds one level.
    pub fn compact(&mut self) {
        if let Layer::Nibbles(bytes) = self {
            let first = bytes[0] & 15;
            if bytes.iter().all(|b| *b == first | first << 4) {
                *self = Layer::Uniform(first);
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Sky,
    Block,
}

const SECTIONS: usize = HEIGHT / 16;
const OFFSETS: [(i32, i32, i32); 6] = [
    (0, -1, 0),
    (0, 1, 0),
    (0, 0, -1),
    (0, 0, 1),
    (-1, 0, 0),
    (1, 0, 0),
];

type Cell = (usize, usize, usize);

pub struct LightGrid {
    wx: usize,
    wz: usize,
    sky: Vec<Layer>,
    block: Vec<Layer>,
    /// Sections whose sky or block light changed since `take_dirty`.
    dirty: Vec<bool>,
    /// Lowest sky source per column (`x * wz + z`); `HEIGHT` when none.
    lowest: Vec<usize>,
}

impl LightGrid {
    /// Light an area from scratch.
    pub fn compute(blocks: &impl LightBlocks, facts: &LightFacts) -> LightGrid {
        let (wx, wz) = (blocks.wx(), blocks.wz());
        assert!(wx % 16 == 0 && wz % 16 == 0);
        let sections = (wx / 16) * (wz / 16) * SECTIONS;
        let mut grid = LightGrid {
            wx,
            wz,
            sky: vec![Layer::Uniform(0); sections],
            block: vec![Layer::Uniform(0); sections],
            dirty: vec![false; sections],
            lowest: vec![HEIGHT; wx * wz],
        };
        let mut increase = Increase::new();
        for x in 0..wx {
            for z in 0..wz {
                grid.lowest[x * wz + z] = lowest_source(blocks, facts, x, z);
            }
        }
        // Whole sections at or above every column's lowest source are open sky.
        for cx in 0..wx / 16 {
            for cz in 0..wz / 16 {
                let low = (0..16)
                    .flat_map(|x| (0..16).map(move |z| (x, z)))
                    .map(|(x, z)| grid.lowest[(cx * 16 + x) * wz + cz * 16 + z])
                    .max()
                    .unwrap_or(HEIGHT);
                for s in low.div_ceil(16)..SECTIONS {
                    grid.sky[(cx * (wz / 16) + cz) * SECTIONS + s] = Layer::Uniform(15);
                }
            }
        }
        for x in 0..wx {
            for z in 0..wz {
                let low = grid.lowest[x * wz + z];
                for y in low..HEIGHT {
                    if grid.get(Kind::Sky, (x, y, z)) != 15 {
                        grid.set(Kind::Sky, (x, y, z), 15);
                    }
                }
                let mut top = low;
                for (dx, dz) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
                    let (nx, nz) = (x as i64 + dx, z as i64 + dz);
                    if nx >= 0 && nz >= 0 && (nx as usize) < wx && (nz as usize) < wz {
                        top = top.max(grid.lowest[nx as usize * wz + nz as usize]);
                    }
                }
                for y in low..top.max(low + 1).min(HEIGHT) {
                    increase.push(Kind::Sky, 15, (x, y, z));
                }
                for y in 0..HEIGHT {
                    let emission = facts.emission(blocks.state(x, y, z));
                    if emission > 0 {
                        grid.set(Kind::Block, (x, y, z), emission);
                        increase.push(Kind::Block, emission, (x, y, z));
                    }
                }
            }
        }
        grid.increase(blocks, facts, increase);
        grid.compact();
        grid.dirty.fill(false);
        grid
    }

    /// Chunks (area chunk coordinates) whose light changed since the last call.
    pub fn take_dirty(&mut self) -> Vec<(usize, usize)> {
        let per_x = (self.wz / 16) * SECTIONS;
        let mut chunks: Vec<(usize, usize)> = self
            .dirty
            .iter()
            .enumerate()
            .filter(|(_, dirty)| **dirty)
            .map(|(s, _)| (s / per_x, (s % per_x) / SECTIONS))
            .collect();
        chunks.dedup();
        self.dirty.fill(false);
        chunks
    }

    #[inline]
    fn layer_index(&self, (x, y, z): Cell) -> (usize, usize) {
        let section = ((x / 16) * (self.wz / 16) + z / 16) * SECTIONS + y / 16;
        (section, ((y & 15) << 8) | ((z & 15) << 4) | (x & 15))
    }

    #[inline]
    pub fn get(&self, kind: Kind, cell: Cell) -> u8 {
        let (s, i) = self.layer_index(cell);
        match kind {
            Kind::Sky => self.sky[s].get(i),
            Kind::Block => self.block[s].get(i),
        }
    }

    #[inline]
    fn set(&mut self, kind: Kind, cell: Cell, level: u8) {
        let (s, i) = self.layer_index(cell);
        self.dirty[s] = true;
        match kind {
            Kind::Sky => self.sky[s].set(i, level),
            Kind::Block => self.block[s].set(i, level),
        }
    }

    /// The layers of one chunk (chunk coordinates within the area), bottom up.
    pub fn chunk(&self, kind: Kind, cx: usize, cz: usize) -> &[Layer] {
        let start = (cx * (self.wz / 16) + cz) * SECTIONS;
        match kind {
            Kind::Sky => &self.sky[start..start + SECTIONS],
            Kind::Block => &self.block[start..start + SECTIONS],
        }
    }

    pub fn compact(&mut self) {
        self.sky
            .iter_mut()
            .chain(self.block.iter_mut())
            .for_each(Layer::compact);
    }

    fn neighbour(&self, (x, y, z): Cell, d: usize) -> Option<Cell> {
        let (dx, dy, dz) = OFFSETS[d];
        let (nx, ny, nz) = (
            x as i64 + dx as i64,
            y as i64 + dy as i64,
            z as i64 + dz as i64,
        );
        (nx >= 0
            && nz >= 0
            && ny >= 0
            && (nx as usize) < self.wx
            && (nz as usize) < self.wz
            && (ny as usize) < HEIGHT)
            .then_some((nx as usize, ny as usize, nz as usize))
    }

    fn source(
        &self,
        kind: Kind,
        blocks: &impl LightBlocks,
        facts: &LightFacts,
        (x, y, z): Cell,
    ) -> u8 {
        match kind {
            Kind::Block => facts.emission(blocks.state(x, y, z)),
            Kind::Sky if y >= self.lowest[x * self.wz + z] => 15,
            Kind::Sky => 0,
        }
    }

    /// Bring light up to date after `changed` cells got the states `blocks` now holds.
    pub fn update(&mut self, blocks: &impl LightBlocks, facts: &LightFacts, changed: &[Cell]) {
        let mut increase = Increase::new();
        for kind in [Kind::Sky, Kind::Block] {
            let mut seeds: Vec<(Cell, u8)> = Vec::new();
            if kind == Kind::Sky {
                let mut columns: Vec<(usize, usize)> =
                    changed.iter().map(|&(x, _, z)| (x, z)).collect();
                columns.sort_unstable();
                columns.dedup();
                for (x, z) in columns {
                    let old = self.lowest[x * self.wz + z];
                    let new = lowest_source(blocks, facts, x, z);
                    self.lowest[x * self.wz + z] = new;
                    // Cells that stopped being sources are cleared like changed cells.
                    for y in old.min(HEIGHT)..new.min(HEIGHT) {
                        seeds.push(((x, y, z), self.get(kind, (x, y, z))));
                    }
                    for y in new..old.min(HEIGHT) {
                        self.set(kind, (x, y, z), 15);
                        increase.push(kind, 15, (x, y, z));
                    }
                }
            }
            for &cell in changed {
                seeds.push((cell, self.get(kind, cell)));
            }
            let cleared = self.decrease(kind, seeds, &mut increase);
            // Sources in the cleared region, and light now able to enter the changed cells.
            for cell in cleared.into_iter().chain(changed.iter().copied()) {
                let source = self.source(kind, blocks, facts, cell);
                if source > self.get(kind, cell) {
                    self.set(kind, cell, source);
                    increase.push(kind, source, cell);
                }
            }
            for &cell in changed {
                for d in 0..6 {
                    if let Some(next) = self.neighbour(cell, d) {
                        let level = self.get(kind, next);
                        if level > 1 {
                            increase.push(kind, level, next);
                        }
                    }
                }
            }
        }
        self.increase(blocks, facts, increase);
    }

    /// Clear light that may have come from the seeds (cells with their former
    /// levels): neighbours dimmer than the light that reached them are cleared in
    /// turn, brighter ones are queued to spread again. Returns the cleared cells.
    fn decrease(
        &mut self,
        kind: Kind,
        seeds: Vec<(Cell, u8)>,
        increase: &mut Increase,
    ) -> Vec<Cell> {
        let mut queue = std::collections::VecDeque::new();
        let mut cleared = Vec::new();
        for (cell, level) in seeds {
            if level > 0 {
                self.set(kind, cell, 0);
                cleared.push(cell);
                queue.push_back((cell, level));
            }
        }
        while let Some((cell, level)) = queue.pop_front() {
            for d in 0..6 {
                let Some(next) = self.neighbour(cell, d) else {
                    continue;
                };
                let current = self.get(kind, next);
                if current == 0 {
                    continue;
                }
                if current < level {
                    self.set(kind, next, 0);
                    cleared.push(next);
                    queue.push_back((next, current));
                } else {
                    increase.push(kind, current, next);
                }
            }
        }
        cleared
    }

    fn increase(&mut self, blocks: &impl LightBlocks, facts: &LightFacts, mut increase: Increase) {
        for kind in [Kind::Sky, Kind::Block] {
            for level in (2..=15u8).rev() {
                let mut queue = std::mem::take(increase.bucket(kind, level));
                while let Some(cell) = queue.pop() {
                    if self.get(kind, cell) != level {
                        continue;
                    }
                    let from = blocks.state(cell.0, cell.1, cell.2);
                    for d in 0..6 {
                        let Some(next) = self.neighbour(cell, d) else {
                            continue;
                        };
                        let to = blocks.state(next.0, next.1, next.2);
                        let opacity = facts.opacity(to);
                        if opacity >= level
                            || self.get(kind, next) >= level - opacity
                            || facts.occludes(from, to, d)
                        {
                            continue;
                        }
                        let lit = level - opacity;
                        self.set(kind, next, lit);
                        if lit > 1 {
                            if lit == level {
                                queue.push(next);
                            } else {
                                increase.push(kind, lit, next);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Queued cells per light kind and level.
struct Increase {
    buckets: [Vec<Vec<Cell>>; 2],
}

impl Increase {
    fn new() -> Self {
        Increase {
            buckets: [vec![Vec::new(); 16], vec![Vec::new(); 16]],
        }
    }

    fn push(&mut self, kind: Kind, level: u8, cell: Cell) {
        if level > 1 {
            self.buckets[kind as usize][level as usize].push(cell);
        }
    }

    fn bucket(&mut self, kind: Kind, level: u8) -> &mut Vec<Cell> {
        &mut self.buckets[kind as usize][level as usize]
    }
}

/// The lowest sky source of a column (`ChunkSkyLightSources`); `HEIGHT` when none.
pub fn lowest_source(blocks: &impl LightBlocks, facts: &LightFacts, x: usize, z: usize) -> usize {
    if !blocks.has_sky() {
        return HEIGHT;
    }
    let mut above = 0u16;
    for y in (0..HEIGHT).rev() {
        let state = blocks.state(x, y, z);
        if facts.sky_blocked(above, state) {
            return y + 1;
        }
        above = state;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::light::{block_light, sky_light, Area};

    struct Dense {
        wx: usize,
        wz: usize,
        states: Vec<u16>,
    }

    impl LightBlocks for Dense {
        fn wx(&self) -> usize {
            self.wx
        }
        fn wz(&self) -> usize {
            self.wz
        }
        fn state(&self, x: usize, y: usize, z: usize) -> u16 {
            self.states[(x * self.wz + z) * HEIGHT + y]
        }
    }

    /// 0 air, 1 stone (opaque, full faces), 2 torch (emission 14), 3 glass-like
    /// (dampening 0, full faces), 4 leaves-like (dampening 1, open faces),
    /// 5 slab-like (dampening 0, full bottom face only), 6 lamp (emission 15).
    fn facts() -> LightFacts {
        let properties = vec![0x00, 0x0F, 0xE0, 0x00, 0x01, 0x00, 0xF0];
        // Face classes: 0 open, 1 full.
        let full = [0u8, 1, 0, 1, 0, 0, 1];
        let faces: [Vec<u8>; 6] = std::array::from_fn(|d| {
            (0..7)
                .map(|s| if s == 5 { (d == 0) as u8 } else { full[s] })
                .collect()
        });
        let occludes: [Vec<u8>; 6] = std::array::from_fn(|_| vec![0b1110]);
        // Sky edges blocked by anything with dampening or a full face.
        let sky_states = vec![0u8, 1, 0, 1, 1, 1, 1];
        LightFacts::new(
            properties,
            faces,
            [2; 6],
            occludes,
            sky_states,
            2,
            vec![0b1110],
        )
        .unwrap()
    }

    fn rng(seed: &mut u64) -> u64 {
        *seed ^= *seed << 13;
        *seed ^= *seed >> 7;
        *seed ^= *seed << 17;
        *seed
    }

    fn full_light(blocks: &Dense, f: &LightFacts) -> (Vec<u8>, Vec<u8>) {
        let area = Area {
            wx: blocks.wx,
            wz: blocks.wz,
            states: &blocks.states,
        };
        (sky_light(&area, f), block_light(&area, f))
    }

    fn assert_matches(grid: &LightGrid, blocks: &Dense, f: &LightFacts, context: &str) {
        let (sky, block) = full_light(blocks, f);
        for x in 0..blocks.wx {
            for z in 0..blocks.wz {
                for y in 0..HEIGHT {
                    let i = (x * blocks.wz + z) * HEIGHT + y;
                    assert_eq!(
                        grid.get(Kind::Sky, (x, y, z)),
                        sky[i],
                        "sky at {x},{y},{z} {context}"
                    );
                    assert_eq!(
                        grid.get(Kind::Block, (x, y, z)),
                        block[i],
                        "block at {x},{y},{z} {context}"
                    );
                }
            }
        }
    }

    /// The Nether's blocks: no sky light anywhere (VMC-026b).
    struct Skyless(Dense);

    impl LightBlocks for Skyless {
        fn wx(&self) -> usize {
            self.0.wx
        }
        fn wz(&self) -> usize {
            self.0.wz
        }
        fn state(&self, x: usize, y: usize, z: usize) -> u16 {
            self.0.state(x, y, z)
        }
        fn has_sky(&self) -> bool {
            false
        }
    }

    #[test]
    fn a_dimension_without_sky_has_only_block_light() {
        let f = facts();
        let (wx, wz) = (16, 16);
        let mut states = vec![0u16; wx * wz * HEIGHT];
        // A torch in an open column and a stone floor.
        for x in 0..wx {
            for z in 0..wz {
                states[(x * wz + z) * HEIGHT + 60] = 1;
            }
        }
        states[(8 * wz + 8) * HEIGHT + 61] = 2;
        let mut blocks = Skyless(Dense { wx, wz, states });
        let mut grid = LightGrid::compute(&blocks, &f);
        let sky_lit = |grid: &LightGrid| {
            (0..wx)
                .any(|x| (0..wz).any(|z| (0..HEIGHT).any(|y| grid.get(Kind::Sky, (x, y, z)) > 0)))
        };
        assert!(!sky_lit(&grid));
        assert_eq!(grid.get(Kind::Block, (8, 61, 8)), 14);
        assert_eq!(grid.get(Kind::Block, (8, 62, 10)), 11);
        // Opening the floor brings no sky light either.
        blocks.0.states[(3 * wz + 3) * HEIGHT + 60] = 0;
        grid.update(&blocks, &f, &[(3, 60, 3)]);
        assert!(!sky_lit(&grid));
    }

    #[test]
    fn incremental_updates_equal_full_relights() {
        let f = facts();
        let mut seed = 0x9E37_79B9_7F4A_7C15u64;
        // Terrain: stone up to y 100 with caves, a few torches and lamps.
        let (wx, wz) = (32, 32);
        let mut states = vec![0u16; wx * wz * HEIGHT];
        for x in 0..wx {
            for z in 0..wz {
                for y in 0..HEIGHT {
                    let r = rng(&mut seed) % 100;
                    states[(x * wz + z) * HEIGHT + y] = if y < 100 {
                        if r < 70 {
                            1
                        } else if r < 72 {
                            2
                        } else if r < 75 {
                            4
                        } else {
                            0
                        }
                    } else if y < 104 && r < 10 {
                        [3, 4, 5, 6][(r % 4) as usize]
                    } else {
                        0
                    };
                }
            }
        }
        let mut blocks = Dense { wx, wz, states };
        let mut grid = LightGrid::compute(&blocks, &f);
        assert_matches(&grid, &blocks, &f, "after compute");
        for round in 0..60 {
            let edits = 1 + (rng(&mut seed) % 4) as usize;
            let mut changed = Vec::new();
            for _ in 0..edits {
                let x = (rng(&mut seed) % wx as u64) as usize;
                let z = (rng(&mut seed) % wz as u64) as usize;
                let y = 80 + (rng(&mut seed) % 40) as usize;
                let state = (rng(&mut seed) % 7) as u16;
                blocks.states[(x * wz + z) * HEIGHT + y] = state;
                changed.push((x, y, z));
            }
            grid.update(&blocks, &f, &changed);
            if round % 10 == 9 {
                grid.compact();
            }
            assert_matches(
                &grid,
                &blocks,
                &f,
                &format!("after round {round}: {changed:?}"),
            );
        }
    }

    #[test]
    fn opening_and_roofing_a_shaft_moves_sky_sources() {
        let f = facts();
        let (wx, wz) = (16, 16);
        let mut states = vec![0u16; wx * wz * HEIGHT];
        for x in 0..wx {
            for z in 0..wz {
                for y in 0..100 {
                    states[(x * wz + z) * HEIGHT + y] =
                        if (x, z) == (8, 8) && y >= 20 { 0 } else { 1 };
                }
            }
        }
        let mut blocks = Dense { wx, wz, states };
        let mut grid = LightGrid::compute(&blocks, &f);
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 15);
        blocks.states[(8 * wz + 8) * HEIGHT + 99] = 1;
        grid.update(&blocks, &f, &[(8, 99, 8)]);
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 0);
        assert_matches(&grid, &blocks, &f, "roofed");
        blocks.states[(8 * wz + 8) * HEIGHT + 99] = 0;
        grid.update(&blocks, &f, &[(8, 99, 8)]);
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 15);
        assert_matches(&grid, &blocks, &f, "reopened");
    }
}
