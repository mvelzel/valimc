//! Chunk columns (24 sections, y −64..319) owned by one region.

use crate::flags::{BlockFlags, MOTION_BLOCKING, WORLD_SURFACE};
use crate::light::LightFacts;
use crate::light_grid::{light_alone, Blocks, ChunkLight, Kind, Layer, LightGrid, TooLarge};
use crate::section::{index, Biomes, Storage, VOLUME};
use crate::snapshot::ChunkSnapshot;
use crate::wire;
use std::collections::HashMap;
use std::sync::Arc;

pub const MIN_Y: i32 = -64;
pub const HEIGHT: usize = 384;
pub const SECTIONS: usize = HEIGHT / 16;

/// Column images by chunk (`fill_biomes`).
pub type ChunkImages = Vec<((i32, i32), Vec<u8>)>;

/// Encoded chunk parts: section data, WORLD_SURFACE longs, MOTION_BLOCKING longs.
pub type EncodedChunk = (Vec<u8>, Vec<u8>, Vec<u8>);

/// A column's sections, bottom first, and biomes are shared with the chunk
/// snapshots published from it (VMC-077p): a write clones a shared section
/// first (`Arc::make_mut`), so a snapshot never changes and holds only the
/// sections written since it was taken in memory of its own.
#[derive(Clone, Debug)]
pub struct Column {
    pub sections: Vec<Arc<Storage>>,
    /// Per-section biomes; `None` uses the region's default biome everywhere.
    pub biomes: Option<Arc<Vec<Biomes>>>,
}

impl Column {
    pub fn new(sections: Vec<Storage>, biomes: Option<Vec<Biomes>>) -> Self {
        Self {
            sections: sections.into_iter().map(Arc::new).collect(),
            biomes: biomes.map(Arc::new),
        }
    }

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
        Self::new(sections, None)
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

    /// Store `state` and return the previous one; a section shared with a
    /// snapshot is cloned first, and only when the state changes.
    pub fn set(&mut self, x: i32, y: i32, z: i32, state: u16) -> u16 {
        let (s, i) = Self::locate(x, y, z);
        let previous = self.sections[s].get(i);
        if previous != state {
            Arc::make_mut(&mut self.sections[s]).set(i, state);
        }
        previous
    }

    /// Heights (1 + highest matching y, relative to MIN_Y; 0 when none) per column
    /// in `z * 16 + x` order for one heightmap predicate bit.
    pub fn heights(&self, flags: &BlockFlags, mask: u8) -> [u16; 256] {
        std::array::from_fn(|c| height(&self.sections, c & 15, c >> 4, flags, mask))
    }

