//! Where the kernel reads block states: published chunk rows (a region's
//! durable snapshot, one section term per 16 blocks), which players and region
//! owners alike read, or supplied states (oracles). A cell that cannot be read
//! fails the query (`Unreadable`): movement into chunks that are not loaded or
//! not generated fails closed.

use super::table::{ShapeTable, LARGE, MOVING_PISTON};
use crate::column::{MIN_Y, SECTIONS};
use std::collections::HashMap;

/// The position a query could not read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unreadable(pub [i32; 3]);

pub trait BlockSource {
    /// The state at a position, or `None` where it cannot be read.
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16>;

    /// Whether the section holding a position may hold a large collision
    /// shape or a moving piston (true when unknown), so a scan may skip halo
    /// cells elsewhere (Moonrise's per-section special collider counts).
    fn special_near(&self, _x: i32, _y: i32, _z: i32) -> bool {
        true
    }
}

/// One published section: a uniform state, a palette with one byte per cell,
/// or big-endian states. Cells are `y << 8 | z << 4 | x`.
#[derive(Clone, Debug)]
pub enum Section<'a> {
    Uniform(u16),
    Paletted(Vec<u16>, &'a [u8]),
    Dense(&'a [u8]),
    /// Outside the heights a query decoded: unreadable.
    Unloaded,
}

impl Section<'_> {
    fn get(&self, index: usize) -> Option<u16> {
        match self {
            Section::Uniform(s) => Some(*s),
            Section::Paletted(palette, cells) => palette.get(*cells.get(index)? as usize).copied(),
            Section::Dense(cells) => {
                let b = cells.get(index * 2..index * 2 + 2)?;
                Some(u16::from_be_bytes([b[0], b[1]]))
            }
            Section::Unloaded => None,
        }
    }

    fn special(&self, table: &ShapeTable) -> bool {
        let any = |s: u16| table.special(s) & (LARGE | MOVING_PISTON) != 0;
        match self {
            Section::Uniform(s) => any(*s),
            Section::Paletted(palette, _) => palette.iter().any(|&s| any(s)),
            Section::Dense(_) | Section::Unloaded => true,
        }
    }
}

/// A chunk's published row: its sections bottom first, or `None` for an
/// untouched chunk of a flat world (the base profile).
pub type Row<'a> = Option<Vec<Section<'a>>>;

/// Published rows of the chunks a query may read.
pub struct Rows<'a> {
    chunks: HashMap<(i32, i32), (Row<'a>, Vec<bool>)>,
    /// The base profile, bottom first, for untouched chunks.
    base: Vec<u16>,
    /// The state outside the stored height.
    outside: u16,
}

impl<'a> Rows<'a> {
    pub fn new(base: Vec<u16>, outside: u16) -> Rows<'a> {
        Rows {
            chunks: HashMap::new(),
            base,
            outside,
        }
    }

    /// Add a chunk's row; `table` decides which sections hold special colliders.
    pub fn insert(&mut self, chunk: (i32, i32), row: Row<'a>, table: &ShapeTable) {
        let special = match &row {
            Some(sections) => sections.iter().map(|s| s.special(table)).collect(),
            None => {
                let base: Vec<bool> = (0..SECTIONS)
                    .map(|s| {
                        self.base[s * 16..(s * 16 + 16).min(self.base.len())]
                            .iter()
                            .any(|&b| table.special(b) & (LARGE | MOVING_PISTON) != 0)
                    })
                    .collect();
                base
            }
        };
        self.chunks.insert(chunk, (row, special));
    }

    pub fn contains(&self, chunk: (i32, i32)) -> bool {
        self.chunks.contains_key(&chunk)
    }
}

fn local(y: i32) -> Option<usize> {
    let local = y - MIN_Y;
    (0..(SECTIONS * 16) as i32)
        .contains(&local)
        .then_some(local as usize)
}

impl BlockSource for Rows<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        let (row, _) = self.chunks.get(&(x >> 4, z >> 4))?;
        let Some(local) = local(y) else {
            return Some(self.outside);
        };
        match row {
            None => self.base.get(local).copied(),
            Some(sections) => {
                let index = (local & 15) << 8 | ((z & 15) as usize) << 4 | (x & 15) as usize;
                sections.get(local >> 4)?.get(index)
            }
        }
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        match (self.chunks.get(&(x >> 4, z >> 4)), local(y)) {
            (Some((_, special)), Some(local)) => special.get(local >> 4).copied().unwrap_or(true),
            (Some(_), None) => false,
            // Unreadable: the scan reads it and fails.
            (None, _) => true,
        }
    }
}

/// Supplied states only (oracles and tests): other positions cannot be read.
pub struct States(pub HashMap<[i32; 3], u16>);

impl BlockSource for States {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.0.get(&[x, y, z]).copied()
    }
}
