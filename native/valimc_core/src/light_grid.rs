//! Live light over an area of chunks: sky and block light per section as one
//! uniform level or a vanilla nibble array, equal to the fixpoint of `light`'s
//! rules (VMC-022c), kept chunk by chunk (VMC-077c).
//!
//! A chunk of the area is unknown until it is installed. Light never enters an
//! unknown chunk and none comes out of it, as vanilla treats a chunk that is not
//! loaded, so installing chunks can only add light and costs work at their
//! faces, not over the area. An installed chunk adopts the light it was stored
//! with or is lit alone, the way Starlight lights a new chunk: sky light as a
//! column fill down to each column's lowest source, block light only from
//! sections whose palette may hold an emitter. The edge checks then queue every
//! cell on either side of its faces that can brighten the cell across, and one
//! increase pass spreads that light to the fixpoint.
//!
//! A block change works like vanilla's decrease and increase queues: light that
//! may have depended on the changed cells (or on sky sources a column lost) is
//! cleared outward while it is dimmer than what removed it, brighter cells met on
//! the way and every source in the cleared region are queued again, and the
//! increase pass spreads them back. An update may get a budget of queue steps;
//! past it the update is undone and reports `TooLarge`, so the caller can run it
//! again where long work is allowed.

use crate::light::{LightFacts, HEIGHT};
use crate::section::{index, Storage};

pub const SECTIONS: usize = HEIGHT / 16;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Layer {
    Uniform(u8),
    Nibbles(Box<[u8; 2048]>),
}

impl Layer {
    #[inline]
    pub fn get(&self, i: usize) -> u8 {
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

    /// Whether two layers hold the same levels, whatever their representation.
    pub fn same(&self, other: &Layer) -> bool {
        match (self, other) {
            (Layer::Uniform(a), Layer::Uniform(b)) => a == b,
            (Layer::Nibbles(a), Layer::Nibbles(b)) => a == b,
            _ => self.nibbles() == other.nibbles(),
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

    /// Tag 1 and the level in both nibbles, or tag 2 and the nibble array.
    pub fn write(&self, out: &mut Vec<u8>) {
        match self {
            Layer::Uniform(level) => out.extend([1, level | level << 4]),
            Layer::Nibbles(bytes) => {
                out.push(2);
                out.extend_from_slice(&bytes[..]);
            }
        }
    }

    fn read(input: &mut &[u8]) -> Option<Layer> {
        let (&tag, rest) = input.split_first()?;
        let (layer, rest) = match tag {
            1 => {
                let (&byte, rest) = rest.split_first()?;
                (byte >> 4 == byte & 15).then_some((Layer::Uniform(byte & 15), rest))?
            }
            2 => {
                let (bytes, rest) = rest.split_at_checked(2048)?;
                (Layer::Nibbles(Box::new(bytes.try_into().ok()?)), rest)
            }
            _ => return None,
        };
        *input = rest;
        Some(layer)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Sky,
    Block,
}

/// A chunk's light, per section from the bottom.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChunkLight {
    pub sky: Vec<Layer>,
    pub block: Vec<Layer>,
}

impl ChunkLight {
    /// Per section its sky then its block layer (`Layer::write`).
    pub fn write(&self, out: &mut Vec<u8>) {
        for (sky, block) in self.sky.iter().zip(&self.block) {
            sky.write(out);
            block.write(out);
        }
    }

    pub fn read(input: &mut &[u8]) -> Option<ChunkLight> {
        let (mut sky, mut block) = (Vec::with_capacity(SECTIONS), Vec::with_capacity(SECTIONS));
        for _ in 0..SECTIONS {
            sky.push(Layer::read(input)?);
            block.push(Layer::read(input)?);
        }
        Some(ChunkLight { sky, block })
    }
}

/// The blocks light reads: per chunk of the area (`cx * nz + cz`) its sections,
/// or `None` where there are none. Light reads only the chunks it knows.
pub struct Blocks<'a> {
    pub nx: usize,
    pub nz: usize,
    pub chunks: Vec<Option<&'a [Storage]>>,
    /// Whether the dimension has sky light (the Nether has none, VMC-026b).
    pub sky: bool,
}

impl Blocks<'_> {
    #[inline]
    fn state(&self, x: usize, y: usize, z: usize) -> u16 {
        match self.chunks[(x >> 4) * self.nz + (z >> 4)] {
            Some(sections) => sections[y >> 4].get(index(x & 15, y & 15, z & 15)),
            None => 0,
        }
    }
}

/// An update stopped at its budget and was undone.
#[derive(Debug, PartialEq, Eq)]
pub struct TooLarge;

type Cell = (usize, usize, usize);

/// A queued cell, `x << 20 | z << 9 | y`: areas up to 2,048 blocks wide.
type Packed = u32;

#[inline]
fn pack((x, y, z): Cell) -> Packed {
    ((x << 20) | (z << 9) | y) as Packed
}

#[inline]
fn unpack(cell: Packed) -> Cell {
    let cell = cell as usize;
    (cell >> 20, cell & 511, (cell >> 9) & 2047)
}

struct Slot {
    /// Sky then block layers, per section.
    layers: [Vec<Layer>; 2],
    /// The lowest sky source per column (`z << 4 | x`), `HEIGHT` for none.
    lowest: Box<[u16; 256]>,
    /// Sections whose light changed since `take_changes`, per kind.
    changed: [u32; 2],
    /// Sections the running operation wrote, per kind.
    touched: [u32; 2],
}

/// One operation's queues and its budget, and what it wrote.
struct Op {
    /// Increase queues per kind and level.
    queues: [Vec<Vec<Packed>>; 2],
    budget: usize,
    spent: usize,
    /// Sections written: `(slot, kind, section)`, each once.
    touched: Vec<(usize, usize, usize)>,
    /// For an update: the touched sections' layers before, the lowest sources
    /// it changed and the change masks before, to undo it or to tell which
    /// sections really changed (a decrease may restore what it cleared).
    undo: Option<Undo>,
}

#[derive(Default)]
struct Undo {
    layers: Vec<Layer>,
    lowest: Vec<(usize, usize, u16)>,
    changed: Vec<(usize, [u32; 2])>,
}

impl Op {
    fn new(budget: Option<usize>, undo: bool) -> Op {
        Op {
            queues: [vec![Vec::new(); 16], vec![Vec::new(); 16]],
            budget: budget.unwrap_or(usize::MAX),
            spent: 0,
            touched: Vec::new(),
            undo: undo.then(Undo::default),
        }
    }

