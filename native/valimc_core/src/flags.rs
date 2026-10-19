//! Per-block-state facts the storage layer needs, supplied once by Elixir from
//! the pinned generated data (one byte per state id).

/// Bits 0..=5 are the vanilla heightmap predicates in `Heightmap.Types` order.
pub const WORLD_SURFACE: u8 = 1 << 1;
pub const MOTION_BLOCKING: u8 = 1 << 4;
/// `BlockState.isAir()`.
pub const AIR: u8 = 1 << 6;
/// `!BlockState.getFluidState().isEmpty()`.
pub const FLUID: u8 = 1 << 7;

#[derive(Clone, Debug)]
pub struct BlockFlags {
    bytes: Vec<u8>,
}

impl BlockFlags {
    pub fn new(bytes: Vec<u8>) -> Option<Self> {
        if bytes.is_empty() || bytes.len() > u16::MAX as usize + 1 {
            return None;
        }
        Some(Self { bytes })
    }

    /// Number of known block states; ids at or above it are invalid.
    pub fn state_count(&self) -> usize {
        self.bytes.len()
    }

    #[inline]
    pub fn get(&self, state: u16) -> u8 {
        self.bytes[state as usize]
    }

    #[inline]
    pub fn valid(&self, state: u32) -> bool {
        (state as usize) < self.bytes.len()
    }
}
