//! The per-state block facts the core reads (VMC-077d), from the one generated
//! table (`priv/registry/block_facts.json`, decoded by
//! `Valimc.Registry.BlockFacts`) and installed once per VM: the flag bits,
//! the heightmap predicates and the contained fluid. The storage flags and
//! worldgen's block table are built from them; the light facts come from the
//! same table's light columns.

use crate::flags::{self, BlockFlags};

/// `isAir` (flag bit 0).
pub const AIR: u64 = 1;
/// `FireBlock.canBurn` (flag bit 49).
pub const FLAMMABLE: u64 = 1 << 49;

#[derive(Debug)]
pub struct StateFacts {
    /// The table's flag bits per state (its `flag_bits` order).
    pub flags: Vec<u64>,
    /// The six heightmap predicates (`Heightmap.Types` order).
    pub heightmaps: Vec<u8>,
    /// The contained fluid as vanilla's fluid registry id: empty, flowing
    /// water, water, flowing lava, lava.
    pub fluid: Vec<u8>,
    /// The fluid amount (0..8) with the falling flag at bit 4.
    pub fluid_level: Vec<u8>,
}

impl StateFacts {
    pub fn new(
        flags: Vec<u64>,
        heightmaps: Vec<u8>,
        fluid: Vec<u8>,
        fluid_level: Vec<u8>,
    ) -> Option<Self> {
        let count = flags.len();
        let valid = count > 0
            && count <= u16::MAX as usize + 1
            && [heightmaps.len(), fluid.len(), fluid_level.len()]
                .iter()
                .all(|&n| n == count)
            && heightmaps.iter().all(|&h| h < 64)
            && fluid.iter().all(|&f| f <= 4)
            && fluid_level.iter().all(|&l| l & 15 <= 8 && l < 32);
        valid.then_some(Self {
            flags,
            heightmaps,
            fluid,
            fluid_level,
        })
    }

    pub fn state_count(&self) -> usize {
        self.flags.len()
    }

    /// The storage layer's byte per state: the heightmap predicates, air and
    /// a contained fluid.
    pub fn storage_flags(&self) -> BlockFlags {
        let bytes = (0..self.state_count())
            .map(|s| {
                let air = if self.flags[s] & AIR != 0 {
                    flags::AIR
                } else {
                    0
                };
                let fluid = if self.fluid[s] != 0 { flags::FLUID } else { 0 };
                self.heightmaps[s] | air | fluid
            })
            .collect();
        BlockFlags::new(bytes).expect("state facts are validated")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storage_flags_combine_heightmaps_air_and_fluid() {
        let facts = StateFacts::new(
            vec![AIR, 0, 0],
            vec![0, 0b11_1111, 0],
            vec![0, 0, 2],
            vec![0, 0, 8],
        )
        .unwrap();
        let storage = facts.storage_flags();
        assert_eq!(storage.get(0), flags::AIR);
        assert_eq!(storage.get(1), 0b11_1111);
        assert_eq!(storage.get(2), flags::FLUID);
        assert!(StateFacts::new(vec![0], vec![64], vec![0], vec![0]).is_none());
        assert!(StateFacts::new(vec![0, 0], vec![0], vec![0], vec![0]).is_none());
    }
}
