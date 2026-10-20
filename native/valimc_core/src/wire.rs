//! Network encodings for chunk data (26.3 `LevelChunkSection.write`).

use crate::flags::{BlockFlags, AIR, FLUID};
use crate::section::{Biomes, Storage, VOLUME};

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

/// Section biomes for encoding: the section's own, or one biome for all cells.
#[derive(Clone, Copy)]
pub enum SectionBiomes<'a> {
    Uniform(u32),
    Stored(&'a Biomes),
}

/// Encode one section: block count, fluid count, block states and biomes.
///
/// The palette lists states in order of first appearance; 1 state is a single-value
/// container, up to 8 bits is indexed (at least 4) and wider uses `global_bits`.
/// Biomes are a single value, 1–3-bit indexed, or `biome_bits` global ids.
pub fn encode_section(
    out: &mut Vec<u8>,
    storage: &Storage,
    flags: &BlockFlags,
    biomes: SectionBiomes,
    global_bits: u32,
    biome_bits: u32,
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
    encode_biomes(out, biomes, biome_bits);
}

fn encode_biomes(out: &mut Vec<u8>, biomes: SectionBiomes, biome_bits: u32) {
    let cells = match biomes {
        SectionBiomes::Uniform(biome) => {
            out.push(0);
            varint(out, biome);
            return;
        }
        SectionBiomes::Stored(Biomes::Single(biome)) => {
            out.push(0);
            varint(out, *biome as u32);
            return;
        }
        SectionBiomes::Stored(Biomes::Cells(cells)) => cells,
    };
    let mut palette: Vec<u16> = Vec::new();
    let slots: Vec<u64> = cells
        .iter()
        .map(|biome| match palette.iter().position(|b| b == biome) {
            Some(slot) => slot as u64,
            None => {
                palette.push(*biome);
                (palette.len() - 1) as u64
            }
        })
        .collect();
    let bits = ceil_log2(palette.len());
    if bits <= 3 {
        out.push(bits as u8);
        varint(out, palette.len() as u32);
        for biome in &palette {
            varint(out, *biome as u32);
        }
        pack_longs(out, slots.into_iter(), bits);
    } else {
        out.push(biome_bits as u8);
        pack_longs(out, cells.iter().map(|b| *b as u64), biome_bits);
    }
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
        encode_section(
            &mut out,
            &Storage::Single(0),
            &flags,
            SectionBiomes::Uniform(40),
            15,
            7,
        );
        assert_eq!(out, [0, 0, 0, 0, 0, 0, 0, 40]);
    }

    #[test]
    fn stored_biomes_use_small_palettes_then_global_ids() {
        let flags = BlockFlags::new(vec![AIR, 0]).unwrap();
        let mut two = Box::new([5u16; 64]);
        two[1] = 9;
        let mut out = Vec::new();
        let biomes = Biomes::Cells(two);
        encode_section(
            &mut out,
            &Storage::Single(0),
            &flags,
            SectionBiomes::Stored(&biomes),
            15,
            7,
        );
        // After counts and the single-state blocks: 1 bit, palette [5, 9], one long
        // with only cell 1 set.
        assert_eq!(out[6..], [1, 2, 5, 9, 0, 0, 0, 0, 0, 0, 0, 2]);
        let many = Biomes::Cells(Box::new(std::array::from_fn(|i| (i % 10) as u16)));
        let mut out = Vec::new();
        encode_section(
            &mut out,
            &Storage::Single(0),
            &flags,
            SectionBiomes::Stored(&many),
            15,
            7,
        );
        // Ten biomes need 4 bits: global ids at 7 bits, 9 per long, 8 longs.
        assert_eq!(out[6..].len(), 1 + 8 * 8);
        assert_eq!(out[6], 7);
    }
}
