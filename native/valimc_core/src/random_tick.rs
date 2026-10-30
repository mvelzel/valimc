//! Vanilla's random ticks over one region's columns (`ServerLevel.tickChunk`,
//! VMC-081g1).
//!
//! Each section keeps `LevelChunkSection`'s count of randomly ticking cells
//! (`recalcBlockCounts`, kept up to date as cells change), so a tick skips the
//! sections that cannot tick without looking at their cells. A ticking
//! section takes `randomTickSpeed` positions from the level's position
//! generator (`Level.getBlockRandomPos`: `randValue = randValue * 3 +
//! 1013904223`, its bits from `>> 2`), in vanilla's order: chunk by chunk,
//! sections bottom first. The block rules run the draws
//! (`rules::live::RandomPhase`).

use crate::column::SECTIONS;
use crate::section::Storage;

/// A drawn state the block rules tick (lava, growing plants).
pub const RULES: u8 = 1;
/// A drawn state the owner ticks itself (its tick behaviours).
pub const OWNER: u8 = 2;

/// The region's random tick state: which states tick, which the owner
/// handles, every section's count and the position generator.
#[derive(Clone, Debug)]
pub struct RandomTicks {
    /// `BlockState.isRandomlyTicking` by state id (the counted states).
    ticking: Vec<bool>,
    /// Who ticks a drawn state (`RULES`, `OWNER`); 0: nobody, the draw
    /// does nothing.
    handled: Vec<u8>,
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

    /// Who ticks `state` when it is drawn: `RULES`, `OWNER` or 0.
    #[inline]
    pub fn handled(&self, state: u16) -> u8 {
        self.handled.get(state as usize).copied().unwrap_or(0)
    }

    /// Install the ticking states and those the rules and the owner tick (the
    /// owner's first); the caller recounts every section (`recount`). A
    /// handled state always counts.
    pub fn set_states(&mut self, ticking: &[bool], rules: &[bool], owner: &[bool]) {
        let n = ticking.len().max(rules.len()).max(owner.len());
        let at = |bits: &[bool], s: usize| bits.get(s).copied().unwrap_or(false);
        self.handled = (0..n)
            .map(|s| {
                if at(owner, s) {
                    OWNER
                } else if at(rules, s) {
                    RULES
                } else {
                    0
                }
            })
            .collect();
        self.ticking = (0..n)
            .map(|s| at(ticking, s) || self.handled[s] != 0)
            .collect();
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

    /// The generator's state, to roll a run's draws back (`set_generator`).
    pub fn generator(&self) -> i32 {
        self.rand_value
    }

    pub fn set_generator(&mut self, value: i32) {
        self.rand_value = value;
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
        ticks.set_states(&[false, true], &[], &[]);
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