    #[inline]
    fn push(&mut self, kind: usize, level: u8, cell: Cell) {
        if level > 1 {
            self.queues[kind][level as usize].push(pack(cell));
        }
    }

    #[inline]
    fn spend(&mut self, steps: usize) -> Result<(), TooLarge> {
        self.spent += steps;
        if self.spent > self.budget {
            Err(TooLarge)
        } else {
            Ok(())
        }
    }
}

pub struct LightGrid {
    nx: usize,
    nz: usize,
    slots: Vec<Option<Box<Slot>>>,
}

impl Default for LightGrid {
    fn default() -> Self {
        LightGrid::new(0, 0)
    }
}

impl LightGrid {
    /// An area of `nx` × `nz` unknown chunks.
    pub fn new(nx: usize, nz: usize) -> LightGrid {
        assert!(nx * 16 <= 2048 && nz * 16 <= 2048);
        LightGrid {
            nx,
            nz,
            slots: (0..nx * nz).map(|_| None).collect(),
        }
    }

    pub fn known(&self, cx: usize, cz: usize) -> bool {
        self.slots[cx * self.nz + cz].is_some()
    }

    /// A known chunk's layers of one kind, bottom up.
    pub fn layers(&self, kind: Kind, cx: usize, cz: usize) -> Option<&[Layer]> {
        let slot = self.slots[cx * self.nz + cz].as_ref()?;
        Some(&slot.layers[kind as usize])
    }

    #[inline]
    fn slot_of(&self, x: usize, z: usize) -> usize {
        (x >> 4) * self.nz + (z >> 4)
    }

    #[inline]
    pub fn get(&self, kind: Kind, (x, y, z): Cell) -> u8 {
        self.level(kind as usize, (x, y, z))
    }

    #[inline]
    fn level(&self, kind: usize, (x, y, z): Cell) -> u8 {
        match &self.slots[self.slot_of(x, z)] {
            Some(slot) => slot.layers[kind][y >> 4].get(index(x & 15, y & 15, z & 15)),
            None => 0,
        }
    }

    fn set(&mut self, op: &mut Op, kind: usize, (x, y, z): Cell, level: u8) {
        let si = self.slot_of(x, z);
        let s = y >> 4;
        let slot = self.slots[si]
            .as_mut()
            .expect("light set in an unknown chunk");
        let bit = 1u32 << s;
        if slot.touched[kind] & bit == 0 {
            if let Some(undo) = &mut op.undo {
                if slot.touched == [0, 0] {
                    undo.changed.push((si, slot.changed));
                }
                undo.layers.push(slot.layers[kind][s].clone());
            }
            slot.touched[kind] |= bit;
            op.touched.push((si, kind, s));
        }
        slot.changed[kind] |= bit;
        slot.layers[kind][s].set(index(x & 15, y & 15, z & 15), level);
    }

