//! Chunk columns (24 sections, y −64..319) owned by one region.

use crate::flags::{BlockFlags, MOTION_BLOCKING, WORLD_SURFACE};
use crate::light::LightFacts;
use crate::light_grid::{Kind, Layer, LightBlocks, LightGrid};
use crate::section::{index, Biomes, Storage, VOLUME};
use crate::wire;
use std::collections::HashMap;

pub const MIN_Y: i32 = -64;
pub const HEIGHT: usize = 384;
pub const SECTIONS: usize = HEIGHT / 16;

/// Encoded chunk parts: section data, WORLD_SURFACE longs, MOTION_BLOCKING longs.
pub type EncodedChunk = (Vec<u8>, Vec<u8>, Vec<u8>);

#[derive(Clone, Debug)]
pub struct Column {
    pub sections: Vec<Storage>,
    /// Per-section biomes; `None` uses the region's default biome everywhere.
    pub biomes: Option<Vec<Biomes>>,
}

impl Column {
    /// A column whose every y level holds `layers[y - MIN_Y]`.
    pub fn from_layers(layers: &[u16; HEIGHT]) -> Self {
        let sections = (0..SECTIONS)
            .map(|s| {
                let base = &layers[s * 16..s * 16 + 16];
                if base.iter().all(|b| *b == base[0]) {
                    Storage::Single(base[0])
                } else {
                    let mut storage = Storage::Single(base[0]);
                    for (y, state) in base.iter().enumerate() {
                        if *state != base[0] {
                            for i in 0..256 {
                                storage.set((y << 8) | i, *state);
                            }
                        }
                    }
                    storage
                }
            })
            .collect();
        Self {
            sections,
            biomes: None,
        }
    }

    #[inline]
    fn locate(x: i32, y: i32, z: i32) -> (usize, usize) {
        let section = ((y - MIN_Y) >> 4) as usize;
        let i = index(
            (x & 15) as usize,
            ((y - MIN_Y) & 15) as usize,
            (z & 15) as usize,
        );
        (section, i)
    }

    pub fn get(&self, x: i32, y: i32, z: i32) -> u16 {
        let (s, i) = Self::locate(x, y, z);
        self.sections[s].get(i)
    }

    pub fn set(&mut self, x: i32, y: i32, z: i32, state: u16) -> u16 {
        let (s, i) = Self::locate(x, y, z);
        self.sections[s].set(i, state)
    }

    /// Heights (1 + highest matching y, relative to MIN_Y; 0 when none) per column
    /// in `z * 16 + x` order for one heightmap predicate bit.
    pub fn heights(&self, flags: &BlockFlags, mask: u8) -> [u16; 256] {
        let mut out = [0u16; 256];
        for (column, height) in out.iter_mut().enumerate() {
            let (x, z) = (column & 15, column >> 4);
            'scan: for s in (0..SECTIONS).rev() {
                let section = &self.sections[s];
                if let Storage::Single(state) = section {
                    if flags.get(*state) & mask != 0 {
                        *height = (s * 16 + 16) as u16;
                        break 'scan;
                    }
                    continue;
                }
                for y in (0..16).rev() {
                    if flags.get(section.get(index(x, y, z))) & mask != 0 {
                        *height = (s * 16 + y + 1) as u16;
                        break 'scan;
                    }
                }
            }
        }
        out
    }

    /// A compact, versioned image of the column for the region log (VMC-021c):
    /// per section a single state or a first-appearance palette with indices packed
    /// at `max(1, ⌈log2 n⌉)` bits, then the same for biomes if the column has them.
    pub fn to_image(&self) -> Vec<u8> {
        let mut out = vec![IMAGE_VERSION, self.biomes.is_some() as u8];
        for storage in &self.sections {
            match storage {
                Storage::Single(state) => {
                    out.push(0);
                    out.extend(state.to_be_bytes());
                }
                // An indexed section already has a palette and indices: pack them as
                // they are (unused palette entries cost two bytes each).
                Storage::Indexed { palette, cells } => {
                    out.push(1);
                    out.extend((palette.len() as u16).to_be_bytes());
                    for state in palette {
                        out.extend(state.to_be_bytes());
                    }
                    wire::pack_longs(
                        &mut out,
                        cells.iter().map(|c| *c as u64),
                        palette_bits(palette.len()),
                    );
                }
                Storage::Dense(cells) => image_palette(&mut out, &cells[..]),
            }
        }
        for biomes in self.biomes.iter().flatten() {
            match biomes {
                Biomes::Single(biome) => {
                    out.push(0);
                    out.extend(biome.to_be_bytes());
                }
                Biomes::Cells(cells) => image_palette(&mut out, &cells[..]),
            }
        }
        out
    }

    /// Read `to_image` output; `None` for any other bytes.
    pub fn from_image(bytes: &[u8]) -> Option<Column> {
        let mut input = bytes;
        let [version, has_biomes] = take::<2>(&mut input)?;
        if version != IMAGE_VERSION || has_biomes > 1 {
            return None;
        }
        let mut sections = Vec::with_capacity(SECTIONS);
        for _ in 0..SECTIONS {
            let (palette, data, bits) = read_palette(&mut input, VOLUME)?;
            sections.push(Storage::from_palette(&palette, data, bits)?);
        }
        let biomes = if has_biomes == 1 {
            let mut all = Vec::with_capacity(SECTIONS);
            for _ in 0..SECTIONS {
                let (palette, data, bits) = read_palette(&mut input, 64)?;
                all.push(Biomes::from_palette(&palette, data, bits)?);
            }
            Some(all)
        } else {
            None
        };
        input.is_empty().then_some(Column { sections, biomes })
    }

    pub fn heap_bytes(&self) -> usize {
        let biomes = self.biomes.as_ref().map_or(0, |b| {
            b.iter()
                .map(|s| if let Biomes::Cells(_) = s { 128 } else { 0 })
                .sum()
        });
        self.sections.iter().map(Storage::heap_bytes).sum::<usize>() + biomes
    }
}

