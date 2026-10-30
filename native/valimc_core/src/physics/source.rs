//! Where the kernel reads block states: published chunk snapshots (a region's
//! durable blocks, VMC-077p), which players and region owners alike read,
//! borrowed for the query, or supplied states (oracles). A cell that cannot be
//! read fails the query (`Unreadable`): movement into chunks that are not
//! loaded or not generated fails closed, except a spectator's
//! (`AirWhereUnreadable`).

use super::table::{ShapeTable, LARGE, MOVING_PISTON};
use crate::column::{MIN_Y, SECTIONS};
use crate::piston::Moving;
use crate::section::Storage;
use crate::snapshot::ChunkSnapshot;
use std::collections::HashMap;
use std::ops::{Deref, RangeInclusive};

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

    /// The moving block at a position holding a moving piston (VMC-048b),
    /// `None` where it has no block entity.
    fn moving(&self, _x: i32, _y: i32, _z: i32) -> Option<Moving> {
        None
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
/// `S` holds a snapshot: borrowed for one query, or shared by a kernel
/// resource for a whole tick (VMC-043e).
pub struct Rows<S> {
    /// Per chunk its snapshot and which sections may hold special colliders.
    chunks: HashMap<(i32, i32), (S, [bool; SECTIONS])>,
    /// The state outside the stored height.
    outside: u16,
}

impl<S: Deref<Target = ChunkSnapshot>> Rows<S> {
    pub fn new(outside: u16) -> Rows<S> {
        Rows {
            chunks: HashMap::new(),
            outside,
        }
    }

    /// Add a chunk's snapshot; `table` decides which of the sections `near`
    /// (those the query reaches) hold special colliders, others count as if
    /// they might.
    pub fn insert(&mut self, snapshot: S, near: RangeInclusive<usize>, table: &ShapeTable) {
        let special =
            std::array::from_fn(|s| !near.contains(&s) || special(&snapshot.sections[s], table));
        self.chunks.insert(snapshot.chunk, (snapshot, special));
    }

    pub fn contains(&self, chunk: (i32, i32)) -> bool {
        self.chunks.contains_key(&chunk)
    }

    /// The snapshot of a chunk (its column and biomes, VMC-081d's rain).
    pub fn snapshot(&self, chunk: (i32, i32)) -> Option<&S> {
        self.chunks.get(&chunk).map(|(s, _)| s)
    }
}

fn local(y: i32) -> Option<usize> {
    let local = y - MIN_Y;
    (0..(SECTIONS * 16) as i32)
        .contains(&local)
        .then_some(local as usize)
}

impl<S: Deref<Target = ChunkSnapshot>> BlockSource for Rows<S> {
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

    fn moving(&self, x: i32, y: i32, z: i32) -> Option<Moving> {
        self.chunks.get(&(x >> 4, z >> 4))?.0.moving(x, y, z)
    }
}

/// Air's block state (vanilla's first).
pub const AIR: u16 = 0;

/// A source whose unreadable cells read as air: a spectator's (VMC-077v).
/// Vanilla's spectator has no physics, its collisions skip chunks that are
/// not loaded and its fluid contact skips them too, so a spectator flies
/// into chunks generation has not reached.
pub struct AirWhereUnreadable<'a>(pub &'a dyn BlockSource);

impl BlockSource for AirWhereUnreadable<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        Some(self.0.state(x, y, z).unwrap_or(AIR))
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        self.0.special_near(x, y, z)
    }

    fn moving(&self, x: i32, y: i32, z: i32) -> Option<Moving> {
        self.0.moving(x, y, z)
    }
}

/// Supplied states only (oracles and tests): other positions cannot be read.
pub struct States(pub HashMap<[i32; 3], u16>);

impl BlockSource for States {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.0.get(&[x, y, z]).copied()
    }
}

/// Supplied states with moving blocks (oracles and tests).
pub struct MovingStates<'a> {
    pub states: &'a dyn BlockSource,
    pub moving: HashMap<[i32; 3], Moving>,
}

impl BlockSource for MovingStates<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        self.states.state(x, y, z)
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        self.states.special_near(x, y, z)
    }

    fn moving(&self, x: i32, y: i32, z: i32) -> Option<Moving> {
        self.moving.get(&[x, y, z]).copied()
    }
}