    /// The lowest sky source of column `(x, z)`, or `None` in an unknown chunk.
    #[inline]
    fn lowest_at(&self, x: usize, z: usize) -> Option<usize> {
        let slot = self.slots[self.slot_of(x, z)].as_ref()?;
        Some(slot.lowest[((z & 15) << 4) | (x & 15)] as usize)
    }

    /// The cell beside `(x, y, z)` in direction `d`, unless it is outside the
    /// area or in an unknown chunk.
    #[inline]
    fn neighbour(&self, (x, y, z): Cell, d: usize) -> Option<Cell> {
        let next = match d {
            0 if y > 0 => (x, y - 1, z),
            1 if y + 1 < HEIGHT => (x, y + 1, z),
            2 if z > 0 => (x, y, z - 1),
            3 if z + 1 < self.nz * 16 => (x, y, z + 1),
            4 if x > 0 => (x - 1, y, z),
            5 if x + 1 < self.nx * 16 => (x + 1, y, z),
            _ => return None,
        };
        if (next.0 >> 4 != x >> 4 || next.2 >> 4 != z >> 4)
            && self.slots[self.slot_of(next.0, next.2)].is_none()
        {
            return None;
        }
        Some(next)
    }

    /// Install chunks (area chunk coordinates), each with the light it was
    /// stored with or `None` to light it alone, then let light cross their
    /// faces. The chunks must be unknown and have blocks.
    pub fn install(
        &mut self,
        blocks: &Blocks,
        facts: &LightFacts,
        chunks: Vec<((usize, usize), Option<ChunkLight>)>,
    ) {
        // Installing only adds light: whatever it writes changed.
        let mut op = Op::new(None, false);
        let mut installed = Vec::with_capacity(chunks.len());
        for ((cx, cz), stored) in chunks {
            let si = cx * self.nz + cz;
            assert!(self.slots[si].is_none(), "chunk light installed twice");
            let sections = blocks.chunks[si].expect("an installed chunk has blocks");
            let mut lowest = Box::new([HEIGHT as u16; 256]);
            if blocks.sky {
                for (column, low) in lowest.iter_mut().enumerate() {
                    *low = lowest_source(sections, facts, column & 15, column >> 4) as u16;
                }
            }
            let stored = stored.filter(|l| l.sky.len() == SECTIONS && l.block.len() == SECTIONS);
            let fresh = stored.is_none();
            let layers = match stored {
                Some(light) => [light.sky, light.block],
                None => std::array::from_fn(|_| vec![Layer::Uniform(0); SECTIONS]),
            };
            self.slots[si] = Some(Box::new(Slot {
                layers,
                lowest,
                changed: [0, 0],
                touched: [0, 0],
            }));
            installed.push((cx, cz, fresh));
        }
        for &(cx, cz, fresh) in &installed {
            if fresh {
                self.seed_alone(blocks, facts, &mut op, cx, cz);
            }
        }
        for &(cx, cz, _) in &installed {
            self.seed_faces(&mut op, cx, cz);
        }
        let unbounded = self.increase(blocks, facts, &mut op);
        debug_assert!(unbounded.is_ok());
        for &(cx, cz, _) in &installed {
            let slot = self.slots[cx * self.nz + cz].as_mut().unwrap();
            slot.layers.iter_mut().flatten().for_each(Layer::compact);
        }
        self.finish(op, false);
    }

    /// Queue a fresh chunk's own light: sky at and above every column's lowest
    /// source (whole sections where they are open sky for every column), the
    /// sources beside a column whose sources start higher, and every emitter in
    /// sections whose palette may hold one.
    fn seed_alone(
        &mut self,
        blocks: &Blocks,
        facts: &LightFacts,
        op: &mut Op,
        cx: usize,
        cz: usize,
    ) {
        let si = cx * self.nz + cz;
        let sections = blocks.chunks[si].unwrap();
        let (ox, oz) = (cx * 16, cz * 16);
        if blocks.sky {
            let slot = self.slots[si].as_mut().unwrap();
            let open = (*slot.lowest.iter().max().unwrap() as usize).div_ceil(16);
            for layer in &mut slot.layers[0][open..] {
                *layer = Layer::Uniform(15);
            }
            for column in 0..256 {
                for y in slot.lowest[column] as usize..open * 16 {
                    slot.layers[0][y >> 4].set(index(column & 15, y & 15, column >> 4), 15);
                }
            }
            for column in 0..256 {
                let (x, z) = (ox + (column & 15), oz + (column >> 4));
                let low = self.slots[si].as_ref().unwrap().lowest[column] as usize;
                let mut top = low + 1;
                for d in 2..6 {
                    if let Some((a, _, c)) = self.neighbour((x, 0, z), d) {
                        top = top.max(self.lowest_at(a, c).unwrap());
                    }
                }
                for y in low..top.min(HEIGHT) {
                    op.push(0, 15, (x, y, z));
                }
            }
        }
        let slot = self.slots[si].as_mut().unwrap();
        for (s, section) in sections.iter().enumerate() {
            let may_emit = match section {
                Storage::Single(state) => facts.emission(*state) > 0,
                Storage::Indexed { palette, .. } => palette.iter().any(|&p| facts.emission(p) > 0),
                Storage::Dense(_) => true,
            };
            if may_emit {
                section.for_each(|i, state| {
                    let emission = facts.emission(state);
                    if emission > 0 {
                        slot.layers[1][s].set(i, emission);
                        op.push(
                            1,
                            emission,
                            (ox + (i & 15), s * 16 + (i >> 8), oz + ((i >> 4) & 15)),
                        );
                    }
                });
            }
        }
    }