const IMAGE_VERSION: u8 = 1;

fn image_palette(out: &mut Vec<u8>, cells: &[u16]) {
    let mut palette: Vec<u16> = Vec::new();
    let mut slot_of: HashMap<u16, u64> = HashMap::new();
    let slots: Vec<u64> = cells
        .iter()
        .map(|state| {
            *slot_of.entry(*state).or_insert_with(|| {
                palette.push(*state);
                (palette.len() - 1) as u64
            })
        })
        .collect();
    out.push(1);
    out.extend((palette.len() as u16).to_be_bytes());
    for state in &palette {
        out.extend(state.to_be_bytes());
    }
    wire::pack_longs(out, slots.into_iter(), palette_bits(palette.len()));
}

/// Image index width for a palette of `n` entries: `max(1, ⌈log2 n⌉)`.
fn palette_bits(n: usize) -> u32 {
    (usize::BITS - n.saturating_sub(1).leading_zeros()).max(1)
}

fn take<const N: usize>(input: &mut &[u8]) -> Option<[u8; N]> {
    let (head, rest) = input.split_at_checked(N)?;
    *input = rest;
    head.try_into().ok()
}

/// One image palette: (palette, packed data, bits); `count` entries.
fn read_palette<'a>(input: &mut &'a [u8], count: usize) -> Option<(Vec<u16>, &'a [u8], u32)> {
    let [tag] = take::<1>(input)?;
    match tag {
        0 => Some((vec![u16::from_be_bytes(take::<2>(input)?)], &[][..], 0)),
        1 => {
            let n = u16::from_be_bytes(take::<2>(input)?) as usize;
            let mut palette = Vec::with_capacity(n);
            for _ in 0..n {
                palette.push(u16::from_be_bytes(take::<2>(input)?));
            }
            let bits = palette_bits(n);
            let len = count.div_ceil((64 / bits) as usize) * 8;
            let (data, rest) = input.split_at_checked(len)?;
            *input = rest;
            Some((palette, data, bits))
        }
        _ => None,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum StoreError {
    OutOfRegion,
    InvalidY,
    InvalidState,
    MemoryBudget,
}

/// The block storage of one region: lazily materialized columns over a base layer
/// profile. Columns that were never touched read from the base profile.
pub struct ColumnStore {
    pub chunk_min: (i32, i32),
    pub chunk_size: i32,
    pub layers: Box<[u16; HEIGHT]>,
    pub columns: HashMap<(i32, i32), Column>,
    pub budget_bytes: usize,
    /// States that react to random ticks in this region (indexed by state id).
    pub ticking: Vec<bool>,
    /// xorshift64 state for random tick positions.
    pub rng: u64,
    /// Light over the region plus a one-chunk ring (VMC-022c), once computed.
    pub light: Option<LightGrid>,
    /// Neighbour chunks of the ring; absent ones read the base profile.
    pub halo: HashMap<(i32, i32), Column>,
}

/// Dense block states for a full light computation.
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
    #[inline]
    fn state(&self, x: usize, y: usize, z: usize) -> u16 {
        self.states[(x * self.wz + z) * HEIGHT + y]
    }
}

/// The region and its one-chunk ring as light sees them: area coordinates start
/// at the ring's corner chunk.
struct LightView<'a> {
    store: &'a ColumnStore,
}

