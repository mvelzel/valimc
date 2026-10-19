//! Network encodings for chunk data (26.3 `LevelChunkSection.write`).

use crate::flags::{BlockFlags, AIR, FLUID};
use crate::section::{Storage, VOLUME};

pub fn varint(out: &mut Vec<u8>, value: u32) {
    let mut v = value;
    loop {
        if v & !0x7f == 0 {
            out.push(v as u8);
            return;
        }
        out.push((v as u8 & 0x7f) | 0x80);
        v >>= 7;
    }
}

/// Pack `values` into big-endian longs, `bits` per entry, entries never spanning longs.
pub fn pack_longs(out: &mut Vec<u8>, values: impl ExactSizeIterator<Item = u64>, bits: u32) {
    let per_long = (64 / bits) as usize;
    let mut word: u64 = 0;
    let mut filled = 0usize;
    for value in values {
        word |= value << (filled as u32 * bits);
        filled += 1;
        if filled == per_long {
            out.extend_from_slice(&word.to_be_bytes());
            word = 0;
            filled = 0;
        }
    }
    if filled > 0 {
        out.extend_from_slice(&word.to_be_bytes());
    }
}

fn ceil_log2(n: usize) -> u32 {
    if n <= 1 {
        0
    } else {
        usize::BITS - (n - 1).leading_zeros()
    }
}

/// Encode one section: block count, fluid count, block states and a uniform biome.
///
/// The palette lists states in order of first appearance; 1 state is a single-value
/// container, up to 8 bits is indexed (at least 4) and wider uses `global_bits`.
pub fn encode_section(
    out: &mut Vec<u8>,
    storage: &Storage,
    flags: &BlockFlags,
    biome: u32,
    global_bits: u32,
) {
    let mut non_air: u16 = 0;
    let mut fluids: u16 = 0;
    let mut palette: Vec<u16> = Vec::new();
    let mut slot_of = vec![u16::MAX; flags.state_count()];
    let mut slots = vec![0u16; VOLUME];
    storage.for_each(|i, state| {
        let f = flags.get(state);
        if f & AIR == 0 {
            non_air += 1;
        }
        if f & FLUID != 0 {
            fluids += 1;
        }
        let slot = &mut slot_of[state as usize];
        if *slot == u16::MAX {
            *slot = palette.len() as u16;
            palette.push(state);
        }
        slots[i] = *slot;
    });
    out.extend_from_slice(&non_air.to_be_bytes());
    out.extend_from_slice(&fluids.to_be_bytes());
    if palette.len() == 1 {
        out.push(0);
        varint(out, palette[0] as u32);
    } else {
        let bits = ceil_log2(palette.len()).max(4);
        if bits <= 8 {
            out.push(bits as u8);
            varint(out, palette.len() as u32);
            for state in &palette {
                varint(out, *state as u32);
            }
            pack_longs(out, slots.iter().map(|s| *s as u64), bits);
        } else {
            out.push(global_bits as u8);
            pack_longs(
                out,
                slots.iter().map(|s| palette[*s as usize] as u64),
                global_bits,
            );
        }
    }
    // Uniform biome: a single-value container.
    out.push(0);
    varint(out, biome);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_match_protocol() {
        let mut out = Vec::new();
        for v in [0u32, 1, 127, 128, 255, 25565, 2097151, u32::MAX] {
            varint(&mut out, v);
        }
        assert_eq!(
            out,
            [
                0x00, 0x01, 0x7f, 0x80, 0x01, 0xff, 0x01, 0xdd, 0xc7, 0x01, 0xff, 0xff, 0x7f, 0xff,
                0xff, 0xff, 0xff, 0x0f
            ]
        );
    }

    #[test]
    fn longs_pack_low_bits_first_without_spanning() {
        let mut out = Vec::new();
        pack_longs(&mut out, [1u64, 2, 3].into_iter(), 9);
        let word = 1u64 | (2 << 9) | (3 << 18);
        assert_eq!(out, word.to_be_bytes());
    }

    #[test]
    fn single_air_section() {
        let flags = BlockFlags::new(vec![AIR, 0]).unwrap();
        let mut out = Vec::new();
        encode_section(&mut out, &Storage::Single(0), &flags, 40, 15);
        assert_eq!(out, [0, 0, 0, 0, 0, 0, 0, 40]);
    }
}
