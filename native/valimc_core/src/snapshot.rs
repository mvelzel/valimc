//! Published chunk snapshots (VMC-077p): what readers outside a region's
//! owner (physics, rain, portals, spawn search) read of a chunk. A snapshot
//! shares its sections and biomes with the owner's column: taking one copies
//! 24 pointers, and a later write in the store clones only the section it
//! writes (`Column::set`), so a snapshot never changes under its readers and
//! holds memory of its own only for sections written since. Each section
//! keeps the revision of the publication that last changed it.

use crate::column::{self, Column, HEIGHT, MIN_Y, SECTIONS};
use crate::flags::{BlockFlags, MOTION_BLOCKING};
use crate::light::LightFacts;
use crate::piston::Moving;
use crate::section::{index, Biomes, Storage};
use std::collections::HashSet;
use std::sync::Arc;

pub struct ChunkSnapshot {
    pub chunk: (i32, i32),
    /// The revision of the publication.
    pub revision: u64,
    /// Bottom first.
    pub sections: Vec<Arc<Storage>>,
    /// Per section, the revision of the publication that last changed it.
    pub revisions: [u64; SECTIONS],
    /// Per-section biomes; `None` uses the region's default biome.
    pub biomes: Option<Arc<Vec<Biomes>>>,
    /// The chunk's moving blocks (VMC-048b), shared with the store.
    pub pistons: Option<crate::piston::ChunkPistons>,
}

impl ChunkSnapshot {
    /// `column` published at `revision`, after `previous` (the chunk's last
    /// publication): sections it still shares keep their revisions.
    pub fn new(
        chunk: (i32, i32),
        column: &Column,
        revision: u64,
        previous: Option<&ChunkSnapshot>,
    ) -> ChunkSnapshot {
        let revisions = std::array::from_fn(|s| match previous {
            Some(p) if p.chunk == chunk && Arc::ptr_eq(&p.sections[s], &column.sections[s]) => {
                p.revisions[s]
            }
            _ => revision,
        });
        ChunkSnapshot {
            chunk,
            revision,
            sections: column.sections.clone(),
            revisions,
            biomes: column.biomes.clone(),
            pistons: None,
        }
    }

    /// The moving block at a position of the chunk (VMC-048b).
    pub fn moving(&self, x: i32, y: i32, z: i32) -> Option<Moving> {
        self.pistons
            .as_ref()?
            .iter()
            .find(|(p, _)| *p == [x, y, z])
            .map(|&(_, m)| m)
    }

    /// The state at a position of the chunk (x and z modulo 16), `None` outside
    /// the stored height.
    #[inline]
    pub fn get(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        let local = y - MIN_Y;
        if !(0..HEIGHT as i32).contains(&local) {
            return None;
        }
        let local = local as usize;
        let i = index((x & 15) as usize, local & 15, (z & 15) as usize);
        Some(self.sections[local >> 4].get(i))
    }

    /// Column `(x, z)`'s MOTION_BLOCKING height (one above its top
    /// motion-blocking state) and lowest sky source, MIN_Y when it has none.
    pub fn column(&self, x: i32, z: i32, flags: &BlockFlags, light: &LightFacts) -> (i32, i32) {
        let (x, z) = ((x & 15) as usize, (z & 15) as usize);
        let motion = column::height(&self.sections, x, z, flags, MOTION_BLOCKING);
        let sky = column::sky_source(&self.sections, x, z, light);
        (MIN_Y + motion as i32, MIN_Y + sky as i32)
    }

    /// The stored biome of a quart (y clamped to the column), `None` for a
    /// column without biomes.
    pub fn biome(&self, quart: (i32, i32, i32)) -> Option<u16> {
        self.biomes.as_ref().map(|b| column::quart_biome(b, quart))
    }

    /// The blocks whose state is in `states`.
    pub fn find(&self, states: &[u16]) -> Vec<(i32, i32, i32, u16)> {
        column::find(&self.sections, self.chunk, states)
    }

    /// The highest section below `below` with a cell whose state is not
    /// `empty` (`getHighestFilledSectionIndex` with air), `None` when there
    /// is none.
    pub fn highest_filled(&self, below: usize, empty: impl Fn(u16) -> bool) -> Option<usize> {
        let below = below.min(self.sections.len());
        (0..below).rev().find(|&s| match &*self.sections[s] {
            Storage::Single(state) => !empty(*state),
            Storage::Indexed { palette, .. } if palette.iter().all(|&p| empty(p)) => false,
            storage => {
                let mut filled = false;
                storage.for_each(|_, state| filled |= !empty(state));
                filled
            }
        })
    }
}