impl LightBlocks for LightView<'_> {
    fn wx(&self) -> usize {
        (self.store.chunk_size as usize + 2) * 16
    }
    fn wz(&self) -> usize {
        (self.store.chunk_size as usize + 2) * 16
    }
    #[inline]
    fn state(&self, x: usize, y: usize, z: usize) -> u16 {
        let (mx, mz) = self.store.chunk_min;
        let chunk = (mx - 1 + (x / 16) as i32, mz - 1 + (z / 16) as i32);
        let inside = self.store.check_chunk(chunk).is_ok();
        let column = if inside {
            self.store.columns.get(&chunk)
        } else {
            self.store.halo.get(&chunk)
        };
        match column {
            Some(column) => column.sections[y / 16].get(index(x & 15, y & 15, z & 15)),
            None => self.store.layers[y],
        }
    }
}

impl ColumnStore {
    pub fn new(
        chunk_min: (i32, i32),
        chunk_size: i32,
        layers: Box<[u16; HEIGHT]>,
        budget_bytes: usize,
    ) -> Self {
        // Any non-zero seed; distinct per region.
        let rng = (chunk_min.0 as u64) << 32 ^ (chunk_min.1 as u32 as u64) ^ 0x9E37_79B9_7F4A_7C15;
        Self {
            chunk_min,
            chunk_size,
            layers,
            columns: HashMap::new(),
            budget_bytes,
            ticking: Vec::new(),
            rng: rng.max(1),
            light: None,
            halo: HashMap::new(),
        }
    }