    /// A compact, versioned image of the column for the region log (VMC-021c):
    /// a version and flags (biomes 1, light 2), per section a single state or a
    /// first-appearance palette with indices packed at `max(1, ⌈log2 n⌉)` bits,
    /// the same for biomes if the column has them, then the light the column was
    /// stored with, if any (`with_light`).
    pub fn to_image(&self) -> Vec<u8> {
        let mut out = vec![IMAGE_VERSION, self.biomes.is_some() as u8];
        for storage in &self.sections {
            match &**storage {
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
        for biomes in self.biomes.iter().flat_map(|b| b.iter()) {
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

    /// Read `to_image` output without its light; `None` for any other bytes.
    pub fn from_image(bytes: &[u8]) -> Option<Column> {
        Column::read_image(bytes).map(|(column, _)| column)
    }

    /// Read a column image and the light stored with it, if any.
    pub fn read_image(bytes: &[u8]) -> Option<(Column, Option<ChunkLight>)> {
        Column::read_sections(bytes, SECTIONS)
    }

    /// Read an image of `count` sections (a proto chunk of another
    /// dimension's height, VMC-026b).
    pub fn from_image_sections(bytes: &[u8], count: usize) -> Option<Column> {
        Column::read_sections(bytes, count).map(|(column, _)| column)
    }

    fn read_sections(bytes: &[u8], count: usize) -> Option<(Column, Option<ChunkLight>)> {
        let mut input = bytes;
        let [version, flags] = take::<2>(&mut input)?;
        let (has_biomes, has_light) = (flags & 1 == 1, flags & 2 == 2);
        if version != IMAGE_VERSION
            || flags > 3
            || count == 0
            || count > SECTIONS
            || (has_light && count != SECTIONS)
        {
            return None;
        }
        let mut sections = Vec::with_capacity(count);
        for _ in 0..count {
            let (palette, data, bits) = read_palette(&mut input, VOLUME)?;
            sections.push(Storage::from_palette(&palette, data, bits)?);
        }
        let biomes = if has_biomes {
            let mut all = Vec::with_capacity(count);
            for _ in 0..count {
                let (palette, data, bits) = read_palette(&mut input, 64)?;
                all.push(Biomes::from_palette(&palette, data, bits)?);
            }
            Some(all)
        } else {
            None
        };
        let light = if has_light {
            Some(ChunkLight::read(&mut input)?)
        } else {
            None
        };
        input
            .is_empty()
            .then(|| (Column::new(sections, biomes), light))
    }

    pub fn heap_bytes(&self) -> usize {
        let biomes = self
            .biomes
            .as_ref()
            .map_or(0, |b| b.iter().map(Biomes::heap_bytes).sum());
        self.sections.iter().map(|s| s.heap_bytes()).sum::<usize>() + biomes
    }
}

/// The height of column `(x, z)` of `sections` (bottom first) for one
/// heightmap predicate bit: 1 + the highest matching y relative to MIN_Y, 0
/// when none.
pub fn height(sections: &[Arc<Storage>], x: usize, z: usize, flags: &BlockFlags, mask: u8) -> u16 {
    for s in (0..sections.len()).rev() {
        let section = &*sections[s];
        if let Storage::Single(state) = section {
            if flags.get(*state) & mask != 0 {
                return (s * 16 + 16) as u16;
            }
            continue;
        }
        for y in (0..16).rev() {
            if flags.get(section.get(index(x, y, z))) & mask != 0 {
                return (s * 16 + y + 1) as u16;
            }
        }
    }
    0
}

/// The lowest sky source of column `(x, z)` of `sections` (bottom first,
/// `ChunkSkyLightSources`) relative to MIN_Y: one above the highest edge
/// vertical sky light cannot pass, 0 when there is none. Above the column is
/// open sky (air).
pub fn sky_source(sections: &[Arc<Storage>], x: usize, z: usize, facts: &LightFacts) -> u16 {
    let mut above = 0u16;
    for s in (0..sections.len()).rev() {
        let section = &*sections[s];
        if let Storage::Single(state) = section {
            if !facts.sky_blocked(above, *state) && !facts.sky_blocked(*state, *state) {
                above = *state;
                continue;
            }
        }
        for y in (0..16).rev() {
            let state = section.get(index(x, y, z));
            if facts.sky_blocked(above, state) {
                return (s * 16 + y + 1) as u16;
            }
            above = state;
        }
    }
    0
}

/// The blocks of `chunk` whose state is in `states`, scanning only sections
/// whose palette holds one.
pub fn find(
    sections: &[Arc<Storage>],
    chunk: (i32, i32),
    states: &[u16],
) -> Vec<(i32, i32, i32, u16)> {
    let mut out = Vec::new();
    for (s, storage) in sections.iter().enumerate() {
        let candidate = match &**storage {
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
    out
}

/// The stored biome of quart `(qx, qy, qz)` (y clamped to the column) in a
/// column's per-section biomes.
pub fn quart_biome(biomes: &[Biomes], (qx, qy, qz): (i32, i32, i32)) -> u16 {
    let min = MIN_Y >> 2;
    let qy = qy.clamp(min, min + (HEIGHT as i32 >> 2) - 1) - min;
    biomes[(qy >> 2) as usize].get((((qy & 3) * 4 + (qz & 3)) * 4 + (qx & 3)) as usize)
}

/// Version 2 added the stored light (VMC-077c); older images are refused.
pub const IMAGE_VERSION: u8 = 2;

/// `image` (a column image without light) with `light` stored after it.
pub fn with_light(image: &[u8], light: &ChunkLight) -> Vec<u8> {
    let mut out = image.to_vec();
    out[1] |= 2;
    light.write(&mut out);
    out
}

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

/// A chunk whose light changed: the chunk, then its changed sections' sky and
/// block bits (bit `s` for stored section `s`).
pub type LightChange = ((i32, i32), u32, u32);

/// The world positions where `new` differs from `old` in `chunk`.
fn changed_cells(chunk: (i32, i32), old: &Column, new: &Column, out: &mut Vec<(i32, i32, i32)>) {
    for s in 0..SECTIONS {
        if Arc::ptr_eq(&old.sections[s], &new.sections[s]) {
            continue;
        }
        if let (Storage::Single(a), Storage::Single(b)) = (&*old.sections[s], &*new.sections[s]) {
            if a == b {
                continue;
            }
        }
        for i in 0..VOLUME {
            if old.sections[s].get(i) != new.sections[s].get(i) {
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
    /// Light of the region and its one-chunk ring (VMC-077c), chunk by chunk;
    /// a chunk is unknown to light until lit. Area chunk `(ax, az)` is chunk
    /// `chunk_min - 1 + (ax, az)`.
    pub light: LightGrid,
    /// Light restored columns were stored with, until `light_init` adopts it.
    stored: HashMap<(i32, i32), ChunkLight>,
    /// Known chunks of the ring, as their owners last sent them.
    pub halo: HashMap<(i32, i32), Column>,
    /// The base profile as a column, which untouched region chunks read.
    flat: Column,
    /// Whether the region's dimension has sky light (VMC-026b).
    pub sky: bool,
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
        let ring = chunk_size as usize + 2;
        Self {
            chunk_min,
            chunk_size,
            flat: Column::from_layers(&layers),
            layers,
            columns: HashMap::new(),
            budget_bytes,
            ticking: Vec::new(),
            rng: rng.max(1),
            light: LightGrid::new(ring, ring),
            stored: HashMap::new(),
            halo: HashMap::new(),
            sky: true,
        }
    }

    /// A region chunk's column: its own, or the base profile's while untouched.
    fn column(&self, chunk: (i32, i32)) -> &Column {
        self.columns.get(&chunk).unwrap_or(&self.flat)
    }

    /// The area chunk of `chunk` if it is in the region or its ring.
    fn area_chunk(&self, (cx, cz): (i32, i32)) -> Option<(usize, usize)> {
        let (ax, az) = (cx - self.chunk_min.0 + 1, cz - self.chunk_min.1 + 1);
        let n = self.chunk_size + 2;
        ((0..n).contains(&ax) && (0..n).contains(&az)).then_some((ax as usize, az as usize))
    }

    /// The region and its ring as light reads them: region chunks without a
    /// column read the base profile, ring chunks their neighbour's column.
    fn light_blocks(&self) -> Blocks<'_> {
        let n = self.chunk_size as usize + 2;
        let (mx, mz) = self.chunk_min;
        let chunks = (0..n * n)
            .map(|i| {
                let chunk = (mx - 1 + (i / n) as i32, mz - 1 + (i % n) as i32);
                if self.check_chunk(chunk).is_ok() {
                    Some(&self.columns.get(&chunk).unwrap_or(&self.flat).sections[..])
                } else {
                    self.halo.get(&chunk).map(|column| &column.sections[..])
                }
            })
            .collect();
        Blocks {
            nx: n,
            nz: n,
            chunks,
            sky: self.sky,
        }
    }

    fn with_light<T>(&mut self, f: impl FnOnce(&mut LightGrid, &Blocks) -> T) -> T {
        let mut grid = std::mem::take(&mut self.light);
        let out = f(&mut grid, &self.light_blocks());
        self.light = grid;
        out
    }

    /// Area cells of world positions in the region or its ring.
    fn area_cells(&self, positions: &[(i32, i32, i32)]) -> Vec<(usize, usize, usize)> {
        let (ox, oz) = ((self.chunk_min.0 - 1) * 16, (self.chunk_min.1 - 1) * 16);
        let span = (self.chunk_size + 2) * 16;
        positions
            .iter()
            .filter(|(x, y, z)| {
                (ox..ox + span).contains(x)
                    && (oz..oz + span).contains(z)
                    && (MIN_Y..MIN_Y + HEIGHT as i32).contains(y)
            })
            .map(|(x, y, z)| ((x - ox) as usize, (y - MIN_Y) as usize, (z - oz) as usize))
            .collect()
    }

    /// The region's chunks whose light changed since the last call.
    fn light_changes(&mut self) -> Vec<LightChange> {
        let (mx, mz) = self.chunk_min;
        let changes = self.light.take_changes();
        changes
            .into_iter()
            .map(|((ax, az), sky, block)| ((mx - 1 + ax as i32, mz - 1 + az as i32), sky, block))
            .filter(|(chunk, _, _)| self.check_chunk(*chunk).is_ok())
            .collect()
    }

    /// Light the region (VMC-077c): every chunk but the `absent` ones (not
    /// generated yet) from the light its column was stored with, or lit alone,
    /// then the light across the faces between them. Later block changes relight
    /// incrementally (`light_update`).
    pub fn light_init(
        &mut self,
        facts: &LightFacts,
        absent: &[(i32, i32)],
    ) -> Result<(), StoreError> {
        for chunk in absent {
            self.check_chunk(*chunk)?;
        }
        let mut stored = std::mem::take(&mut self.stored);
        let flat = light_alone(&self.flat.sections, facts, self.sky);
        let (mx, mz) = self.chunk_min;
        let chunks: Vec<_> = (0..self.chunk_size)
            .flat_map(|x| (0..self.chunk_size).map(move |z| (mx + x, mz + z)))
            .filter(|chunk| !absent.contains(chunk))
            .filter_map(|chunk| {
                let (ax, az) = self.area_chunk(chunk)?;
                if self.light.known(ax, az) {
                    return None;
                }
                let light = match self.columns.get(&chunk) {
                    Some(_) => stored.remove(&chunk),
                    None => Some(flat.clone()),
                };
                Some(((ax, az), light))
            })
            .collect();
        self.with_light(|grid, blocks| grid.install(blocks, facts, chunks));
        self.light.take_changes();
        Ok(())
    }

    /// Relight after blocks at `positions` changed (in the region or its ring);
    /// returns the region's light changes. With a budget of queue steps, an
    /// update that needs more is undone (`TooLarge`).
    pub fn light_update(
        &mut self,
        facts: &LightFacts,
        positions: &[(i32, i32, i32)],
        budget: Option<usize>,
    ) -> Result<Vec<LightChange>, TooLarge> {
        let cells = self.area_cells(positions);
        self.with_light(|grid, blocks| grid.update(blocks, facts, &cells, budget))?;
        Ok(self.light_changes())
    }

    /// Whether `chunk` is in the one-chunk ring around the region.
    pub fn in_ring(&self, chunk: (i32, i32)) -> bool {
        self.check_chunk(chunk).is_err() && self.area_chunk(chunk).is_some()
    }

    /// Adopt ring chunks from a neighbour's columns (`None`: the base profile).
    /// A chunk new to the ring is lit alone and light crosses its faces; a known
    /// one relights the cells that changed. Returns the region's light changes.
    pub fn halo_put(
        &mut self,
        facts: &LightFacts,
        chunks: Vec<((i32, i32), Option<Column>)>,
    ) -> Result<Vec<LightChange>, StoreError> {
        if chunks.iter().any(|(chunk, _)| !self.in_ring(*chunk)) {
            return Err(StoreError::OutOfRegion);
        }
        let (mut fresh, mut changed) = (Vec::new(), Vec::new());
        for (chunk, column) in chunks {
            let column = column.unwrap_or_else(|| self.flat.clone());
            match self.halo.get(&chunk) {
                Some(old) => changed_cells(chunk, old, &column, &mut changed),
                None => fresh.push((self.area_chunk(chunk).unwrap(), None)),
            }
            self.halo.insert(chunk, column);
        }
        let cells = self.area_cells(&changed);
        self.with_light(|grid, blocks| {
            grid.install(blocks, facts, fresh);
            grid.update(blocks, facts, &cells, None)
        })
        .expect("an update without a budget completes");
        Ok(self.light_changes())
    }

    /// Install generated columns (VMC-075), all or nothing, each with the light
    /// it was generated with (or lit alone), and let light cross their faces;
    /// returns the region's light changes.
    pub fn put_columns(
        &mut self,
        facts: &LightFacts,
        flags: &BlockFlags,
        columns: Vec<((i32, i32), Column, Option<ChunkLight>)>,
    ) -> Result<Vec<LightChange>, StoreError> {
        let (mut added, mut replaced) = (0, 0);
        for (i, (chunk, column, _)) in columns.iter().enumerate() {
            self.check_chunk(*chunk)?;
            if columns[..i].iter().any(|(other, _, _)| other == chunk) {
                return Err(StoreError::OutOfRegion);
            }
            Self::validate(column, flags)?;
            added += column.heap_bytes();
            replaced += self.columns.get(chunk).map_or(0, Column::heap_bytes);
        }
        if self.heap_bytes() - replaced + added > self.budget_bytes {
            return Err(StoreError::MemoryBudget);
        }
        let (mut fresh, mut changed) = (Vec::new(), Vec::new());
        for (chunk, column, light) in columns {
            let (ax, az) = self.area_chunk(chunk).unwrap();
            if self.light.known(ax, az) {
                let old = self.columns.get(&chunk).unwrap_or(&self.flat);
                changed_cells(chunk, old, &column, &mut changed);
            } else {
                fresh.push(((ax, az), light));
            }
            self.stored.remove(&chunk);
            self.columns.insert(chunk, column);
        }
        let cells = self.area_cells(&changed);
        self.with_light(|grid, blocks| {
            grid.install(blocks, facts, fresh);
            grid.update(blocks, facts, &cells, None)
        })
        .expect("an update without a budget completes");
        Ok(self.light_changes())
    }

    /// Apply a neighbour's block changes to known ring chunks; returns the
    /// positions applied, for `light_update`.
    pub fn halo_set(&mut self, edits: &[(i32, i32, i32, u16)]) -> Vec<(i32, i32, i32)> {
        let mut positions = Vec::with_capacity(edits.len());
        for &(x, y, z, state) in edits {
            let chunk = (x >> 4, z >> 4);
            if !(self.in_ring(chunk) && (MIN_Y..MIN_Y + HEIGHT as i32).contains(&y)) {
                continue;
            }
            if let Some(column) = self.halo.get_mut(&chunk) {
                column.set(x, y, z, state);
                positions.push((x, y, z));
            }
        }
        positions
    }

    /// A chunk's light image (VMC-021e5 layout), `None` while the chunk is
    /// unknown to light: 26 sections from one below the world to one above,
    /// each sky then block as tag 1 + repeated byte (uniform) or tag 2 + 2,048
    /// bytes. With `sections` (sky and block bits per stored section) only those
    /// layers, and tag 0 (absent) for every other.
    pub fn light_image(
        &self,
        chunk: (i32, i32),
        sections: Option<(u32, u32)>,
    ) -> Result<Option<Vec<u8>>, StoreError> {
        self.check_chunk(chunk)?;
        let (ax, az) = self.area_chunk(chunk).unwrap();
        let (Some(sky), Some(block)) = (
            self.light.layers(Kind::Sky, ax, az),
            self.light.layers(Kind::Block, ax, az),
        ) else {
            return Ok(None);
        };
        let mut out = Vec::with_capacity(26 * 4);
        let edge = |out: &mut Vec<u8>, sky: u8| match sections {
            // Below the world dark, above it open sky.
            None => {
                Layer::Uniform(sky).write(out);
                Layer::Uniform(0).write(out);
            }
            Some(_) => out.extend([0, 0]),
        };
        edge(&mut out, 0);
        for s in 0..SECTIONS {
            let (sky_bits, block_bits) = sections.unwrap_or((u32::MAX, u32::MAX));
            for (layer, bits) in [(&sky[s], sky_bits), (&block[s], block_bits)] {
                if bits & 1 << s == 0 {
                    out.push(0);
                } else {
                    layer.write(&mut out);
                }
            }
        }
        edge(&mut out, 15);
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

    /// The states of the box `min..=max` (inside the region and the build
    /// height) in vanilla's `BlockPos.betweenClosed` order: x fastest, then y,
    /// then z (VMC-077o box edits).
    pub fn read_box(
        &self,
        min: (i32, i32, i32),
        max: (i32, i32, i32),
    ) -> Result<Vec<u16>, StoreError> {
        let ((x0, y0, z0), (x1, y1, z1)) = (min, max);
        if x0 > x1 || y0 > y1 || z0 > z1 {
            return Err(StoreError::OutOfRegion);
        }
        self.chunk_of(x0, z0)?;
        self.chunk_of(x1, z1)?;
        Self::check_y(y0)?;
        Self::check_y(y1)?;
        let mut out = Vec::with_capacity(
            ((x1 - x0 + 1) as usize) * ((y1 - y0 + 1) as usize) * ((z1 - z0 + 1) as usize),
        );
        for z in z0..=z1 {
            for y in y0..=y1 {
                for x in x0..=x1 {
                    out.push(match self.columns.get(&self.chunk_of(x, z)?) {
                        Some(column) => column.get(x, y, z),
                        None => self.layers[(y - MIN_Y) as usize],
                    });
                }
            }
        }
        Ok(out)
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
            let flat = &self.flat;
            let column = self.columns.entry(chunk).or_insert_with(|| flat.clone());
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
        let column = self.column(chunk);
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
        Ok(find(&self.column(chunk).sections, chunk, states))
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
        Some(
            match self.columns.get(&chunk).and_then(|c| c.biomes.as_ref()) {
                Some(biomes) => quart_biome(biomes, (qx, qy, qz)),
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
                            Some(column) => match &*column.sections[s] {
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
        self.stored.remove(&chunk);
        self.columns.insert(chunk, column);
        Ok(())
    }

    /// Restore a chunk's column from its image (region load), keeping the light
    /// it was stored with for `light_init`.
    pub fn restore_column(
        &mut self,
        chunk: (i32, i32),
        column: Column,
        light: Option<ChunkLight>,
        flags: &BlockFlags,
    ) -> Result<(), StoreError> {
        self.put_column(chunk, column, flags)?;
        if let Some(light) = light {
            self.stored.insert(chunk, light);
        }
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
                None => self.flat.clone(),
            };
            let mut biomes: Vec<Biomes> = match column.biomes.take() {
                Some(stored) => Arc::unwrap_or_clone(stored),
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
            column.biomes = Some(Arc::new(biomes));
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

    /// `chunk` published at `revision` (VMC-077p), sharing its sections and
    /// biomes; `previous` is its last publication. An untouched chunk
    /// publishes the base profile.
    pub fn snapshot(
        &self,
        chunk: (i32, i32),
        revision: u64,
        previous: Option<&ChunkSnapshot>,
    ) -> Result<ChunkSnapshot, StoreError> {
        self.check_chunk(chunk)?;
        Ok(ChunkSnapshot::new(
            chunk,
            self.column(chunk),
            revision,
            previous,
        ))
    }

    /// The store's columns and the base profile, for `snapshot::resident_bytes`.
    pub fn all_columns(&self) -> impl Iterator<Item = &Column> {
        self.columns.values().chain(std::iter::once(&self.flat))
    }

    /// One chunk's states (24 × 4096, section index order) and biomes (24 × 64);
    /// biomes are `default_biome` where the column has none.
    pub fn dump_column(
        &self,
        chunk: (i32, i32),
        default_biome: u16,
    ) -> Result<(Vec<u16>, Vec<u16>), StoreError> {
        self.check_chunk(chunk)?;
        let column = self.column(chunk);
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
        column.biomes = Some(Arc::new(biomes));
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
    fn a_box_reads_x_fastest_then_y_then_z() {
        let mut store = ColumnStore::new((0, 0), 8, flat(), 1 << 30);
        let f = flags();
        store
            .set_many(&[(17, 64, 3, 5), (16, 65, 4, 6)], &f)
            .unwrap();
        let states = store.read_box((16, 64, 3), (17, 65, 4)).unwrap();
        // (16,64,3) (17,64,3) (16,65,3) (17,65,3) (16,64,4) (17,64,4) (16,65,4) (17,65,4)
        assert_eq!(states, vec![0, 5, 0, 0, 0, 0, 6, 0]);
        assert_eq!(store.read_box((0, 63, 0), (0, 63, 0)).unwrap(), vec![4]);
        assert!(store.read_box((0, 64, 0), (128, 64, 0)).is_err());
        assert!(store.read_box((0, 400, 0), (0, 401, 0)).is_err());
        assert!(store.read_box((3, 64, 0), (2, 64, 0)).is_err());
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
        column.biomes = Some(Arc::new(biomes));
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

    /// Stone below y 60, air above.
    fn ground() -> Box<[u16; HEIGHT]> {
        let mut layers = Box::new([0u16; HEIGHT]);
        layers[..(60 - MIN_Y) as usize].fill(1);
        layers
    }

    /// Ground with a closed cave at y 20..29 holding a lamp.
    fn terrain(lamp: (usize, usize, usize)) -> Column {
        let mut column = Column::from_layers(&ground());
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
        store.light_image(chunk, None).unwrap().unwrap()
    }

    fn all_chunks() -> Vec<(i32, i32)> {
        (0..8).flat_map(|x| (0..8).map(move |z| (x, z))).collect()
    }

    #[test]
    fn put_columns_lights_new_chunks_at_their_faces_as_a_load_would() {
        let (facts, flags) = (light_facts(), flags());
        let mut store = ColumnStore::new((0, 0), 8, ground(), 1 << 30);
        store.light_init(&facts, &all_chunks()).unwrap();

        // All or nothing: a chunk outside the region installs neither.
        let outside = vec![
            ((2, 2), terrain((5, 25, 5)), None),
            ((9, 2), terrain((5, 25, 5)), None),
        ];
        assert_eq!(
            store.put_columns(&facts, &flags, outside),
            Err(StoreError::OutOfRegion)
        );
        assert!(store.columns.is_empty());

        // One chunk with the light generation stored, one lit here, and an open
        // pit across their face.
        let mut a = terrain((5, 25, 5));
        let mut b = terrain((8, 22, 3));
        for y in 40..60 {
            a.set(15, y, 7, 0);
            b.set(0, y, 7, 0);
        }
        a.set(15, 45, 7, 2);
        let stored = light_alone(&a.sections, &facts, true);
        let columns = vec![((2, 2), a.clone(), Some(stored)), ((3, 2), b.clone(), None)];
        let changes = store.put_columns(&facts, &flags, columns).unwrap();
        // The torch lights across the face into the chunk lit here; the stored
        // light of the other is already right.
        assert_eq!(
            changes.iter().map(|c| c.0).collect::<Vec<_>>(),
            vec![(3, 2)]
        );
        assert_eq!(
            store.light_image((4, 4), None),
            Ok(None),
            "absent chunks are unknown"
        );

        // A region loading these columns lights them the same.
        let mut loaded = ColumnStore::new((0, 0), 8, ground(), 1 << 30);
        loaded.restore_column((2, 2), a, None, &flags).unwrap();
        loaded.restore_column((3, 2), b, None, &flags).unwrap();
        let absent: Vec<_> = all_chunks()
            .into_iter()
            .filter(|c| ![(2, 2), (3, 2)].contains(c))
            .collect();
        loaded.light_init(&facts, &absent).unwrap();
        for chunk in [(2, 2), (3, 2)] {
            assert_eq!(
                light_of(&store, chunk),
                light_of(&loaded, chunk),
                "{chunk:?}"
            );
        }

        // Replacing a known chunk relights the cells that changed.
        let mut column = store.columns[&(2, 2)].clone();
        column.set(40, 25, 40, 1);
        column.set(36, 25, 36, 6);
        let changes = store
            .put_columns(&facts, &flags, vec![((2, 2), column.clone(), None)])
            .unwrap();
        assert_eq!(
            changes.iter().map(|c| c.0).collect::<Vec<_>>(),
            vec![(2, 2)]
        );
        loaded.put_column((2, 2), column, &flags).unwrap();
        let mut again = ColumnStore::new((0, 0), 8, ground(), 1 << 30);
        again.columns = loaded.columns.clone();
        again.light_init(&facts, &absent).unwrap();
        assert_eq!(light_of(&store, (2, 2)), light_of(&again, (2, 2)));
    }

    #[test]
    fn column_images_keep_the_light_they_were_stored_with() {
        let (facts, flags) = (light_facts(), flags());
        let column = terrain((5, 25, 5));
        let light = light_alone(&column.sections, &facts, true);
        let image = with_light(&column.to_image(), &light);
        let (back, stored) = Column::read_image(&image).unwrap();
        assert_eq!(stored.as_ref(), Some(&light));
        assert_eq!(Column::read_image(&column.to_image()).unwrap().1, None);
        assert!(Column::read_image(&image[..image.len() - 1]).is_none());
        // Version 1 images (before stored light) are refused.
        let mut old = column.to_image();
        old[0] = 1;
        assert!(Column::from_image(&old).is_none());

        // Restored with its light, the chunk lights as one lit from scratch.
        let mut adopted = ColumnStore::new((0, 0), 8, ground(), 1 << 30);
        adopted
            .restore_column((1, 1), back, stored, &flags)
            .unwrap();
        adopted.light_init(&facts, &[]).unwrap();
        let mut computed = ColumnStore::new((0, 0), 8, ground(), 1 << 30);
        computed.put_column((1, 1), column, &flags).unwrap();
        computed.light_init(&facts, &[]).unwrap();
        for chunk in all_chunks() {
            assert_eq!(
                light_of(&adopted, chunk),
                light_of(&computed, chunk),
                "{chunk:?}"
            );
        }
    }

    #[test]
    fn the_ring_is_unknown_until_a_neighbour_sends_it() {
        let (facts, flags) = (light_facts(), flags());
        let mut store = ColumnStore::new((0, 0), 2, ground(), 1 << 30);
        store.light_init(&facts, &[]).unwrap();
        let block = |store: &ColumnStore, x: i32, y: i32, z: i32| {
            let (ax, az) = ((x + 16) as usize, (z + 16) as usize);
            store.light.get(Kind::Block, (ax, (y - MIN_Y) as usize, az))
        };
        // A torch in the air west of the region, in an unknown ring chunk.
        let mut west = Column::from_layers(&ground());
        west.set(-1, 70, 5, 2);
        assert_eq!(
            store.halo_set(&[(-1, 70, 5, 2)]),
            vec![],
            "unknown ring chunks take no edits"
        );
        let changes = store.halo_put(&facts, vec![((-1, 0), Some(west))]).unwrap();
        assert_eq!(block(&store, 0, 70, 5), 13);
        // Air at y 60..82 holds that light (sections 7 to 9), and z 16 and 17
        // at y 70 or so (section 8) in the next chunk.
        let lit = vec![((0, 0), 0, 1 << 7 | 1 << 8 | 1 << 9), ((0, 1), 0, 1 << 8)];
        assert_eq!(changes, lit);
        // Only that layer, the 51 others absent.
        let image = store
            .light_image((0, 0), Some((0, 1 << 8)))
            .unwrap()
            .unwrap();
        assert_eq!(image.len(), 51 + 1 + 2048);

        // The neighbour removes it.
        let positions = store.halo_set(&[(-1, 70, 5, 0)]);
        assert_eq!(positions, vec![(-1, 70, 5)]);
        // A budget too small for the change leaves the light as it was.
        let before = light_of(&store, (0, 0));
        assert_eq!(
            store.light_update(&facts, &positions, Some(10)),
            Err(TooLarge)
        );
        assert_eq!(light_of(&store, (0, 0)), before);
        assert_eq!(store.light_update(&facts, &positions, None), Ok(lit));
        assert_eq!(block(&store, 0, 70, 5), 0);
        assert!(store
            .put_column((0, 0), Column::from_layers(&ground()), &flags)
            .is_ok());
    }

    #[test]
    fn sky_sources_stop_at_the_highest_blocked_edge() {
        let mut column = Column::from_layers(&ground());
        column.set(3, 100, 5, 4);
        let facts = light_facts();
        assert_eq!(
            sky_source(&column.sections, 3, 5, &facts),
            (101 - MIN_Y) as u16
        );
        assert_eq!(
            sky_source(&column.sections, 0, 0, &facts),
            (60 - MIN_Y) as u16
        );
        let open = Column::from_layers(&Box::new([0u16; HEIGHT]));
        assert!((0..256).all(|c| sky_source(&open.sections, c & 15, c >> 4, &facts) == 0));
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