    /// Queue the cells on either side of a chunk's faces with known neighbours
    /// that are at least two brighter than the cell across (light loses at
    /// least one per block).
    fn seed_faces(&self, op: &mut Op, cx: usize, cz: usize) {
        let Some(slot) = &self.slots[cx * self.nz + cz] else {
            return;
        };
        for (dx, dz) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
            let (ax, az) = (cx as i64 + dx, cz as i64 + dz);
            if ax < 0 || az < 0 || ax as usize >= self.nx || az as usize >= self.nz {
                continue;
            }
            let (ax, az) = (ax as usize, az as usize);
            let Some(other) = &self.slots[ax * self.nz + az] else {
                continue;
            };
            for kind in 0..2 {
                for s in 0..SECTIONS {
                    let (mine, theirs) = (&slot.layers[kind][s], &other.layers[kind][s]);
                    if let (Layer::Uniform(a), Layer::Uniform(b)) = (mine, theirs) {
                        if a.abs_diff(*b) <= 1 {
                            continue;
                        }
                    }
                    for y in 0..16 {
                        for t in 0..16 {
                            // This chunk's face cell, then the neighbour's across.
                            let (x0, z0, x1, z1) = match (dx, dz) {
                                (-1, 0) => (0, t, 15, t),
                                (1, 0) => (15, t, 0, t),
                                (0, -1) => (t, 0, t, 15),
                                _ => (t, 15, t, 0),
                            };
                            let a = mine.get(index(x0, y, z0));
                            let b = theirs.get(index(x1, y, z1));
                            if a > b + 1 {
                                op.push(kind, a, (cx * 16 + x0, s * 16 + y, cz * 16 + z0));
                            } else if b > a + 1 {
                                op.push(kind, b, (ax * 16 + x1, s * 16 + y, az * 16 + z1));
                            }
                        }
                    }
                }
            }
        }
    }

    /// Chunks (area chunk coordinates) whose light changed since the last call,
    /// with the sections that changed: sky bits, then block bits, bit `s` for
    /// section `s`.
    pub fn take_changes(&mut self) -> Vec<((usize, usize), u32, u32)> {
        let nz = self.nz;
        self.slots
            .iter_mut()
            .enumerate()
            .filter_map(|(si, slot)| {
                let [sky, block] = std::mem::take(&mut slot.as_mut()?.changed);
                (sky | block != 0).then_some(((si / nz, si % nz), sky, block))
            })
            .collect()
    }

    fn source(&self, kind: usize, blocks: &Blocks, facts: &LightFacts, cell: Cell) -> u8 {
        let (x, y, z) = cell;
        match kind {
            0 if y >= self.lowest_at(x, z).unwrap_or(HEIGHT) => 15,
            0 => 0,
            _ => facts.emission(blocks.state(x, y, z)),
        }
    }

    /// Bring light up to date after `changed` cells (area coordinates) got the
    /// states `blocks` now holds; cells of unknown chunks are ignored. With a
    /// budget of queue steps, an update that needs more is undone.
    pub fn update(
        &mut self,
        blocks: &Blocks,
        facts: &LightFacts,
        changed: &[Cell],
        budget: Option<usize>,
    ) -> Result<(), TooLarge> {
        let mut op = Op::new(budget, true);
        let result = self.relight(blocks, facts, changed, &mut op);
        self.finish(op, result.is_err());
        result
    }

