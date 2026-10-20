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

/// Unpack `count` entries of `bits` each from big-endian longs, entries never
/// spanning two longs (vanilla `SimpleBitStorage`). `None` unless `data` holds
/// exactly the longs that layout needs.
pub fn unpack(data: &[u8], bits: u32, count: usize) -> Option<Vec<u32>> {
    if bits == 0 || bits > 32 {
        return None;
    }
    let per_long = (64 / bits) as usize;
    if data.len() != count.div_ceil(per_long) * 8 {
        return None;
    }
    let mask = (1u64 << bits) - 1;
    let mut out = Vec::with_capacity(count);
    for word in data.chunks_exact(8) {
        let word = u64::from_be_bytes(word.try_into().unwrap());
        for k in 0..per_long {
            if out.len() == count {
                break;
            }
            out.push(((word >> (k as u32 * bits)) & mask) as u32);
        }
    }
    Some(out)
}

impl Storage {
    /// A section from a palette and packed indices (`bits` 0 for a single entry).
    /// `None` when the data does not fit the layout or an index is past the palette.
    pub fn from_palette(palette: &[u16], data: &[u8], bits: u32) -> Option<Storage> {
        match palette.len() {
            0 => None,
            1 if bits == 0 => Some(Storage::Single(palette[0])),
            _ if bits == 0 => None,
            len => {
                let indices = unpack(data, bits, VOLUME)?;
                if indices.iter().any(|&i| i as usize >= len) {
                    return None;
                }
                let mut storage = if len <= INDEXED_LIMIT {
                    let mut cells = Box::new([0u8; VOLUME]);
                    for (cell, &i) in cells.iter_mut().zip(&indices) {
                        *cell = i as u8;
                    }
                    Storage::Indexed {
                        palette: palette.to_vec(),
                        cells,
                    }
                } else {
                    let mut cells = Box::new([0u16; VOLUME]);
                    for (cell, &i) in cells.iter_mut().zip(&indices) {
                        *cell = palette[i as usize];
                    }
                    Storage::Dense(cells)
                };
                storage.normalize();
                Some(storage)
            }
        }
    }
}

/// Biomes of one section: 4×4×4 cells, index `(y << 4) | (z << 2) | x`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Biomes {
    Single(u16),
    Cells(Box<[u16; 64]>),
}

impl Biomes {
    pub fn from_palette(palette: &[u16], data: &[u8], bits: u32) -> Option<Biomes> {
        match palette.len() {
            0 => None,
            1 if bits == 0 => Some(Biomes::Single(palette[0])),
            _ if bits == 0 => None,
            _ => {
                let indices = unpack(data, bits, 64)?;
                let mut cells = Box::new([0u16; 64]);
                for (cell, &i) in cells.iter_mut().zip(&indices) {
                    *cell = *palette.get(i as usize)?;
                }
                Some(if cells.iter().all(|&b| b == cells[0]) {
                    Biomes::Single(cells[0])
                } else {
                    Biomes::Cells(cells)
                })
            }
        }
    }

    #[inline]
    pub fn get(&self, index: usize) -> u16 {
        match self {
            Biomes::Single(biome) => *biome,
            Biomes::Cells(cells) => cells[index],
        }
    }
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
    fn packed_palettes_unpack_without_spanning_longs() {
        // 5 bits: 12 entries per long; 4096 entries need 342 longs.
        let mut data = Vec::new();
        let mut word = 0u64;
        for i in 0..VOLUME {
            word |= ((i % 20) as u64) << ((i % 12) * 5);
            if i % 12 == 11 || i == VOLUME - 1 {
                data.extend(word.to_be_bytes());
                word = 0;
            }
        }
        let palette: Vec<u16> = (100..120).collect();
        let storage = Storage::from_palette(&palette, &data, 5).unwrap();
        for i in [0, 11, 12, 4095] {
            assert_eq!(storage.get(i), 100 + (i % 20) as u16);
        }
        assert_eq!(Storage::from_palette(&palette, &data[8..], 5), None);
        assert_eq!(Storage::from_palette(&palette[..10], &data, 5), None);
        assert_eq!(
            Storage::from_palette(&[7], &[], 0),
            Some(Storage::Single(7))
        );
        assert_eq!(
            Storage::from_palette(&[7, 7], &data, 5).map(|s| s.get(0)),
            None
        );
        // An unused palette entry collapses to a single state.
        let zeros = vec![0u8; 256 * 8];
        assert_eq!(
            Storage::from_palette(&[3, 4], &zeros, 4),
            Some(Storage::Single(3))
        );
        let biomes = Biomes::from_palette(&[9, 8], &[0, 0, 0, 0, 0, 0, 0, 2], 1).unwrap();
        assert_eq!((biomes.get(0), biomes.get(1), biomes.get(2)), (9, 8, 9));
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
