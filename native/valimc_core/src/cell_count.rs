//! Counts of a region's cells by class of state (VMC-081j), kept up to date
//! as cells change the way random ticks' section counts are: the redstone
//! contact blocks (plates, buttons, tripwire) and the portal blocks. A
//! region with none of a class skips the work that only that class can
//! start (entities' contacts, a mob's portal sweep) without reading a cell.

use crate::section::Storage;

/// Plates, weighted plates, buttons and tripwire: what an entity standing
/// in them reaches (`entityInside`).
pub const CONTACT: usize = 0;
/// Nether portals, end portals and end gateways.
pub const PORTAL: usize = 1;
const CLASSES: usize = 2;

/// The region's counted states and its cells of each class, chunk by chunk.
#[derive(Clone, Debug)]
pub struct CellCounts {
    /// Class bits by state id.
    classes: Vec<u8>,
    /// Cells of each class per local chunk `z * size + x`.
    chunks: Vec<[u32; CLASSES]>,
    /// The region's cells of each class.
    totals: [u64; CLASSES],
}

impl CellCounts {
    pub fn new(chunks: usize) -> Self {
        Self {
            classes: Vec::new(),
            chunks: vec![[0; CLASSES]; chunks],
            totals: [0; CLASSES],
        }
    }

    /// Install the states of each class (`by_class[class][state]`); the
    /// caller recounts every chunk (`recount`).
    pub fn set_states(&mut self, by_class: [&[bool]; CLASSES]) {
        let n = by_class.iter().map(|b| b.len()).max().unwrap_or(0);
        self.classes = (0..n)
            .map(|s| {
                by_class
                    .iter()
                    .enumerate()
                    .filter(|(_, bits)| bits.get(s).copied().unwrap_or(false))
                    .fold(0u8, |acc, (class, _)| acc | 1 << class)
            })
            .collect();
    }

    #[inline]
    fn class_of(&self, state: u16) -> u8 {
        self.classes.get(state as usize).copied().unwrap_or(0)
    }

    /// Chunk `chunk`'s cells counted again from its sections.
    pub fn recount<'a>(&mut self, chunk: usize, sections: impl Iterator<Item = &'a Storage>) {
        let mut counts = [0u32; CLASSES];
        if !self.classes.is_empty() {
            for storage in sections {
                self.count(storage, &mut counts);
            }
        }
        for (class, &n) in counts.iter().enumerate() {
            self.totals[class] = self.totals[class] - self.chunks[chunk][class] as u64 + n as u64;
        }
        self.chunks[chunk] = counts;
    }

    /// A cell of chunk `chunk` went from `old` to `new`.
    #[inline]
    pub fn changed(&mut self, chunk: usize, old: u16, new: u16) {
        let (was, is) = (self.class_of(old), self.class_of(new));
        if was == is {
            return;
        }
        for class in 0..CLASSES {
            let bit = 1 << class;
            match (was & bit != 0, is & bit != 0) {
                (false, true) => {
                    self.chunks[chunk][class] += 1;
                    self.totals[class] += 1;
                }
                (true, false) => {
                    self.chunks[chunk][class] -= 1;
                    self.totals[class] -= 1;
                }
                _ => {}
            }
        }
    }

    /// The region's cells of `class`.
    pub fn total(&self, class: usize) -> u64 {
        self.totals[class]
    }

    /// Whether the region may hold a cell of `class`: it does, or its
    /// states were never installed (a scene's region).
    pub fn may_hold(&self, class: usize) -> bool {
        self.classes.is_empty() || self.totals[class] > 0
    }

    /// Whether the states were installed (a scene's region has none, and
    /// may hold any cell).
    pub fn installed(&self) -> bool {
        !self.classes.is_empty()
    }

    /// The local chunks (`z * size + x`) holding a cell of `class`.
    pub fn chunks_with(&self, class: usize) -> impl Iterator<Item = usize> + '_ {
        self.chunks
            .iter()
            .enumerate()
            .filter(move |(_, counts)| counts[class] > 0)
            .map(|(i, _)| i)
    }

    fn count(&self, storage: &Storage, counts: &mut [u32; CLASSES]) {
        let mut add = |class: u8, n: u32| {
            for (c, count) in counts.iter_mut().enumerate() {
                if class & (1 << c) != 0 {
                    *count += n;
                }
            }
        };
        match storage {
            Storage::Single(state) => add(self.class_of(*state), crate::section::VOLUME as u32),
            Storage::Indexed { palette, cells } => {
                let classes: Vec<u8> = palette.iter().map(|&s| self.class_of(s)).collect();
                if classes.iter().any(|&c| c != 0) {
                    for &cell in cells.iter() {
                        add(classes[cell as usize], 1);
                    }
                }
            }
            Storage::Dense(cells) => {
                for &state in cells.iter() {
                    add(self.class_of(state), 1);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_follow_cell_changes_by_class() {
        let mut counts = CellCounts::new(2);
        // State 1 a contact block, 2 a portal.
        counts.set_states([&[false, true], &[false, false, true]]);
        let mut storage = Storage::Single(0);
        storage.set(5, 1);
        storage.set(9, 1);
        storage.set(10, 2);
        counts.recount(0, std::iter::once(&storage));
        counts.recount(1, std::iter::once(&Storage::Single(2)));
        assert_eq!(counts.total(CONTACT), 2);
        assert_eq!(counts.total(PORTAL), 1 + 4096);
        counts.changed(0, 1, 0);
        counts.changed(0, 0, 0);
        counts.changed(1, 2, 1);
        assert_eq!(counts.total(CONTACT), 2);
        assert_eq!(counts.total(PORTAL), 4096);
        // A recount replaces the chunk's share.
        counts.recount(1, std::iter::once(&Storage::Single(0)));
        assert_eq!(counts.total(CONTACT), 1);
        assert_eq!(counts.total(PORTAL), 1);
        assert!(counts.may_hold(PORTAL));
        counts.changed(0, 2, 0);
        assert!(!counts.may_hold(PORTAL));
        assert!(CellCounts::new(1).may_hold(PORTAL));
        assert_eq!(counts.chunks_with(CONTACT).collect::<Vec<_>>(), [0]);
        assert_eq!(counts.chunks_with(PORTAL).count(), 0);
    }
}
