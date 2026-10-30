//! A mob section's resident spawn census (VMC-081g2): what each of its mobs
//! counts as toward natural spawning's caps (`NaturalSpawner.createState`),
//! and per chunk how many mobs of each category count.
//!
//! The section notes every mob that may have changed (any mutable access,
//! an insertion, a removal, a chunk change), and the spawn pass refreshes
//! only those before it reads the counts, so a tick costs what changed, not
//! every loaded mob. Noted ids are bounded: past a limit the census forgets
//! them and is rebuilt whole at its next refresh.

use std::collections::{BTreeMap, HashMap};
use std::hash::{BuildHasherDefault, Hasher};

/// What a mob counts as: its entity type, its category's index when it
/// counts toward the caps (not persistent, a spawning category), its
/// chunk, whether it is persistent (or from a bucket) and whether its type
/// can come from a bucket at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Counted {
    pub kind: u16,
    pub category: Option<u8>,
    pub chunk: (i32, i32),
    pub persistent: bool,
    pub bucketable: bool,
}

/// A hasher for network ids (sequential integers).
#[derive(Default)]
pub struct IdHasher(u64);

impl Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(8) ^ b as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }

    fn write_i32(&mut self, v: i32) {
        self.0 = (v as u32 as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    }
}

#[derive(Debug, Default)]
pub struct Census {
    entries: HashMap<i32, Counted, BuildHasherDefault<IdHasher>>,
    /// Counting mobs per chunk and category; chunks with none are absent.
    by_chunk: BTreeMap<(i32, i32), [u32; 8]>,
    /// Mobs noted since the last refresh (a slot is noted once).
    pub(crate) dirty: Vec<i32>,
    /// Rebuild every entry at the next refresh.
    pub(crate) stale: bool,
}

impl Census {
    /// What mob `id` counted as at the last refresh.
    pub fn get(&self, id: i32) -> Option<&Counted> {
        self.entries.get(&id)
    }

    /// Every counted mob as of the last refresh, in no order.
    pub fn entries(&self) -> impl Iterator<Item = (i32, &Counted)> {
        self.entries.iter().map(|(&id, c)| (id, c))
    }

    /// The chunks holding counting mobs with their per-category counts.
    pub fn by_chunk(&self) -> impl Iterator<Item = ((i32, i32), &[u32; 8])> {
        self.by_chunk.iter().map(|(&c, n)| (c, n))
    }

    pub(crate) fn clear(&mut self) {
        self.entries.clear();
        self.by_chunk.clear();
        self.dirty.clear();
        self.stale = false;
    }

    /// Mob `id` counts as `now` (None: not at all).
    pub(crate) fn set(&mut self, id: i32, now: Option<Counted>) {
        let before = match now {
            Some(c) => self.entries.insert(id, c),
            None => self.entries.remove(&id),
        };
        if before == now {
            return;
        }
        if let Some(Counted {
            category: Some(i),
            chunk,
            ..
        }) = before
        {
            if let Some(n) = self.by_chunk.get_mut(&chunk) {
                n[i as usize] -= 1;
                if n.iter().all(|&v| v == 0) {
                    self.by_chunk.remove(&chunk);
                }
            }
        }
        if let Some(Counted {
            category: Some(i),
            chunk,
            ..
        }) = now
        {
            self.by_chunk.entry(chunk).or_insert([0; 8])[i as usize] += 1;
        }
    }

    /// Notes a change of mob `id` unless the census is to be rebuilt; past
    /// `limit` noted ids it forgets them and rebuilds instead.
    pub(crate) fn note(&mut self, id: i32, limit: usize) {
        if self.stale {
            return;
        }
        if self.dirty.len() >= limit {
            self.dirty.clear();
            self.stale = true;
            return;
        }
        self.dirty.push(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counted(kind: u16, category: Option<u8>, chunk: (i32, i32)) -> Option<Counted> {
        Some(Counted {
            kind,
            category,
            chunk,
            persistent: category.is_none(),
            bucketable: false,
        })
    }

    #[test]
    fn counts_follow_category_chunk_and_persistence_changes() {
        let mut c = Census::default();
        c.set(1, counted(5, Some(0), (0, 0)));
        c.set(2, counted(5, Some(0), (0, 0)));
        c.set(3, counted(6, None, (0, 0)));
        assert_eq!(
            c.by_chunk().collect::<Vec<_>>(),
            [((0, 0), &[2, 0, 0, 0, 0, 0, 0, 0])]
        );
        // A move, a persistence change and a removal.
        c.set(1, counted(5, Some(0), (1, 0)));
        c.set(2, counted(5, None, (0, 0)));
        assert_eq!(
            c.by_chunk().collect::<Vec<_>>(),
            [((1, 0), &[1, 0, 0, 0, 0, 0, 0, 0])]
        );
        c.set(1, None);
        assert_eq!(c.by_chunk().count(), 0);
        assert_eq!(c.entries().count(), 2);
        // A repeated set changes nothing.
        c.set(4, counted(7, Some(3), (2, 2)));
        c.set(4, counted(7, Some(3), (2, 2)));
        assert_eq!(
            c.by_chunk().collect::<Vec<_>>(),
            [((2, 2), &[0, 0, 0, 1, 0, 0, 0, 0])]
        );
    }

    #[test]
    fn notes_past_the_limit_turn_into_a_rebuild() {
        let mut c = Census::default();
        c.note(1, 2);
        c.note(2, 2);
        assert!(!c.stale);
        c.note(3, 2);
        assert!(c.stale && c.dirty.is_empty());
        c.note(4, 2);
        assert!(c.dirty.is_empty());
    }
}
