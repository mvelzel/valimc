//! One 16×16×16 section of block states, stored by how varied it is.
//!
//! Index order matches vanilla: `(y << 8) | (z << 4) | x`.

pub const VOLUME: usize = 4096;
const INDEXED_LIMIT: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Storage {
    /// Every cell holds the same state.
    Single(u16),
    /// Up to 256 distinct states; one byte per cell. The palette may keep states
    /// that no cell uses any more; encoders derive the live palette themselves.
    Indexed {
        palette: Vec<u16>,
        cells: Box<[u8; VOLUME]>,
    },
    /// Any number of states; one `u16` per cell.
    Dense(Box<[u16; VOLUME]>),
}

impl Storage {
    #[inline]
    pub fn get(&self, index: usize) -> u16 {
        match self {
            Storage::Single(state) => *state,
            Storage::Indexed { palette, cells } => palette[cells[index] as usize],
            Storage::Dense(cells) => cells[index],
        }
    }

    /// Store `state` at `index` and return the previous state.
    pub fn set(&mut self, index: usize, state: u16) -> u16 {
        match self {
            Storage::Single(current) => {
                let previous = *current;
                if previous != state {
                    let mut cells = Box::new([0u8; VOLUME]);
                    cells[index] = 1;
                    *self = Storage::Indexed {
                        palette: vec![previous, state],
                        cells,
                    };
                }
                previous
            }
            Storage::Indexed { palette, cells } => {
                let previous = palette[cells[index] as usize];
                if previous == state {
                    return previous;
                }
                if let Some(slot) = palette.iter().position(|&s| s == state) {
                    cells[index] = slot as u8;
                } else if palette.len() < INDEXED_LIMIT {
                    palette.push(state);
                    cells[index] = (palette.len() - 1) as u8;
                } else if let Some(compacted) = Self::compact(palette, cells, index, state) {
                    *self = compacted;
                } else {
                    let mut dense = Box::new([0u16; VOLUME]);
                    for (i, cell) in cells.iter().enumerate() {
                        dense[i] = palette[*cell as usize];
                    }
                    dense[index] = state;
                    *self = Storage::Dense(dense);
                }
                previous
            }
            Storage::Dense(cells) => std::mem::replace(&mut cells[index], state),
        }
    }

    /// Rebuild a full palette without unused states, if that frees a slot.
    fn compact(palette: &[u16], cells: &[u8; VOLUME], index: usize, state: u16) -> Option<Storage> {
        let mut used = [false; INDEXED_LIMIT];
        for (i, cell) in cells.iter().enumerate() {
            if i != index {
                used[*cell as usize] = true;
            }
        }
        let live = used.iter().filter(|u| **u).count();
        if live >= INDEXED_LIMIT {
            return None;
        }
        let mut remap = [0u8; INDEXED_LIMIT];
        let mut next = Vec::with_capacity(live + 1);
        for (slot, is_used) in used.iter().enumerate() {
            if *is_used {
                remap[slot] = next.len() as u8;
                next.push(palette[slot]);
            }
        }
        let mut fresh = Box::new([0u8; VOLUME]);
        for (i, cell) in cells.iter().enumerate() {
            fresh[i] = remap[*cell as usize];
        }
        next.push(state);
        fresh[index] = (next.len() - 1) as u8;
        Some(Storage::Indexed {
            palette: next,
            cells: fresh,
        })
    }

    /// Collapse to `Single` when every cell holds one state (after edits revert).
    pub fn normalize(&mut self) {
        let first = self.get(0);
        let uniform = match self {
            Storage::Single(_) => return,
            Storage::Indexed { palette, cells } => {
                cells.iter().all(|c| palette[*c as usize] == first)
            }
            Storage::Dense(cells) => cells.iter().all(|c| *c == first),
        };
        if uniform {
            *self = Storage::Single(first);
        }
    }

    /// Visit every cell in index order.
    pub fn for_each(&self, mut f: impl FnMut(usize, u16)) {
        match self {
            Storage::Single(state) => (0..VOLUME).for_each(|i| f(i, *state)),
            Storage::Indexed { palette, cells } => cells
                .iter()
                .enumerate()
                .for_each(|(i, c)| f(i, palette[*c as usize])),
            Storage::Dense(cells) => cells.iter().enumerate().for_each(|(i, c)| f(i, *c)),
        }
    }

    /// Approximate heap bytes, for memory budgets.
    pub fn heap_bytes(&self) -> usize {
        match self {
            Storage::Single(_) => 0,
            Storage::Indexed { palette, .. } => VOLUME + palette.capacity() * 2,
            Storage::Dense(_) => VOLUME * 2,
        }
    }
}

#[inline]
pub fn index(x: usize, y: usize, z: usize) -> usize {
    (y << 8) | (z << 4) | x
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_upgrades_and_returns_previous() {
        let mut s = Storage::Single(1);
        assert_eq!(s.set(5, 7), 1);
        assert_eq!(s.get(5), 7);
        assert_eq!(s.get(6), 1);
        assert_eq!(s.set(5, 1), 7);
        s.normalize();
        assert_eq!(s, Storage::Single(1));
    }

    #[test]
    fn indexed_spills_to_dense_beyond_256_states() {
        let mut s = Storage::Single(0);
        for i in 0..300usize {
            s.set(i, i as u16 + 1);
        }
        assert!(matches!(s, Storage::Dense(_)));
        for i in 0..300usize {
            assert_eq!(s.get(i), i as u16 + 1);
        }
        assert_eq!(s.get(300), 0);
    }

    #[test]
    fn full_palette_compacts_when_states_were_overwritten() {
        let mut s = Storage::Single(0);
        for i in 0..255usize {
            s.set(i, i as u16 + 1);
        }
        // Overwrite one state so its palette slot becomes unused, then add a new state.
        s.set(10, 0);
        s.set(20, 999);
        assert!(matches!(s, Storage::Indexed { .. }));
        assert_eq!(s.get(10), 0);
        assert_eq!(s.get(20), 999);
        assert_eq!(s.get(30), 31);
    }
}