    fn relight(
        &mut self,
        blocks: &Blocks,
        facts: &LightFacts,
        changed: &[Cell],
        op: &mut Op,
    ) -> Result<(), TooLarge> {
        let changed: Vec<Cell> = changed
            .iter()
            .copied()
            .filter(|&(x, y, z)| {
                x < self.nx * 16
                    && z < self.nz * 16
                    && y < HEIGHT
                    && self.slots[self.slot_of(x, z)].is_some()
            })
            .collect();
        let kinds = if blocks.sky { 0..2 } else { 1..2 };
        for kind in kinds {
            let mut seeds: Vec<(Cell, u8)> = Vec::new();
            if kind == 0 {
                let mut columns: Vec<(usize, usize)> =
                    changed.iter().map(|&(x, _, z)| (x, z)).collect();
                columns.sort_unstable();
                columns.dedup();
                for (x, z) in columns {
                    let si = self.slot_of(x, z);
                    let column = ((z & 15) << 4) | (x & 15);
                    let sections = blocks.chunks[si].expect("a known chunk has blocks");
                    let new = lowest_source(sections, facts, x & 15, z & 15);
                    let slot = self.slots[si].as_mut().unwrap();
                    let old = slot.lowest[column] as usize;
                    if old == new {
                        continue;
                    }
                    if let Some(undo) = &mut op.undo {
                        undo.lowest.push((si, column, old as u16));
                    }
                    slot.lowest[column] = new as u16;
                    op.spend(old.abs_diff(new))?;
                    // Cells that stopped being sources are cleared like changed cells.
                    for y in old..new {
                        seeds.push(((x, y, z), self.level(0, (x, y, z))));
                    }
                    for y in new..old {
                        self.set(op, 0, (x, y, z), 15);
                        op.push(0, 15, (x, y, z));
                    }
                }
            }
            for &cell in &changed {
                seeds.push((cell, self.level(kind, cell)));
            }
            let cleared = self.decrease(op, kind, seeds)?;
            // Sources in the cleared region, and light now able to enter the changed cells.
            for cell in cleared.into_iter().chain(changed.iter().copied()) {
                let source = self.source(kind, blocks, facts, cell);
                if source > self.level(kind, cell) {
                    self.set(op, kind, cell, source);
                    op.push(kind, source, cell);
                }
            }
            for &cell in &changed {
                for d in 0..6 {
                    if let Some(next) = self.neighbour(cell, d) {
                        let level = self.level(kind, next);
                        op.push(kind, level, next);
                    }
                }
            }
        }
        self.increase(blocks, facts, op)
    }

    /// Clear light that may have come from the seeds (cells with their former
    /// levels): neighbours dimmer than the light that reached them are cleared in
    /// turn, brighter ones are queued to spread again. Returns the cleared cells.
    fn decrease(
        &mut self,
        op: &mut Op,
        kind: usize,
        seeds: Vec<(Cell, u8)>,
    ) -> Result<Vec<Cell>, TooLarge> {
        let mut queue = std::collections::VecDeque::new();
        let mut cleared = Vec::new();
        for (cell, level) in seeds {
            if level > 0 {
                self.set(op, kind, cell, 0);
                cleared.push(cell);
                queue.push_back((cell, level));
            }
        }
        while let Some((cell, level)) = queue.pop_front() {
            op.spend(1)?;
            for d in 0..6 {
                let Some(next) = self.neighbour(cell, d) else {
                    continue;
                };
                let current = self.level(kind, next);
                if current == 0 {
                    continue;
                }
                if current < level {
                    self.set(op, kind, next, 0);
                    cleared.push(next);
                    queue.push_back((next, current));
                } else {
                    op.push(kind, current, next);
                }
            }
        }
        Ok(cleared)
    }

    fn increase(
        &mut self,
        blocks: &Blocks,
        facts: &LightFacts,
        op: &mut Op,
    ) -> Result<(), TooLarge> {
        for kind in 0..2 {
            for level in (2..=15u8).rev() {
                let mut queue = std::mem::take(&mut op.queues[kind][level as usize]);
                while let Some(packed) = queue.pop() {
                    op.spend(1)?;
                    let cell = unpack(packed);
                    if self.level(kind, cell) != level {
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
                            || self.level(kind, next) >= level - opacity
                            || facts.occludes(from, to, d)
                        {
                            continue;
                        }
                        let lit = level - opacity;
                        self.set(op, kind, next, lit);
                        op.push(kind, lit, next);
                    }
                }
            }
        }
        Ok(())
    }

