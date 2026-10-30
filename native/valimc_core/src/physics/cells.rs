//! Small keyed sets and maps for the kernel's hot paths: a fast hash for
//! integer keys (block positions, chunk and grid cells; no flooding concern,
//! the keys are the server's own) and a set of block positions that stays a
//! plain list while it is small, as most walks and contact scans are.

use std::collections::HashSet;
use std::hash::{BuildHasherDefault, Hasher};

/// A multiplicative hash over the key's integer words (FxHash's mixing).
#[derive(Clone, Copy, Default)]
pub struct CellHasher(u64);

const SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

impl CellHasher {
    #[inline]
    fn add(&mut self, word: u64) {
        self.0 = (self.0.rotate_left(5) ^ word).wrapping_mul(SEED);
    }
}

impl Hasher for CellHasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }

    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut word = [0u8; 8];
            word[..chunk.len()].copy_from_slice(chunk);
            self.add(u64::from_le_bytes(word));
        }
    }

    #[inline]
    fn write_u32(&mut self, v: u32) {
        self.add(v as u64);
    }

    #[inline]
    fn write_i32(&mut self, v: i32) {
        self.add(v as u32 as u64);
    }

    #[inline]
    fn write_u64(&mut self, v: u64) {
        self.add(v);
    }

    #[inline]
    fn write_i64(&mut self, v: i64) {
        self.add(v as u64);
    }

    #[inline]
    fn write_usize(&mut self, v: usize) {
        self.add(v as u64);
    }
}

pub type CellBuild = BuildHasherDefault<CellHasher>;
pub type CellMap<K, V> = std::collections::HashMap<K, V, CellBuild>;

/// Positions the set searches as a list up to; past it, a hash set.
const LINEAR: usize = 24;

/// A set of block positions: a list while small, then hashed.
#[derive(Default)]
pub struct CellSet {
    list: Vec<[i32; 3]>,
    hashed: Option<HashSet<[i32; 3], CellBuild>>,
}

impl CellSet {
    pub fn new() -> CellSet {
        CellSet::default()
    }

    #[inline]
    pub fn contains(&self, p: &[i32; 3]) -> bool {
        match &self.hashed {
            Some(set) => set.contains(p),
            None => self.list.contains(p),
        }
    }

    /// Add `p`; whether it was new.
    #[inline]
    pub fn insert(&mut self, p: [i32; 3]) -> bool {
        if let Some(set) = &mut self.hashed {
            return set.insert(p);
        }
        if self.list.contains(&p) {
            return false;
        }
        if self.list.len() < LINEAR {
            self.list.push(p);
        } else {
            let mut set: HashSet<[i32; 3], CellBuild> =
                HashSet::with_capacity_and_hasher(LINEAR * 4, CellBuild::default());
            set.extend(self.list.drain(..));
            set.insert(p);
            self.hashed = Some(set);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_set_answers_alike_listed_and_hashed() {
        let mut set = CellSet::new();
        for i in 0..100 {
            assert!(set.insert([i % 50, i / 7, -i]));
            assert!(!set.insert([i % 50, i / 7, -i]));
        }
        assert!((0..100).all(|i| set.contains(&[i % 50, i / 7, -i])));
        assert!(!set.contains(&[1, 2, 3]));
    }
}
