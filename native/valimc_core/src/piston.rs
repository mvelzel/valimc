//! A moving piston's block entity (VMC-048b, vanilla's
//! `PistonMovingBlockEntity`): the block it carries, its direction and
//! progress. The block rules make, tick and end them; region stores keep
//! them beside their cells and chunk snapshots publish them, so the physics
//! kernel gives moving blocks their collision shapes.

/// One moving block.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Moving {
    /// The state it carries (`movedState`).
    pub moved: u16,
    /// The piston's facing, a `Direction` index (down, up, north, south,
    /// west, east).
    pub direction: u8,
    pub extending: bool,
    /// It is the piston's own head or base (`isSourcePiston`).
    pub source: bool,
    pub progress: f32,
    pub progress_o: f32,
    /// The game time it last ticked (`lastTicked`).
    pub last_ticked: i64,
    /// Its place in the tick order: block entities tick in the order they
    /// were made.
    pub order: i64,
}

/// A chunk's moving blocks by position, as stores and snapshots share them.
pub type ChunkPistons = std::sync::Arc<Vec<([i32; 3], Moving)>>;

/// The packed size of one moving block with its position.
pub const PACKED: usize = 12 + 2 + 1 + 1 + 4 + 4 + 8 + 8;

impl Moving {
    /// `getExtendedProgress`: how far the block lags its cell, along its
    /// direction.
    pub fn extended_progress(&self, progress: f32) -> f32 {
        if self.extending {
            progress - 1.0
        } else {
            1.0 - progress
        }
    }

    /// `getMovementDirection`.
    pub fn movement(&self) -> usize {
        let d = self.direction as usize;
        if self.extending {
            d
        } else {
            d ^ 1
        }
    }

    /// The big-endian record the owner and the stores exchange: position,
    /// moved state, direction, flags (1 extending, 2 source), progress and
    /// its old value as float bits, last ticked and order.
    pub fn pack(&self, pos: [i32; 3], out: &mut Vec<u8>) {
        for c in pos {
            out.extend_from_slice(&c.to_be_bytes());
        }
        out.extend_from_slice(&self.moved.to_be_bytes());
        out.push(self.direction);
        out.push(u8::from(self.extending) | u8::from(self.source) << 1);
        out.extend_from_slice(&self.progress.to_bits().to_be_bytes());
        out.extend_from_slice(&self.progress_o.to_bits().to_be_bytes());
        out.extend_from_slice(&self.last_ticked.to_be_bytes());
        out.extend_from_slice(&self.order.to_be_bytes());
    }

    /// Records packed by `pack`; `None` for a malformed binary.
    pub fn unpack(bytes: &[u8]) -> Option<Vec<([i32; 3], Moving)>> {
        if !bytes.len().is_multiple_of(PACKED) {
            return None;
        }
        bytes
            .as_chunks::<PACKED>()
            .0
            .iter()
            .map(|r| {
                let i32_at = |i: usize| i32::from_be_bytes(r[i..i + 4].try_into().unwrap());
                let i64_at = |i: usize| i64::from_be_bytes(r[i..i + 8].try_into().unwrap());
                let f32_at =
                    |i: usize| f32::from_bits(u32::from_be_bytes(r[i..i + 4].try_into().unwrap()));
                let direction = r[14];
                (direction < 6).then(|| {
                    (
                        [i32_at(0), i32_at(4), i32_at(8)],
                        Moving {
                            moved: u16::from_be_bytes([r[12], r[13]]),
                            direction,
                            extending: r[15] & 1 != 0,
                            source: r[15] & 2 != 0,
                            progress: f32_at(16),
                            progress_o: f32_at(20),
                            last_ticked: i64_at(24),
                            order: i64_at(32),
                        },
                    )
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_round_trip() {
        let moving = Moving {
            moved: 1234,
            direction: 5,
            extending: true,
            source: false,
            progress: 0.5,
            progress_o: 0.0,
            last_ticked: -7,
            order: 1 << 40,
        };
        let mut out = Vec::new();
        moving.pack([-3, 64, 17], &mut out);
        assert_eq!(out.len(), PACKED);
        assert_eq!(Moving::unpack(&out), Some(vec![([-3, 64, 17], moving)]));
        assert_eq!(moving.movement(), 5);
        assert_eq!(
            Moving {
                extending: false,
                ..moving
            }
            .movement(),
            4
        );
        assert_eq!(Moving::unpack(&out[1..]), None);
    }
}