/// Bytes held by distinct sections and biomes among `columns` and
/// `snapshots`, a shared one counted once, plus the snapshots' own records:
/// the resident block memory of a store and its publications.
pub fn resident_bytes<'a>(
    columns: impl Iterator<Item = &'a Column>,
    snapshots: impl Iterator<Item = &'a ChunkSnapshot>,
) -> usize {
    let mut seen: HashSet<*const ()> = HashSet::new();
    let mut total = 0;
    let mut add = |sections: &'a [Arc<Storage>], biomes: &'a Option<Arc<Vec<Biomes>>>| {
        for s in sections {
            if seen.insert(Arc::as_ptr(s) as *const ()) {
                total += s.heap_bytes();
            }
        }
        if let Some(b) = biomes {
            if seen.insert(Arc::as_ptr(b) as *const ()) {
                total += b.iter().map(Biomes::heap_bytes).sum::<usize>();
            }
        }
    };
    let mut records = 0;
    for c in columns {
        add(&c.sections, &c.biomes);
    }
    for s in snapshots {
        add(&s.sections, &s.biomes);
        records += std::mem::size_of::<ChunkSnapshot>() + s.sections.len() * 8;
    }
    total + records
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layers() -> Box<[u16; HEIGHT]> {
        let mut layers = Box::new([0u16; HEIGHT]);
        for y in 0..64 {
            layers[y] = 1;
        }
        layers
    }

    #[test]
    fn a_write_after_publishing_clones_only_its_section() {
        let mut column = Column::from_layers(&layers());
        column.set(3, 10, 4, 7);
        let first = ChunkSnapshot::new((0, 0), &column, 1, None);
        assert!(first.revisions.iter().all(|&r| r == 1));
        // A write clones the shared section; the snapshot keeps the old state.
        column.set(3, 10, 4, 9);
        column.set(5, 100, 5, 2);
        assert_eq!(first.get(3, 10, 4), Some(7));
        assert_eq!(first.get(5, 100, 5), Some(0));
        let s10 = ((10 - MIN_Y) >> 4) as usize;
        let s100 = ((100 - MIN_Y) >> 4) as usize;
        for s in 0..SECTIONS {
            assert_eq!(
                Arc::ptr_eq(&first.sections[s], &column.sections[s]),
                s != s10 && s != s100
            );
        }
        let second = ChunkSnapshot::new((0, 0), &column, 2, Some(&first));
        assert_eq!(second.get(3, 10, 4), Some(9));
        for s in 0..SECTIONS {
            let changed = s == s10 || s == s100;
            assert_eq!(second.revisions[s], if changed { 2 } else { 1 });
        }
        // Unchanged states write nothing.
        column.set(3, 10, 4, 9);
        assert!(Arc::ptr_eq(&second.sections[s10], &column.sections[s10]));
        // Shared sections count once.
        let alone = resident_bytes(std::iter::once(&column), std::iter::empty());
        let both = resident_bytes(std::iter::once(&column), [&first, &second].into_iter());
        let records = 2 * (std::mem::size_of::<ChunkSnapshot>() + SECTIONS * 8);
        assert_eq!(
            both - records - alone,
            first.sections[s10].heap_bytes() + first.sections[s100].heap_bytes()
        );
    }

    #[test]
    fn reads_answer_as_the_column_does() {
        let mut column = Column::from_layers(&layers());
        column.set(1, 200, 2, 5);
        let snap = ChunkSnapshot::new((2, -3), &column, 4, None);
        assert_eq!(snap.get(33, 200, -46), Some(5));
        assert_eq!(snap.get(0, MIN_Y - 1, 0), None);
        assert_eq!(snap.get(0, MIN_Y + HEIGHT as i32, 0), None);
        assert_eq!(snap.find(&[5]), vec![(33, 200, -46, 5)]);
        let top = ((200 - MIN_Y) >> 4) as usize;
        assert_eq!(snap.highest_filled(SECTIONS, |s| s == 0), Some(top));
        assert_eq!(snap.highest_filled(top, |s| s == 0), Some(3));
        assert_eq!(
            snap.highest_filled(SECTIONS, |s| [0, 1, 5].contains(&s)),
            None
        );
        assert_eq!(snap.biome((0, 0, 0)), None);
    }
}