    /// End an operation: undo what it wrote, or compact it and keep as changed
    /// only the sections that differ from before.
    fn finish(&mut self, mut op: Op, undo: bool) {
        let saved = op.undo.take();
        if let Some(saved) = &saved {
            let before: std::collections::HashMap<usize, [u32; 2]> =
                saved.changed.iter().copied().collect();
            for (&(si, kind, s), old) in op.touched.iter().zip(&saved.layers) {
                let slot = self.slots[si].as_mut().unwrap();
                if undo {
                    slot.layers[kind][s] = old.clone();
                } else if slot.layers[kind][s].same(old) && before[&si][kind] & 1 << s == 0 {
                    slot.changed[kind] &= !(1 << s);
                }
            }
        }
        if let (true, Some(saved)) = (undo, saved) {
            for (si, column, low) in saved.lowest.into_iter().rev() {
                self.slots[si].as_mut().unwrap().lowest[column] = low;
            }
            for (si, changed) in saved.changed {
                self.slots[si].as_mut().unwrap().changed = changed;
            }
        }
        for &(si, kind, s) in &op.touched {
            let slot = self.slots[si].as_mut().unwrap();
            slot.touched = [0, 0];
            if !undo {
                slot.layers[kind][s].compact();
            }
        }
    }
}

/// One chunk lit alone, its neighbours unknown: the light a chunk is stored
/// with, which installing it adopts.
pub fn light_alone(sections: &[Storage], facts: &LightFacts, sky: bool) -> ChunkLight {
    let mut grid = LightGrid::new(1, 1);
    let blocks = Blocks {
        nx: 1,
        nz: 1,
        chunks: vec![Some(sections)],
        sky,
    };
    grid.install(&blocks, facts, vec![((0, 0), None)]);
    let slot = grid.slots.pop().flatten().unwrap();
    let [sky, block] = slot.layers;
    ChunkLight { sky, block }
}

