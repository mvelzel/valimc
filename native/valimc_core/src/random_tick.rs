//! Vanilla's random ticks over one region's columns (`ServerLevel.tickChunk`,
//! VMC-081g1).
//!
//! Each section keeps `LevelChunkSection`'s count of randomly ticking cells
//! (`recalcBlockCounts`, kept up to date as cells change), so a tick skips the
//! sections that cannot tick without looking at their cells. A ticking
//! section takes `randomTickSpeed` positions from the level's position
//! generator (`Level.getBlockRandomPos`: `randValue = randValue * 3 +
//! 1013904223`, its bits from `>> 2`), in vanilla's order: chunk by chunk,
//! sections bottom first.

use crate::column::SECTIONS;
use crate::section::{index, Storage};

/// The region's random tick state: which states tick, which the owner
/// handles, every section's count and the position generator.
#[derive(Clone, Debug)]
pub struct RandomTicks {
    /// `BlockState.isRandomlyTicking` by state id (the counted states).
    ticking: Vec<bool>,
    /// The states whose ticks the owner runs; a draw at any other state
    /// does nothing.
    handled: Vec<bool>,
    /// Ticking cells per section, per local chunk `z * size + x`.
    counts: Vec<[u16; SECTIONS]>,
    /// `Level.randValue`.
    rand_value: i32,
}

impl RandomTicks {
    pub fn new(chunks: usize, seed: i32) -> Self {
        Self {
            ticking: Vec::new(),
            handled: Vec::new(),
            counts: vec![[0; SECTIONS]; chunks],
            rand_value: seed,
        }
    }

    #[inline]
    pub fn ticks(&self, state: u16) -> bool {
        self.ticking.get(state as usize).copied().unwrap_or(false)
    }

    #[inline]
    pub fn handled(&self, state: u16) -> bool {
        self.handled.get(state as usize).copied().unwrap_or(false)
    }

    /// Install the ticking and handled states; the caller recounts every
    /// section (`recount`). A handled state always counts.
    pub fn set_states(&mut self, ticking: Vec<bool>, handled: Vec<bool>) {
        let n = ticking.len().max(handled.len());
        self.ticking = (0..n)
            .map(|s| {
                ticking.get(s).copied().unwrap_or(false) || handled.get(s).copied().unwrap_or(false)
            })
            .collect();
        self.handled = handled;
    }

    /// `recalcBlockCounts` for one chunk's sections.
    pub fn recount<'a>(&mut self, chunk: usize, sections: impl Iterator<Item = &'a Storage>) {
        let mut counts = [0; SECTIONS];
        for (count, storage) in counts.iter_mut().zip(sections) {
            *count = self.count(storage);
        }
        self.counts[chunk] = counts;
    }

    /// A cell of chunk `chunk`'s section `section` went from `old` to `new`.
    #[inline]
    pub fn changed(&mut self, chunk: usize, section: usize, old: u16, new: u16) {
        match (self.ticks(old), self.ticks(new)) {
            (false, true) => self.counts[chunk][section] += 1,
            (true, false) => self.counts[chunk][section] -= 1,
            _ => {}
        }
    }

    pub fn counts(&self, chunk: usize) -> &[u16; SECTIONS] {
        &self.counts[chunk]
    }

    fn count(&self, storage: &Storage) -> u16 {
        match storage {
            Storage::Single(state) => {
                if self.ticks(*state) {
                    crate::section::VOLUME as u16
                } else {
                    0
                }
            }
            Storage::Indexed { palette, cells } => {
                let mut table = [0u16; 256];
                let mut any = false;
                for (slot, &state) in palette.iter().enumerate() {
                    if self.ticks(state) {
                        table[slot] = 1;
                        any = true;
                    }
                }
                if any {
                    cells.iter().map(|&c| table[c as usize]).sum()
                } else {
                    0
                }
            }
            Storage::Dense(cells) => cells.iter().filter(|&&s| self.ticks(s)).count() as u16,
        }
    }

    /// `Level.getBlockRandomPos` with mask 15: a section-relative `(x, y, z)`.
    #[inline]
    pub fn next_position(&mut self) -> (usize, usize, usize) {
        self.rand_value = self.rand_value.wrapping_mul(3).wrapping_add(1_013_904_223);
        let val = self.rand_value >> 2;
        (
            (val & 15) as usize,
            ((val >> 16) & 15) as usize,
            ((val >> 8) & 15) as usize,
        )
    }

    /// One chunk's random ticks (`tickChunk`'s block part): `per_section`
    /// draws in each section that counts ticking cells, bottom first; the
    /// handled states drawn go to `hit(section, x, y, z, state)`.
    pub fn tick_chunk(
        &mut self,
        chunk: usize,
        sections: &[std::sync::Arc<Storage>],
        per_section: u32,
        mut hit: impl FnMut(usize, usize, usize, usize, u16),
    ) {
        let counts = self.counts[chunk];
        for (s, &count) in counts.iter().enumerate() {
            if count == 0 {
                continue;
            }
            let storage = &*sections[s];
            for _ in 0..per_section {
                let (x, y, z) = self.next_position();
                let state = storage.get(index(x, y, z));
                if self.handled(state) {
                    hit(s, x, y, z, state);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positions_follow_the_level_generator() {
        // randValue 0: 1013904223 >> 2 = 0x0F1BBCD7.
        let mut ticks = RandomTicks::new(1, 0);
        assert_eq!(ticks.next_position(), (7, 11, 12));
        // Then 3 * 1013904223 + 1013904223 wraps: 4055616892 as i32 is negative,
        // and `>>` is arithmetic.
        let value = 1_013_904_223i32.wrapping_mul(4);
        let val = value >> 2;
        assert!(val < 0);
        assert_eq!(
            ticks.next_position(),
            (
                (val & 15) as usize,
                ((val >> 16) & 15) as usize,
                ((val >> 8) & 15) as usize
            )
        );
    }

    #[test]
    fn counts_follow_cell_changes() {
        let mut ticks = RandomTicks::new(1, 0);
        ticks.set_states(vec![false, true], vec![]);
        let mut storage = Storage::Single(0);
        storage.set(5, 1);
        storage.set(9, 1);
        ticks.recount(0, std::iter::once(&storage));
        assert_eq!(ticks.counts(0)[0], 2);
        ticks.changed(0, 0, 1, 0);
        ticks.changed(0, 0, 0, 0);
        assert_eq!(ticks.counts(0)[0], 1);
        ticks.recount(0, std::iter::once(&Storage::Single(1)));
        assert_eq!(ticks.counts(0)[0], 4096);
    }
}