    /// Light the region (and its ring) from scratch, over a dense copy of their
    /// blocks (filled section by section; dropped afterwards).
    pub fn light_compute(&mut self, facts: &LightFacts) {
        let view = LightView { store: self };
        let (wx, wz) = (view.wx(), view.wz());
        let mut states = vec![0u16; wx * wz * HEIGHT];
        let (mx, mz) = self.chunk_min;
        for cx in 0..wx / 16 {
            for cz in 0..wz / 16 {
                let chunk = (mx - 1 + cx as i32, mz - 1 + cz as i32);
                let column = if self.check_chunk(chunk).is_ok() {
                    self.columns.get(&chunk)
                } else {
                    self.halo.get(&chunk)
                };
                for x in 0..16 {
                    for z in 0..16 {
                        let base = ((cx * 16 + x) * wz + cz * 16 + z) * HEIGHT;
                        match column {
                            None => states[base..base + HEIGHT].copy_from_slice(&self.layers[..]),
                            Some(column) => {
                                for (s, storage) in column.sections.iter().enumerate() {
                                    for y in 0..16 {
                                        states[base + s * 16 + y] = storage.get(index(x, y, z));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let grid = LightGrid::compute(&Dense { wx, wz, states }, facts);
        self.light = Some(grid);
    }

    /// Relight after blocks at `positions` changed (in the region or its ring);
    /// returns the region's chunks whose light changed.
    pub fn light_update(
        &mut self,
        facts: &LightFacts,
        positions: &[(i32, i32, i32)],
    ) -> Vec<(i32, i32)> {
        let Some(mut grid) = self.light.take() else {
            return Vec::new();
        };
        let (mx, mz) = self.chunk_min;
        let (ox, oz) = ((mx - 1) * 16, (mz - 1) * 16);
        let span = (self.chunk_size + 2) * 16;
        let cells: Vec<(usize, usize, usize)> = positions
            .iter()
            .filter(|(x, y, z)| {
                (ox..ox + span).contains(x)
                    && (oz..oz + span).contains(z)
                    && (MIN_Y..MIN_Y + HEIGHT as i32).contains(y)
            })
            .map(|(x, y, z)| ((x - ox) as usize, (y - MIN_Y) as usize, (z - oz) as usize))
            .collect();
        grid.update(&LightView { store: self }, facts, &cells);
        let changed = grid
            .take_dirty()
            .into_iter()
            .map(|(cx, cz)| (mx - 1 + cx as i32, mz - 1 + cz as i32))
            .filter(|chunk| self.check_chunk(*chunk).is_ok())
            .collect();
        self.light = Some(grid);
        changed
    }

    /// Whether `chunk` is in the one-chunk ring around the region.
    pub fn in_ring(&self, chunk: (i32, i32)) -> bool {
        let (mx, mz) = self.chunk_min;
        let n = self.chunk_size;
        self.check_chunk(chunk).is_err()
            && (mx - 1..=mx + n).contains(&chunk.0)
            && (mz - 1..=mz + n).contains(&chunk.1)
    }

    /// Replace ring chunks (a neighbour's columns, or `None` for the base
    /// profile) and relight once; returns the region's chunks whose light changed.
    pub fn halo_put(
        &mut self,
        facts: &LightFacts,
        chunks: Vec<((i32, i32), Option<Column>)>,
    ) -> Result<Vec<(i32, i32)>, StoreError> {
        if chunks.iter().any(|(chunk, _)| !self.in_ring(*chunk)) {
            return Err(StoreError::OutOfRegion);
        }
        let mut changed = Vec::new();
        for (chunk, column) in chunks {
            for s in 0..SECTIONS {
                for i in 0..VOLUME {
                    let base = self.layers[s * 16 + (i >> 8)];
                    let old = self.halo.get(&chunk).map_or(base, |c| c.sections[s].get(i));
                    let new = column.as_ref().map_or(base, |c| c.sections[s].get(i));
                    if old != new {
                        let (x, y, z) = (i & 15, i >> 8, (i >> 4) & 15);
                        changed.push((
                            chunk.0 * 16 + x as i32,
                            MIN_Y + (s * 16 + y) as i32,
                            chunk.1 * 16 + z as i32,
                        ));
                    }
                }
            }
            match column {
                Some(column) => self.halo.insert(chunk, column),
                None => self.halo.remove(&chunk),
            };
        }
        Ok(self.relight_cells(facts, &changed))
    }

    /// Apply a neighbour's block changes in the ring and relight.
    pub fn halo_edits(
        &mut self,
        facts: &LightFacts,
        edits: &[(i32, i32, i32, u16)],
    ) -> Vec<(i32, i32)> {
        let mut positions = Vec::with_capacity(edits.len());
        for &(x, y, z, state) in edits {
            let chunk = (x >> 4, z >> 4);
            if !(self.in_ring(chunk) && (MIN_Y..MIN_Y + HEIGHT as i32).contains(&y)) {
                continue;
            }
            let layers = &self.layers;
            let column = self
                .halo
                .entry(chunk)
                .or_insert_with(|| Column::from_layers(layers));
            column.set(x, y, z, state);
            positions.push((x, y, z));
        }
        self.light_update(facts, &positions)
    }

    /// Relight many cells: incrementally, or from scratch when most of a chunk changed.
    fn relight_cells(&mut self, facts: &LightFacts, cells: &[(i32, i32, i32)]) -> Vec<(i32, i32)> {
        if cells.len() <= 16_384 {
            return self.light_update(facts, cells);
        }
        self.light_compute(facts);
        let (mx, mz) = self.chunk_min;
        (0..self.chunk_size)
            .flat_map(|x| (0..self.chunk_size).map(move |z| (mx + x, mz + z)))
            .collect()
    }

    /// A chunk's light image (VMC-021e5 layout): 26 sections from one below the
    /// world to one above, each sky then block as tag 1 + repeated byte (uniform)
    /// or tag 2 + 2,048 bytes.
    pub fn light_image(&self, chunk: (i32, i32)) -> Result<Option<Vec<u8>>, StoreError> {
        self.check_chunk(chunk)?;
        let Some(grid) = &self.light else {
            return Ok(None);
        };
        let (cx, cz) = (
            (chunk.0 - self.chunk_min.0 + 1) as usize,
            (chunk.1 - self.chunk_min.1 + 1) as usize,
        );
        let mut out = Vec::with_capacity(26 * 4);
        let uniform = |out: &mut Vec<u8>, level: u8| out.extend([1, level | level << 4]);
        // Below the world: dark.
        uniform(&mut out, 0);
        uniform(&mut out, 0);
        let (sky, block) = (
            grid.chunk(Kind::Sky, cx, cz),
            grid.chunk(Kind::Block, cx, cz),
        );
        for s in 0..SECTIONS {
            for layer in [&sky[s], &block[s]] {
                match layer {
                    Layer::Uniform(level) => uniform(&mut out, *level),
                    Layer::Nibbles(bytes) => {
                        out.push(2);
                        out.extend_from_slice(&bytes[..]);
                    }
                }
            }
        }
        // Above the world: open sky.
        uniform(&mut out, 15);
        uniform(&mut out, 0);
        Ok(Some(out))
    }

    fn chunk_of(&self, x: i32, z: i32) -> Result<(i32, i32), StoreError> {
        let chunk = (x >> 4, z >> 4);
        let (mx, mz) = self.chunk_min;
        if chunk.0 < mx
            || chunk.0 >= mx + self.chunk_size
            || chunk.1 < mz
            || chunk.1 >= mz + self.chunk_size
        {
            return Err(StoreError::OutOfRegion);
        }
        Ok(chunk)
    }

    fn check_y(y: i32) -> Result<(), StoreError> {
        if (MIN_Y..MIN_Y + HEIGHT as i32).contains(&y) {
            Ok(())
        } else {
            Err(StoreError::InvalidY)
        }
    }

    pub fn get(&self, x: i32, y: i32, z: i32) -> Result<u16, StoreError> {
        let chunk = self.chunk_of(x, z)?;
        Self::check_y(y)?;
        Ok(match self.columns.get(&chunk) {
            Some(column) => column.get(x, y, z),
            None => self.layers[(y - MIN_Y) as usize],
        })
    }

    /// Validate every change first, then apply all of them; returns previous states.
    pub fn set_many(
        &mut self,
        changes: &[(i32, i32, i32, u32)],
        flags: &BlockFlags,
    ) -> Result<Vec<u16>, StoreError> {
        for (x, y, z, state) in changes {
            self.chunk_of(*x, *z)?;
            Self::check_y(*y)?;
            if !flags.valid(*state) {
                return Err(StoreError::InvalidState);
            }
        }
        let worst_case = changes.len().min(64) * SECTIONS * VOLUME * 2;
        if self.heap_bytes() + worst_case > self.budget_bytes {
            return Err(StoreError::MemoryBudget);
        }
        let mut previous = Vec::with_capacity(changes.len());
        for (x, y, z, state) in changes {
            let chunk = (x >> 4, z >> 4);
            let layers = &self.layers;
            let column = self
                .columns
                .entry(chunk)
                .or_insert_with(|| Column::from_layers(layers));
            previous.push(column.set(*x, *y, *z, *state as u16));
        }
        Ok(previous)
    }

    /// Network data for one chunk: concatenated sections plus the two heightmaps
    /// (WORLD_SURFACE, MOTION_BLOCKING) packed at 9 bits.
    pub fn encode_chunk(
        &self,
        chunk: (i32, i32),
        flags: &BlockFlags,
        biome: u32,
        global_bits: u32,
        biome_bits: u32,
    ) -> Result<EncodedChunk, StoreError> {
        self.chunk_of(chunk.0 * 16, chunk.1 * 16)?;
        let owned;
        let column = match self.columns.get(&chunk) {
            Some(column) => column,
            None => {
                owned = Column::from_layers(&self.layers);
                &owned
            }
        };
        let mut sections = Vec::with_capacity(SECTIONS * 16);
        for (s, storage) in column.sections.iter().enumerate() {
            let biomes = match &column.biomes {
                Some(stored) => wire::SectionBiomes::Stored(&stored[s]),
                None => wire::SectionBiomes::Uniform(biome),
            };
            wire::encode_section(
                &mut sections,
                storage,
                flags,
                biomes,
                global_bits,
                biome_bits,
            );
        }
        let mut surface = Vec::with_capacity(37 * 8);
        wire::pack_longs(
            &mut surface,
            column
                .heights(flags, WORLD_SURFACE)
                .iter()
                .map(|h| *h as u64),
            9,
        );
        let mut motion = Vec::with_capacity(37 * 8);
        wire::pack_longs(
            &mut motion,
            column
                .heights(flags, MOTION_BLOCKING)
                .iter()
                .map(|h| *h as u64),
            9,
        );
        Ok((sections, surface, motion))
    }

    /// Blocks in one chunk whose state is in `states` (e.g. block-entity carriers).
    /// Untouched chunks are searched in the base profile.
    pub fn find(
        &self,
        chunk: (i32, i32),
        states: &[u16],
    ) -> Result<Vec<(i32, i32, i32, u16)>, StoreError> {
        self.chunk_of(chunk.0 * 16, chunk.1 * 16)?;
        let mut out = Vec::new();
        let owned;
        let column = match self.columns.get(&chunk) {
            Some(column) => column,
            None => {
                owned = Column::from_layers(&self.layers);
                &owned
            }
        };
        for (s, storage) in column.sections.iter().enumerate() {
            let candidate = match storage {
                Storage::Single(state) => states.contains(state),
                Storage::Indexed { palette, .. } => palette.iter().any(|p| states.contains(p)),
                Storage::Dense(_) => true,
            };
            if candidate {
                storage.for_each(|i, state| {
                    if states.contains(&state) {
                        let (x, z, y) = (i & 15, (i >> 4) & 15, i >> 8);
                        out.push((
                            chunk.0 * 16 + x as i32,
                            (s * 16 + y) as i32 + MIN_Y,
                            chunk.1 * 16 + z as i32,
                            state,
                        ));
                    }
                });
            }
        }
        Ok(out)
    }

    pub fn check_chunk(&self, chunk: (i32, i32)) -> Result<(), StoreError> {
        self.chunk_of(chunk.0 * 16, chunk.1 * 16).map(|_| ())
    }

    pub fn touched(&self, chunk: (i32, i32)) -> bool {
        self.columns.contains_key(&chunk)
    }

    /// Every block that differs from the base profile, for sparse persistence.
    pub fn diff(&self) -> Vec<(i32, i32, i32, u16)> {
        let mut out = Vec::new();
        for chunk in self.columns.keys() {
            self.diff_into(*chunk, &mut out);
        }
        out
    }

    /// Blocks of one chunk that differ from the base profile.
    pub fn chunk_diff(&self, chunk: (i32, i32)) -> Vec<(i32, i32, i32, u16)> {
        let mut out = Vec::new();
        self.diff_into(chunk, &mut out);
        out
    }

    fn diff_into(&self, (cx, cz): (i32, i32), out: &mut Vec<(i32, i32, i32, u16)>) {
        if let Some(column) = self.columns.get(&(cx, cz)) {
            for (s, storage) in column.sections.iter().enumerate() {
                if let Storage::Single(state) = storage {
                    if self.layers[s * 16..s * 16 + 16].iter().all(|b| b == state) {
                        continue;
                    }
                }
                storage.for_each(|i, state| {
                    let (x, z, y) = (i & 15, (i >> 4) & 15, i >> 8);
                    let wy = s * 16 + y;
                    if self.layers[wy] != state {
                        out.push((
                            cx * 16 + x as i32,
                            wy as i32 + MIN_Y,
                            cz * 16 + z as i32,
                            state,
                        ));
                    }
                });
            }
        }
    }

    /// Drop columns that equal the base profile and collapse uniform sections.
    fn next_random(&mut self) -> u64 {
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng = x;
        x
    }

    /// Vanilla random ticks: `per_section` uniform positions in every section of
    /// the region, returning those whose state is in `ticking`. Sections whose
    /// palette holds no ticking state are skipped without drawing.
    pub fn random_ticks(&mut self, per_section: u32) -> Vec<(i32, i32, i32, u16)> {
        let ticking = std::mem::take(&mut self.ticking);
        let ticks = |s: u16| ticking.get(s as usize).copied().unwrap_or(false);
        let mut hits = Vec::new();
        if ticking.iter().any(|&t| t) {
            let base: Vec<bool> = (0..SECTIONS)
                .map(|s| self.layers[s * 16..s * 16 + 16].iter().any(|&b| ticks(b)))
                .collect();
            let (mx, mz) = self.chunk_min;
            for dx in 0..self.chunk_size {
                for dz in 0..self.chunk_size {
                    let chunk = (mx + dx, mz + dz);
                    for (s, &base_ticks) in base.iter().enumerate() {
                        let possible = match self.columns.get(&chunk) {
                            Some(column) => match &column.sections[s] {
                                Storage::Single(state) => ticks(*state),
                                Storage::Indexed { palette, .. } => {
                                    palette.iter().any(|&b| ticks(b))
                                }
                                Storage::Dense(_) => true,
                            },
                            None => base_ticks,
                        };
                        if !possible {
                            continue;
                        }
                        for _ in 0..per_section {
                            let n = (self.next_random() % VOLUME as u64) as usize;
                            let (x, z, y) =
                                ((n & 15) as i32, ((n >> 4) & 15) as i32, (n >> 8) as i32);
                            let state = match self.columns.get(&chunk) {
                                Some(column) => column.sections[s].get(n),
                                None => self.layers[s * 16 + y as usize],
                            };
                            if ticks(state) {
                                hits.push((
                                    chunk.0 * 16 + x,
                                    MIN_Y + s as i32 * 16 + y,
                                    chunk.1 * 16 + z,
                                    state,
                                ));
                            }
                        }
                    }
                }
            }
        }
        self.ticking = ticking;
        hits
    }

    pub fn compact(&mut self) {
        let layers = &self.layers;
        self.columns.retain(|_, column| {
            column.sections.iter_mut().for_each(Storage::normalize);
            column.biomes.is_some()
                || !column.sections.iter().enumerate().all(|(s, storage)| {
                    let mut same = true;
                    storage.for_each(|i, state| same &= layers[s * 16 + (i >> 8)] == state);
                    same
                })
        });
    }

    pub fn heap_bytes(&self) -> usize {
        self.columns.values().map(Column::heap_bytes).sum()
    }

    /// Replace one chunk's column (an imported chunk). States must be valid.
    pub fn put_column(
        &mut self,
        chunk: (i32, i32),
        column: Column,
        flags: &BlockFlags,
    ) -> Result<(), StoreError> {
        self.check_chunk(chunk)?;
        if column.sections.len() != SECTIONS
            || column.biomes.as_ref().is_some_and(|b| b.len() != SECTIONS)
        {
            return Err(StoreError::InvalidY);
        }
        let mut valid = true;
        for storage in &column.sections {
            storage.for_each(|_, state| valid &= flags.valid(state as u32));
        }
        if !valid {
            return Err(StoreError::InvalidState);
        }
        let previous = self.columns.get(&chunk).map_or(0, Column::heap_bytes);
        if self.heap_bytes() - previous + column.heap_bytes() > self.budget_bytes {
            return Err(StoreError::MemoryBudget);
        }
        self.columns.insert(chunk, column);
        Ok(())
    }

    /// The region-log image of a chunk's column, or `None` while it is the base profile.
    pub fn column_image(&self, chunk: (i32, i32)) -> Result<Option<Vec<u8>>, StoreError> {
        self.check_chunk(chunk)?;
        Ok(self.columns.get(&chunk).map(Column::to_image))
    }

    /// One chunk's states (24 × 4096, section index order) and biomes (24 × 64);
    /// biomes are `default_biome` where the column has none.
    pub fn dump_column(
        &self,
        chunk: (i32, i32),
        default_biome: u16,
    ) -> Result<(Vec<u16>, Vec<u16>), StoreError> {
        self.check_chunk(chunk)?;
        let owned;
        let column = match self.columns.get(&chunk) {
            Some(column) => column,
            None => {
                owned = Column::from_layers(&self.layers);
                &owned
            }
        };
        let mut states = Vec::with_capacity(SECTIONS * VOLUME);
        for storage in &column.sections {
            storage.for_each(|_, state| states.push(state));
        }
        let biomes = (0..SECTIONS)
            .flat_map(|s| {
                (0..64).map(move |i| match &column.biomes {
                    Some(b) => b[s].get(i),
                    None => default_biome,
                })
            })
            .collect();
        Ok((states, biomes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flags::AIR;

    #[test]
    fn column_images_round_trip_and_refuse_other_bytes() {
        let mut column = Column::from_layers(&flat());
        for i in 0..300 {
            column.set(
                i % 16,
                -60 + (i / 16) % 300,
                (i / 7) % 16,
                (i % 200) as u16 + 4,
            );
        }
        let mut biomes = vec![Biomes::Single(3); SECTIONS];
        biomes[5] = Biomes::Cells(Box::new(std::array::from_fn(|i| (i % 3) as u16)));
        column.biomes = Some(biomes);
        let image = column.to_image();
        let back = Column::from_image(&image).unwrap();
        for s in 0..SECTIONS {
            for i in 0..VOLUME {
                assert_eq!(back.sections[s].get(i), column.sections[s].get(i));
            }
        }
        assert_eq!(back.biomes, column.biomes);
        assert!(Column::from_image(&image[..image.len() - 1]).is_none());
        let mut longer = image.clone();
        longer.push(0);
        assert!(Column::from_image(&longer).is_none());
        let plain = Column::from_layers(&flat());
        assert_eq!(Column::from_image(&plain.to_image()).unwrap().biomes, None);
    }

    fn flat() -> Box<[u16; HEIGHT]> {
        let mut layers = Box::new([0u16; HEIGHT]);
        layers[0] = 3;
        for y in 1..124 {
            layers[y] = 1;
        }
        for y in 124..127 {
            layers[y] = 2;
        }
        layers[127] = 4;
        layers
    }

    fn flags() -> BlockFlags {
        let mut bytes = vec![!AIR & !crate::flags::FLUID; 8];
        bytes[0] = AIR;
        BlockFlags::new(bytes).unwrap()
    }

    #[test]
    fn random_ticks_sample_only_sections_that_can_tick() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        assert!(store.random_ticks(3).is_empty());
        // State 4 (the surface layer, y = 63) ticks; it sits in section 7.
        store.ticking = vec![false, false, false, false, true];
        let flags = flags();
        store.set_many(&[(5, 63, 5, 2)], &flags).unwrap();
        let mut total = 0;
        for _ in 0..200 {
            let hits = store.random_ticks(3);
            total += hits.len();
            for (x, y, z, state) in hits {
                assert_eq!(state, 4);
                assert_eq!(y, 63);
                assert_eq!(store.get(x, y, z), Ok(4));
                assert!((0..128).contains(&x) && (0..128).contains(&z));
            }
        }
        // 64 chunks x 3 draws hit the surface layer with probability 1/16.
        let expected = 200 * 64 * 3 / 16;
        assert!(total > expected / 2 && total < expected * 2, "{total}");
    }

    #[test]
    fn untouched_columns_read_the_base_profile() {
        let store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        assert_eq!(store.get(5, -64, 5), Ok(3));
        assert_eq!(store.get(5, 63, 5), Ok(4));
        assert_eq!(store.get(5, 64, 5), Ok(0));
        assert_eq!(store.get(200, 0, 0), Err(StoreError::OutOfRegion));
        assert_eq!(store.get(0, 320, 0), Err(StoreError::InvalidY));
    }

    #[test]
    fn set_many_is_all_or_nothing_and_diff_round_trips() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let f = flags();
        assert_eq!(
            store.set_many(&[(1, 64, 1, 5), (1, 64, 300, 5)], &f),
            Err(StoreError::OutOfRegion)
        );
        assert_eq!(store.get(1, 64, 1), Ok(0));
        assert_eq!(
            store.set_many(&[(1, 64, 1, 5), (2, 63, 2, 0)], &f),
            Ok(vec![0, 4])
        );
        let mut diff = store.diff();
        diff.sort();
        assert_eq!(diff, vec![(1, 64, 1, 5), (2, 63, 2, 0)]);
        store.set_many(&[(1, 64, 1, 0), (2, 63, 2, 4)], &f).unwrap();
        store.compact();
        assert!(store.columns.is_empty());
        assert!(store.diff().is_empty());
    }

    #[test]
    fn heights_follow_the_highest_matching_block() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let f = flags();
        store.set_many(&[(3, 100, 0, 5)], &f).unwrap();
        let column = &store.columns[&(0, 0)];
        let heights = column.heights(&f, WORLD_SURFACE);
        assert_eq!(heights[3], (100 - MIN_Y + 1) as u16);
        assert_eq!(heights[4], 128);
    }
}
