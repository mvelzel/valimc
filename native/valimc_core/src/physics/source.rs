//! Where the kernel reads block states: published chunk snapshots (a region's
//! durable blocks, VMC-077p), which players and region owners alike read,
//! borrowed for the query, or supplied states (oracles). A cell that cannot be
//! read fails the query (`Unreadable`): movement into chunks that are not
//! loaded or not generated fails closed.

use super::table::{ShapeTable, LARGE, MOVING_PISTON};
use crate::column::{MIN_Y, SECTIONS};
use crate::section::Storage;
use crate::snapshot::ChunkSnapshot;
use std::collections::HashMap;
use std::ops::RangeInclusive;

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

fn special(storage: &Storage, table: &ShapeTable) -> bool {
    let any = |s: u16| table.special(s) & (LARGE | MOVING_PISTON) != 0;
    match storage {
        Storage::Single(s) => any(*s),
        Storage::Indexed { palette, .. } => palette.iter().any(|&s| any(s)),
        Storage::Dense(_) => true,
    }
}

/// Published snapshots of the chunks a query may read.
pub struct Rows<'a> {
    /// Per chunk its snapshot and which sections may hold special colliders.
    chunks: HashMap<(i32, i32), (&'a ChunkSnapshot, [bool; SECTIONS])>,
    /// The state outside the stored height.
    outside: u16,
}

impl<'a> Rows<'a> {
    pub fn new(outside: u16) -> Rows<'a> {
        Rows {
            chunks: HashMap::new(),
            outside,
        }
    }

    /// Add a chunk's snapshot; `table` decides which of the sections `near`
    /// (those the query reaches) hold special colliders, others count as if
    /// they might.
    pub fn insert(
        &mut self,
        snapshot: &'a ChunkSnapshot,
        near: RangeInclusive<usize>,
        table: &ShapeTable,
    ) {
        let special =
            std::array::from_fn(|s| !near.contains(&s) || special(&snapshot.sections[s], table));
        self.chunks.insert(snapshot.chunk, (snapshot, special));
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
    #[inline]
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        let (snapshot, _) = self.chunks.get(&(x >> 4, z >> 4))?;
        Some(snapshot.get(x, y, z).unwrap_or(self.outside))
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        match (self.chunks.get(&(x >> 4, z >> 4)), local(y)) {
            (Some((_, special)), Some(local)) => special[local >> 4],
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