/// The lowest sky source of column `(x, z)` of a chunk (`ChunkSkyLightSources`):
/// one above the first edge from the top of the world that the sky facts block,
/// 0 when none does. Above the world is air.
fn lowest_source(sections: &[Storage], facts: &LightFacts, x: usize, z: usize) -> usize {
    let mut above = 0u16;
    for s in (0..SECTIONS).rev() {
        let section = &sections[s];
        if let Storage::Single(state) = *section {
            if facts.sky_blocked(above, state) {
                return s * 16 + 16;
            }
            if facts.sky_blocked(state, state) {
                return s * 16 + 15;
            }
            above = state;
            continue;
        }
        for y in (0..16).rev() {
            let state = section.get(index(x, y, z));
            if facts.sky_blocked(above, state) {
                return s * 16 + y + 1;
            }
            above = state;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::light::reference::{block_light, sky_light, Area};

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

    /// An area of chunks, dense for the reference and as sections for the grid.
    struct World {
        nx: usize,
        nz: usize,
        states: Vec<u16>,
        chunks: Vec<Vec<Storage>>,
        sky: bool,
    }

    impl World {
        fn new(nx: usize, nz: usize, f: impl Fn(usize, usize, usize) -> u16) -> World {
            let (wx, wz) = (nx * 16, nz * 16);
            let mut world = World {
                nx,
                nz,
                states: vec![0; wx * wz * HEIGHT],
                chunks: (0..nx * nz)
                    .map(|_| vec![Storage::Single(0); SECTIONS])
                    .collect(),
                sky: true,
            };
            for x in 0..wx {
                for z in 0..wz {
                    for y in 0..HEIGHT {
                        world.set((x, y, z), f(x, y, z));
                    }
                }
            }
            world
        }

        fn set(&mut self, (x, y, z): Cell, state: u16) {
            self.states[(x * self.nz * 16 + z) * HEIGHT + y] = state;
            self.chunks[(x >> 4) * self.nz + (z >> 4)][y >> 4]
                .set(index(x & 15, y & 15, z & 15), state);
        }

        fn blocks(&self) -> Blocks<'_> {
            Blocks {
                nx: self.nx,
                nz: self.nz,
                chunks: self.chunks.iter().map(|c| Some(&c[..])).collect(),
                sky: self.sky,
            }
        }

        /// The reference's light with every unknown chunk filled with stone,
        /// which light can neither enter nor leave.
        fn reference(&self, f: &LightFacts, grid: &LightGrid) -> (Vec<u8>, Vec<u8>) {
            let wz = self.nz * 16;
            let mut states = self.states.clone();
            for (i, state) in states.iter_mut().enumerate() {
                let (x, z) = ((i / HEIGHT) / wz, (i / HEIGHT) % wz);
                if !grid.known(x >> 4, z >> 4) {
                    *state = 1;
                }
            }
            let area = Area {
                wx: self.nx * 16,
                wz,
                states: &states,
            };
            let sky = if self.sky {
                sky_light(&area, f)
            } else {
                vec![0; states.len()]
            };
            (sky, block_light(&area, f))
        }

        fn install(&self, grid: &mut LightGrid, f: &LightFacts, chunks: &[(usize, usize, bool)]) {
            let list = chunks
                .iter()
                .map(|&(cx, cz, stored)| {
                    let alone =
                        stored.then(|| light_alone(&self.chunks[cx * self.nz + cz], f, self.sky));
                    ((cx, cz), alone)
                })
                .collect();
            grid.install(&self.blocks(), f, list);
        }

        fn update(
            &self,
            grid: &mut LightGrid,
            f: &LightFacts,
            cells: &[Cell],
            budget: Option<usize>,
        ) -> Result<(), TooLarge> {
            grid.update(&self.blocks(), f, cells, budget)
        }
    }

    fn assert_matches(grid: &LightGrid, world: &World, f: &LightFacts, context: &str) {
        let (sky, block) = world.reference(f, grid);
        let wz = world.nz * 16;
        for x in 0..world.nx * 16 {
            for z in 0..wz {
                if !grid.known(x >> 4, z >> 4) {
                    continue;
                }
                for y in 0..HEIGHT {
                    let i = (x * wz + z) * HEIGHT + y;
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

    /// Stone up to a varying surface with caves, torches and leaves, and
    /// glass, slabs and lamps above it.
    fn terrain(nx: usize, nz: usize, seed: u64) -> World {
        let mut seed = seed;
        let (wx, wz) = (nx * 16, nz * 16);
        let mut cells = vec![0u16; wx * wz * HEIGHT];
        for x in 0..wx {
            for z in 0..wz {
                let surface = 90 + (x * 7 + z * 3) % 20;
                for y in 0..HEIGHT {
                    let r = rng(&mut seed) % 100;
                    cells[(x * wz + z) * HEIGHT + y] = if y < surface {
                        if r < 70 {
                            1
                        } else if r < 72 {
                            2
                        } else if r < 75 {
                            4
                        } else {
                            0
                        }
                    } else if y < surface + 4 && r < 10 {
                        [3, 4, 5, 6][(r % 4) as usize]
                    } else {
                        0
                    };
                }
            }
        }
        World::new(nx, nz, |x, y, z| cells[(x * wz + z) * HEIGHT + y])
    }

    #[test]
    fn chunks_installed_in_any_order_equal_lighting_them_together() {
        let f = facts();
        let world = terrain(3, 3, 0x2545_F491_4F6C_DD1D);
        let mut order: Vec<(usize, usize)> =
            (0..3).flat_map(|x| (0..3).map(move |z| (x, z))).collect();
        let mut seed = 77u64;
        for i in (1..order.len()).rev() {
            order.swap(i, (rng(&mut seed) % (i as u64 + 1)) as usize);
        }
        let mut grid = LightGrid::new(3, 3);
        // One chunk alone, then the others one at a time (stored light or lit
        // fresh), then the last two together.
        for (n, &(cx, cz)) in order[..7].iter().enumerate() {
            world.install(&mut grid, &f, &[(cx, cz, n % 2 == 0)]);
            assert_matches(&grid, &world, &f, &format!("after installing {cx},{cz}"));
        }
        let rest: Vec<_> = order[7..].iter().map(|&(x, z)| (x, z, x == 1)).collect();
        world.install(&mut grid, &f, &rest);
        assert_matches(&grid, &world, &f, "with every chunk");
    }

    #[test]
    fn incremental_updates_equal_full_relights() {
        let f = facts();
        let mut world = terrain(3, 2, 0x9E37_79B9_7F4A_7C15);
        let mut grid = LightGrid::new(3, 2);
        // One chunk stays unknown: light neither enters nor leaves it.
        let known: Vec<_> = (0..3)
            .flat_map(|x| (0..2).map(move |z| (x, z, true)))
            .filter(|&(x, z, _)| (x, z) != (2, 1))
            .collect();
        world.install(&mut grid, &f, &known);
        grid.take_changes();
        let mut seed = 0xD1B5_4A32_D192_ED03u64;
        for round in 0..60 {
            let edits = 1 + (rng(&mut seed) % 4) as usize;
            let mut changed = Vec::new();
            for _ in 0..edits {
                let x = (rng(&mut seed) % 48) as usize;
                let z = (rng(&mut seed) % 32) as usize;
                let y = 80 + (rng(&mut seed) % 40) as usize;
                let state = (rng(&mut seed) % 7) as u16;
                world.set((x, y, z), state);
                changed.push((x, y, z));
            }
            world.update(&mut grid, &f, &changed, None).unwrap();
            assert_matches(
                &grid,
                &world,
                &f,
                &format!("after round {round}: {changed:?}"),
            );
        }
    }

    #[test]
    fn a_dimension_without_sky_has_only_block_light() {
        let f = facts();
        // A torch over a stone floor.
        let mut world = World::new(1, 1, |x, y, z| match (x, y, z) {
            (8, 61, 8) => 2,
            (_, 60, _) => 1,
            _ => 0,
        });
        world.sky = false;
        let mut grid = LightGrid::new(1, 1);
        world.install(&mut grid, &f, &[(0, 0, false)]);
        let sky_lit = |grid: &LightGrid| {
            (0..16)
                .any(|x| (0..16).any(|z| (0..HEIGHT).any(|y| grid.get(Kind::Sky, (x, y, z)) > 0)))
        };
        assert!(!sky_lit(&grid));
        assert_eq!(grid.get(Kind::Block, (8, 61, 8)), 14);
        assert_eq!(grid.get(Kind::Block, (8, 62, 10)), 11);
        // Opening the floor brings no sky light either.
        world.set((3, 60, 3), 0);
        world.update(&mut grid, &f, &[(3, 60, 3)], None).unwrap();
        assert!(!sky_lit(&grid));
        assert_eq!(
            light_alone(&world.chunks[0], &f, false).sky,
            vec![Layer::Uniform(0); SECTIONS]
        );
    }

    fn shaft() -> World {
        // Stone up to y 100 with a shaft at (8, 8) from y 20 up.
        World::new(1, 1, |x, y, z| {
            if y >= 100 || ((x, z) == (8, 8) && y >= 20) {
                0
            } else {
                1
            }
        })
    }

    #[test]
    fn opening_and_roofing_a_shaft_moves_sky_sources() {
        let f = facts();
        let mut world = shaft();
        let mut grid = LightGrid::new(1, 1);
        world.install(&mut grid, &f, &[(0, 0, false)]);
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 15);
        world.set((8, 99, 8), 1);
        world.update(&mut grid, &f, &[(8, 99, 8)], None).unwrap();
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 0);
        assert_matches(&grid, &world, &f, "roofed");
        world.set((8, 99, 8), 0);
        world.update(&mut grid, &f, &[(8, 99, 8)], None).unwrap();
        assert_eq!(grid.get(Kind::Sky, (8, 20, 8)), 15);
        assert_matches(&grid, &world, &f, "reopened");
    }

    #[test]
    fn an_update_past_its_budget_changes_nothing() {
        let f = facts();
        let mut world = shaft();
        world.set((8, 99, 8), 1);
        let mut grid = LightGrid::new(1, 1);
        world.install(&mut grid, &f, &[(0, 0, true)]);
        grid.take_changes();
        let before: Vec<Vec<Layer>> = [Kind::Sky, Kind::Block]
            .iter()
            .map(|&k| grid.layers(k, 0, 0).unwrap().to_vec())
            .collect();
        // Opening the roof lights 80 cells of the shaft and the cave they reach.
        world.set((8, 99, 8), 0);
        assert_eq!(
            world.update(&mut grid, &f, &[(8, 99, 8)], Some(40)),
            Err(TooLarge)
        );
        for (k, kind) in [Kind::Sky, Kind::Block].into_iter().enumerate() {
            assert_eq!(grid.layers(kind, 0, 0).unwrap(), &before[k][..]);
        }
        assert!(grid.take_changes().is_empty());
        world
            .update(&mut grid, &f, &[(8, 99, 8)], Some(100_000))
            .unwrap();
        assert_matches(&grid, &world, &f, "reopened within the budget");
    }

    #[test]
    fn changes_name_the_sections_whose_light_changed() {
        let f = facts();
        let mut world = World::new(2, 1, |_, y, _| if y < 64 { 1 } else { 0 });
        let mut grid = LightGrid::new(2, 1);
        world.install(&mut grid, &f, &[(0, 0, true), (1, 0, true)]);
        assert!(
            grid.take_changes().is_empty(),
            "flat terrain lights nothing across faces"
        );
        // A torch at the east face of chunk 0, 13 levels reaching y 87..113.
        world.set((15, 100, 8), 2);
        world.update(&mut grid, &f, &[(15, 100, 8)], None).unwrap();
        let sections = 1 << 5 | 1 << 6 | 1 << 7;
        assert_eq!(
            grid.take_changes(),
            vec![((0, 0), 0, sections), ((1, 0), 0, sections)]
        );
    }

    #[test]
    fn chunk_light_round_trips_and_refuses_other_bytes() {
        let f = facts();
        let light = light_alone(&terrain(1, 1, 5).chunks[0], &f, true);
        let mut bytes = Vec::new();
        light.write(&mut bytes);
        let mut input = &bytes[..];
        assert_eq!(ChunkLight::read(&mut input), Some(light));
        assert!(input.is_empty());
        assert_eq!(ChunkLight::read(&mut &bytes[..bytes.len() - 1]), None);
        bytes[0] = 3;
        assert_eq!(ChunkLight::read(&mut &bytes[..]), None);
    }
}
