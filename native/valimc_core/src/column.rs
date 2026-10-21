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

/// Column images by chunk (`fill_biomes`).
pub type ChunkImages = Vec<((i32, i32), Vec<u8>)>;

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
        Column::from_image_sections(bytes, SECTIONS)
    }

    /// Read an image of `count` sections (a proto chunk of another
    /// dimension's height, VMC-026b).
    pub fn from_image_sections(bytes: &[u8], count: usize) -> Option<Column> {
        let mut input = bytes;
        let [version, has_biomes] = take::<2>(&mut input)?;
        if version != IMAGE_VERSION || has_biomes > 1 || count == 0 || count > SECTIONS {
            return None;
        }
        let mut sections = Vec::with_capacity(count);
        for _ in 0..count {
            let (palette, data, bits) = read_palette(&mut input, VOLUME)?;
            sections.push(Storage::from_palette(&palette, data, bits)?);
        }
        let biomes = if has_biomes == 1 {
            let mut all = Vec::with_capacity(count);
            for _ in 0..count {
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

/// A column image built from raw cells (VMC-025d proto chunks), byte for
/// byte as `to_image` writes a column with these states: per section its
/// 4,096 states in index order, then optionally per section its 64 biomes.
pub fn image_of_cells<'a>(
    sections: impl Iterator<Item = &'a [u16]>,
    biomes: Option<&mut dyn Iterator<Item = &'a [u16]>>,
) -> Vec<u8> {
    let mut out = vec![IMAGE_VERSION, biomes.is_some() as u8];
    for cells in sections {
        image_cells(&mut out, cells);
    }
    if let Some(biomes) = biomes {
        for cells in biomes {
            image_cells(&mut out, cells);
        }
    }
    out
}

/// One section (or a section's biomes): a single value, or a palette.
fn image_cells(out: &mut Vec<u8>, cells: &[u16]) {
    let first = cells[0];
    if cells.iter().all(|&c| c == first) {
        out.push(0);
        out.extend(first.to_be_bytes());
    } else {
        image_palette(out, cells);
    }
}

/// First-appearance palette and packed indices. Generated sections hold few
/// states and long runs, so a small palette is searched linearly with the
/// last cell's slot remembered; larger ones switch to a map.
fn image_palette(out: &mut Vec<u8>, cells: &[u16]) {
    let mut palette: Vec<u16> = Vec::new();
    let mut slot_of: HashMap<u16, u64> = HashMap::new();
    let mut last: Option<(u16, u64)> = None;
    let slots: Vec<u64> = cells
        .iter()
        .map(|&state| match last {
            Some((value, slot)) if value == state => slot,
            _ => {
                let slot = if palette.len() <= 32 {
                    match palette.iter().position(|&p| p == state) {
                        Some(i) => i as u64,
                        None => {
                            palette.push(state);
                            if palette.len() > 32 {
                                slot_of = palette
                                    .iter()
                                    .enumerate()
                                    .map(|(i, &p)| (p, i as u64))
                                    .collect();
                            }
                            (palette.len() - 1) as u64
                        }
                    }
                } else {
                    *slot_of.entry(state).or_insert_with(|| {
                        palette.push(state);
                        (palette.len() - 1) as u64
                    })
                };
                last = Some((state, slot));
                slot
            }
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

/// Changed cells beyond which a relight starts from scratch.
const RELIGHT_LIMIT: usize = 16_384;

/// The world positions where `new` differs from `old` in `chunk` (`None` reads
/// the base profile `layers`).
fn changed_cells(
    layers: &[u16; HEIGHT],
    chunk: (i32, i32),
    old: Option<&Column>,
    new: Option<&Column>,
    out: &mut Vec<(i32, i32, i32)>,
) {
    for s in 0..SECTIONS {
        let base = &layers[s * 16..s * 16 + 16];
        let single = |column: Option<&Column>| match column {
            Some(column) => match column.sections[s] {
                Storage::Single(state) => Some(state),
                _ => None,
            },
            None => base.iter().all(|b| *b == base[0]).then_some(base[0]),
        };
        if let (Some(a), Some(b)) = (single(old), single(new)) {
            if a == b {
                continue;
            }
        }
        for i in 0..VOLUME {
            let at =
                |column: Option<&Column>| column.map_or(base[i >> 8], |c| c.sections[s].get(i));
            if at(old) != at(new) {
                let (x, y, z) = (i & 15, i >> 8, (i >> 4) & 15);
                out.push((
                    chunk.0 * 16 + x as i32,
                    MIN_Y + (s * 16 + y) as i32,
                    chunk.1 * 16 + z as i32,
                ));
            }
        }
    }
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
    /// Whether the region's dimension has sky light (VMC-026b).
    pub sky: bool,
}

/// Dense block states for a full light computation.
struct Dense {
    wx: usize,
    wz: usize,
    states: Vec<u16>,
    sky: bool,
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
    fn has_sky(&self) -> bool {
        self.sky
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
    fn has_sky(&self) -> bool {
        self.store.sky
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
            sky: true,
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
        let sky = self.sky;
        let grid = LightGrid::compute(
            &Dense {
                wx,
                wz,
                states,
                sky,
            },
            facts,
        );
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
            changed_cells(
                &self.layers,
                chunk,
                self.halo.get(&chunk),
                column.as_ref(),
                &mut changed,
            );
            match column {
                Some(column) => self.halo.insert(chunk, column),
                None => self.halo.remove(&chunk),
            };
        }
        Ok(self.relight_cells(facts, &changed))
    }

    /// Install generated columns (VMC-075), all or nothing, and relight once;
    /// returns the region's chunks whose light changed (none before the region
    /// is lit, since the first computation sees them).
    pub fn put_columns(
        &mut self,
        facts: &LightFacts,
        flags: &BlockFlags,
        columns: Vec<((i32, i32), Column)>,
    ) -> Result<Vec<(i32, i32)>, StoreError> {
        let (mut added, mut replaced) = (0, 0);
        for (i, (chunk, column)) in columns.iter().enumerate() {
            self.check_chunk(*chunk)?;
            if columns[..i].iter().any(|(other, _)| other == chunk) {
                return Err(StoreError::OutOfRegion);
            }
            Self::validate(column, flags)?;
            added += column.heap_bytes();
            replaced += self.columns.get(chunk).map_or(0, Column::heap_bytes);
        }
        if self.heap_bytes() - replaced + added > self.budget_bytes {
            return Err(StoreError::MemoryBudget);
        }
        let mut changed = Vec::new();
        for (chunk, column) in columns {
            if self.light.is_some() {
                changed_cells(
                    &self.layers,
                    chunk,
                    self.columns.get(&chunk),
                    Some(&column),
                    &mut changed,
                );
            }
            self.columns.insert(chunk, column);
        }
        Ok(if changed.is_empty() {
            Vec::new()
        } else {
            self.relight_cells(facts, &changed)
        })
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

    /// Relight many cells: incrementally, or from scratch when most of a chunk
    /// changed; either way only the chunks whose light changed are reported.
    fn relight_cells(&mut self, facts: &LightFacts, cells: &[(i32, i32, i32)]) -> Vec<(i32, i32)> {
        if cells.len() <= RELIGHT_LIMIT {
            return self.light_update(facts, cells);
        }
        let before = self.light.take();
        self.light_compute(facts);
        let (Some(before), Some(after)) = (before, self.light.as_ref()) else {
            return Vec::new();
        };
        let (mx, mz) = self.chunk_min;
        (0..self.chunk_size)
            .flat_map(|x| (0..self.chunk_size).map(move |z| (x, z)))
            .filter(|&(x, z)| {
                let (ax, az) = (x as usize + 1, z as usize + 1);
                [Kind::Sky, Kind::Block].iter().any(|&kind| {
                    let (old, new) = (before.chunk(kind, ax, az), after.chunk(kind, ax, az));
                    old.iter().zip(new).any(|(a, b)| !a.same(b))
                })
            })
            .map(|(x, z)| (mx + x, mz + z))
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
    /// (WORLD_SURFACE, MOTION_BLOCKING) packed at 9 bits. `window` is the
    /// dimension's `(first, count)` of the stored sections (VMC-026b): only those
    /// are sent, with heights relative to the first one's bottom.
    pub fn encode_chunk(
        &self,
        chunk: (i32, i32),
        flags: &BlockFlags,
        biome: u32,
        global_bits: u32,
        biome_bits: u32,
        window: (usize, usize),
    ) -> Result<EncodedChunk, StoreError> {
        let (first, count) = window;
        if count == 0 || first + count > SECTIONS {
            return Err(StoreError::InvalidY);
        }
        self.chunk_of(chunk.0 * 16, chunk.1 * 16)?;
        let owned;
        let column = match self.columns.get(&chunk) {
            Some(column) => column,
            None => {
                owned = Column::from_layers(&self.layers);
                &owned
            }
        };
        let mut sections = Vec::with_capacity(count * 16);
        for (s, storage) in column.sections.iter().enumerate().skip(first).take(count) {
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
        let (bottom, top) = ((first * 16) as u16, (count * 16) as u16);
        let relative = |h: &u16| h.saturating_sub(bottom).min(top) as u64;
        let mut surface = Vec::with_capacity(37 * 8);
        wire::pack_longs(
            &mut surface,
            column.heights(flags, WORLD_SURFACE).iter().map(relative),
            9,
        );
        let mut motion = Vec::with_capacity(37 * 8);
        wire::pack_longs(
            &mut motion,
            column.heights(flags, MOTION_BLOCKING).iter().map(relative),
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

    /// The biome of quart `(qx, qy, qz)` as `getNoiseBiome` reads it (y
    /// clamped to the column), `default_biome` for a flat column; None outside
    /// the region.
    pub fn noise_biome(&self, (qx, qy, qz): (i32, i32, i32), default_biome: u16) -> Option<u16> {
        let chunk = (qx >> 2, qz >> 2);
        self.check_chunk(chunk).ok()?;
        let min = MIN_Y >> 2;
        let qy = qy.clamp(min, min + (HEIGHT as i32 >> 2) - 1) - min;
        Some(
            match self.columns.get(&chunk).and_then(|c| c.biomes.as_ref()) {
                Some(biomes) => biomes[(qy >> 2) as usize]
                    .get((((qy & 3) * 4 + (qz & 3)) * 4 + (qx & 3)) as usize),
                None => default_biome,
            },
        )
    }

    pub fn touched(&self, chunk: (i32, i32)) -> bool {
        self.columns.contains_key(&chunk)
    }

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
        Self::validate(&column, flags)?;
        let previous = self.columns.get(&chunk).map_or(0, Column::heap_bytes);
        if self.heap_bytes() - previous + column.heap_bytes() > self.budget_bytes {
            return Err(StoreError::MemoryBudget);
        }
        self.columns.insert(chunk, column);
        Ok(())
    }

    fn validate(column: &Column, flags: &BlockFlags) -> Result<(), StoreError> {
        if column.sections.len() != SECTIONS
            || column.biomes.as_ref().is_some_and(|b| b.len() != SECTIONS)
        {
            return Err(StoreError::InvalidY);
        }
        let mut valid = true;
        for storage in &column.sections {
            storage.for_each(|_, state| valid &= flags.valid(state as u32));
        }
        if valid {
            Ok(())
        } else {
            Err(StoreError::InvalidState)
        }
    }

    /// `/fillbiome` (VMC-053j4), vanilla's `FillBiomeCommand` resolver: in
    /// `chunks`, every biome cell whose corner block lies in `min..=max` and
    /// whose biome passes `filter` (`None`: any) becomes `biome`, at once. The
    /// count of cells that changed and the column images of the chunks with
    /// changes, for the owner to persist. Columns without stored biomes hold
    /// `default_biome` everywhere.
    #[allow(clippy::too_many_arguments)]
    pub fn fill_biomes(
        &mut self,
        chunks: &[(i32, i32)],
        min: [i32; 3],
        max: [i32; 3],
        biome: u16,
        filter: Option<&[u16]>,
        default_biome: u16,
    ) -> Result<(u32, ChunkImages), StoreError> {
        let mut count = 0;
        let mut images = Vec::new();
        for &chunk in chunks {
            self.check_chunk(chunk)?;
            let mut column = match self.columns.get(&chunk) {
                Some(column) => column.clone(),
                None => Column::from_layers(&self.layers),
            };
            let mut biomes: Vec<Biomes> = match column.biomes.take() {
                Some(stored) => stored,
                None => (0..SECTIONS)
                    .map(|_| Biomes::Single(default_biome))
                    .collect(),
            };
            let before = count;
            for (section, cells) in biomes.iter_mut().enumerate() {
                for i in 0..64usize {
                    let qx = chunk.0 * 4 + (i & 3) as i32;
                    let qz = chunk.1 * 4 + ((i >> 2) & 3) as i32;
                    let qy = (MIN_Y >> 2) + section as i32 * 4 + (i >> 4) as i32;
                    let corner = [qx * 4, qy * 4, qz * 4];
                    let inside = (0..3).all(|a| corner[a] >= min[a] && corner[a] <= max[a]);
                    let current = cells.get(i);
                    if !inside || filter.is_some_and(|f| !f.contains(&current)) {
                        continue;
                    }
                    if current != biome {
                        count += 1;
                        let mut all = match cells {
                            Biomes::Single(b) => Box::new([*b; 64]),
                            Biomes::Cells(c) => c.clone(),
                        };
                        all[i] = biome;
                        *cells = if all.iter().all(|&b| b == all[0]) {
                            Biomes::Single(all[0])
                        } else {
                            Biomes::Cells(all)
                        };
                    }
                }
            }
            column.biomes = Some(biomes);
            if count != before {
                images.push((chunk, column.to_image()));
                self.columns.insert(chunk, column);
            }
        }
        Ok((count, images))
    }

    /// A chunk's biomes as `chunks_biomes` carries them: each of the stored
    /// sections `first..first + count` as a biome container.
    pub fn encode_biomes(
        &self,
        chunk: (i32, i32),
        default_biome: u32,
        biome_bits: u32,
        (first, count): (usize, usize),
    ) -> Result<Vec<u8>, StoreError> {
        self.check_chunk(chunk)?;
        let mut out = Vec::new();
        let stored = self.columns.get(&chunk).and_then(|c| c.biomes.as_ref());
        for s in first..first + count {
            let biomes = match stored {
                Some(stored) => wire::SectionBiomes::Stored(&stored[s]),
                None => wire::SectionBiomes::Uniform(default_biome),
            };
            wire::encode_biomes(&mut out, biomes, biome_bits);
        }
        Ok(out)
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
    fn a_window_encodes_only_the_dimension_sections() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let f = flags();
        // A block at y 100 is in stored section 10, the window's sixth (y 0 starts at 4).
        store.set_many(&[(3, 100, 0, 5)], &f).unwrap();
        let (whole, surface, _) = store
            .encode_chunk((0, 0), &f, 1, 15, 6, (0, SECTIONS))
            .unwrap();
        let (part, part_surface, _) = store.encode_chunk((0, 0), &f, 1, 15, 6, (4, 16)).unwrap();
        assert!(part.len() < whole.len());
        let heights = |longs: &[u8]| -> Vec<u64> {
            let words: Vec<u64> = longs
                .chunks(8)
                .map(|b| u64::from_be_bytes(b.try_into().unwrap()))
                .collect();
            (0..256)
                .map(|i| (words[i / 7] >> (9 * (i % 7))) & 511)
                .collect()
        };
        assert_eq!(heights(&surface)[3], (100 - MIN_Y + 1) as u64);
        assert_eq!(heights(&part_surface)[3], 101);
        // The flat surface (y 63) is below the window's top: relative to y 0.
        assert_eq!(heights(&part_surface)[4], 64);
        assert!(store.encode_chunk((0, 0), &f, 1, 15, 6, (20, 8)).is_err());
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
    fn noise_biomes_index_quarts_as_paletted_containers_do() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let mut column = Column::from_layers(&flat());
        let mut biomes = vec![Biomes::Single(1); SECTIONS];
        // Section 5 (y 16..31): biome = its cell index, (y * 4 + z) * 4 + x.
        biomes[5] = Biomes::Cells(Box::new(std::array::from_fn(|i| 100 + i as u16)));
        column.biomes = Some(biomes);
        store.put_column((2, 3), column, &flags()).unwrap();
        // Quart (x 9, y 5, z 14): chunk (2, 3), local (1, 1, 2), section 5.
        assert_eq!(
            store.noise_biome((9, 5, 14), 7),
            Some(100 + (4 + 2) * 4 + 1)
        );
        // y clamps to the column; a flat column reads the default; outside is None.
        assert_eq!(store.noise_biome((9, -40, 14), 7), Some(1));
        assert_eq!(store.noise_biome((9, 200, 14), 7), Some(1));
        assert_eq!(store.noise_biome((0, 5, 0), 7), Some(7));
        assert_eq!(store.noise_biome((-1, 5, 0), 7), None);
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
    fn set_many_is_all_or_nothing() {
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
        assert_eq!(store.get(1, 64, 1), Ok(5));
        assert_eq!(store.get(2, 63, 2), Ok(0));
    }

    /// The light facts of `light_grid`'s tests: 0 air, 1 stone, 2 torch
    /// (emission 14), 3 glass-like, 4 leaves-like, 5 slab-like, 6 lamp.
    fn light_facts() -> LightFacts {
        let full = [0u8, 1, 0, 1, 0, 0, 1];
        let faces: [Vec<u8>; 6] = std::array::from_fn(|d| {
            (0..7)
                .map(|s| if s == 5 { (d == 0) as u8 } else { full[s] })
                .collect()
        });
        LightFacts::new(
            vec![0x00, 0x0F, 0xE0, 0x00, 0x01, 0x00, 0xF0],
            faces,
            [2; 6],
            std::array::from_fn(|_| vec![0b1110]),
            vec![0u8, 1, 0, 1, 1, 1, 1],
            2,
            vec![0b1110],
        )
        .unwrap()
    }

    /// Air with a stone floor at y 60, a cave of air under it and a lamp in it.
    fn terrain(lamp: (usize, usize, usize)) -> Column {
        let mut layers = [0u16; HEIGHT];
        for layer in layers.iter_mut().take((60 - MIN_Y) as usize) {
            *layer = 1;
        }
        let mut column = Column::from_layers(&layers);
        for x in 2..14 {
            for z in 2..14 {
                for y in 20..30 {
                    column.set(x, y, z, 0);
                }
            }
        }
        column.set(lamp.0 as i32, lamp.1 as i32, lamp.2 as i32, 6);
        column
    }

    fn light_of(store: &ColumnStore, chunk: (i32, i32)) -> Vec<u8> {
        store.light_image(chunk).unwrap().unwrap()
    }

    #[test]
    fn put_columns_relights_once_and_reports_the_chunks_whose_light_changed() {
        let (facts, flags) = (light_facts(), flags());
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        store.light_compute(&facts);
        let before: Vec<Vec<u8>> = (0..8)
            .flat_map(|x| (0..8).map(move |z| (x, z)))
            .map(|c| light_of(&store, c))
            .collect();

        // All or nothing: a chunk outside the region installs neither.
        let outside = vec![((2, 2), terrain((5, 25, 5))), ((9, 2), terrain((5, 25, 5)))];
        assert_eq!(
            store.put_columns(&facts, &flags, outside),
            Err(StoreError::OutOfRegion)
        );
        assert!(store.columns.is_empty());

        // Two columns differ from flat terrain in far more cells than an
        // incremental relight takes: the region relights from scratch.
        let columns = vec![((2, 2), terrain((5, 25, 5))), ((6, 5), terrain((8, 22, 3)))];
        let mut changed = store.put_columns(&facts, &flags, columns).unwrap();
        changed.sort();

        let mut fresh = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        fresh.columns = store.columns.clone();
        fresh.light_compute(&facts);
        let mut differs = Vec::new();
        for (i, chunk) in (0..8).flat_map(|x| (0..8).map(move |z| (x, z))).enumerate() {
            assert_eq!(
                light_of(&store, chunk),
                light_of(&fresh, chunk),
                "{chunk:?}"
            );
            if light_of(&store, chunk) != before[i] {
                differs.push(chunk);
            }
        }
        assert_eq!(changed, differs);
        assert!(changed.contains(&(2, 2)) && changed.contains(&(6, 5)));
        assert!(changed.len() < 64, "{changed:?}");

        // A small change relights incrementally, equal to a full computation.
        let mut column = store.columns[&(2, 2)].clone();
        column.set(40, 25, 40, 1);
        column.set(36, 25, 36, 6);
        let changed = store
            .put_columns(&facts, &flags, vec![((2, 2), column)])
            .unwrap();
        fresh.columns = store.columns.clone();
        fresh.light_compute(&facts);
        assert!(changed.contains(&(2, 2)));
        for chunk in (0..8).flat_map(|x| (0..8).map(move |z| (x, z))) {
            assert_eq!(
                light_of(&store, chunk),
                light_of(&fresh, chunk),
                "{chunk:?}"
            );
        }
    }

    #[test]
    fn put_columns_before_the_first_light_computation_only_stores_them() {
        let (facts, flags) = (light_facts(), flags());
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let changed = store
            .put_columns(&facts, &flags, vec![((1, 1), terrain((5, 25, 5)))])
            .unwrap();
        assert!(changed.is_empty() && store.light.is_none());
        assert_eq!(store.get(16, 0, 16), Ok(1));
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
