//! The per-state block facts the core reads (VMC-077d), from the one generated
//! table (`priv/registry/block_facts.json`, decoded by
//! `Valimc.Registry.BlockFacts`) and installed once per VM: the flag bits,
//! the heightmap predicates, the contained fluid and the redstone signals. The storage flags and
//! worldgen's block table are built from them; the light facts come from the
//! same table's light columns.

use crate::flags::{self, BlockFlags};

/// `isAir` (flag bit 0).
pub const AIR: u64 = 1;
/// `FireBlock.canBurn` (flag bit 49).
pub const FLAMMABLE: u64 = 1 << 49;
/// A signal that reads the level (`signal` column's `context`): powered
/// wire, comparators, trapped chests.
pub const SIGNAL_CONTEXT: u64 = 1 << 48;

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
    /// What base block removal leaves: the state's fluid as a block.
    pub remains: Vec<u16>,
    /// `getSignal` toward direction `d` at bits `4d..4d+4`, `getDirectSignal`
    /// at `24+4d`, and `SIGNAL_CONTEXT` for a signal that reads the level.
    pub signal: Vec<u64>,
}

impl StateFacts {
    pub fn new(
        flags: Vec<u64>,
        heightmaps: Vec<u8>,
        fluid: Vec<u8>,
        fluid_level: Vec<u8>,
        remains: Vec<u16>,
        signal: Vec<u64>,
    ) -> Option<Self> {
        let count = flags.len();
        let valid = count > 0
            && count <= u16::MAX as usize + 1
            && [
                heightmaps.len(),
                fluid.len(),
                fluid_level.len(),
                remains.len(),
                signal.len(),
            ]
            .iter()
            .all(|&n| n == count)
            && remains.iter().all(|&r| (r as usize) < count)
            && heightmaps.iter().all(|&h| h < 64)
            && fluid.iter().all(|&f| f <= 4)
            && fluid_level.iter().all(|&l| l & 15 <= 8 && l < 32)
            && signal.iter().all(|&s| s >> 49 == 0);
        valid.then_some(Self {
            flags,
            heightmaps,
            fluid,
            fluid_level,
            remains,
            signal,
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
            vec![0, 0, 0],
            vec![0, 0, 0],
        )
        .unwrap();
        let storage = facts.storage_flags();
        assert_eq!(storage.get(0), flags::AIR);
        assert_eq!(storage.get(1), 0b11_1111);
        assert_eq!(storage.get(2), flags::FLUID);
        assert!(StateFacts::new(vec![0], vec![64], vec![0], vec![0], vec![0], vec![0]).is_none());
        let (one, two) = (vec![0], vec![0, 0]);
        assert!(StateFacts::new(two.clone(), one.clone(), one, vec![0], vec![0, 0], two).is_none());
    }
}
