//! LZ4 block streams as vanilla writes region chunks with `region-file-compression=lz4`
//! (lz4-java's `LZ4BlockOutputStream`, VMC-021).
//!
//! A stream is a sequence of blocks, each `"LZ4Block"`, a token (method in the high
//! nibble: 0x10 stored, 0x20 LZ4; block-size level in the low nibble), little-endian
//! compressed length, original length and checksum (xxHash32, seed 0x9747B28C, low 28
//! bits) of the original bytes. An empty block ends the stream; bytes after it are
//! ignored, as `LZ4BlockInputStream` ignores them.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lz4Error {
    /// The stream ends inside a block or before its end block.
    Truncated,
    /// Bad magic, method, lengths, block data or checksum.
    Corrupt,
    /// The output would exceed the caller's limit.
    Limit,
}

const MAGIC: &[u8; 8] = b"LZ4Block";
const HEADER: usize = 8 + 1 + 4 + 4 + 4;
const SEED: u32 = 0x9747_B28C;
const STORED: u8 = 0x10;
const LZ4: u8 = 0x20;

fn le32(bytes: &[u8]) -> i32 {
    i32::from_le_bytes(bytes.try_into().unwrap())
}

/// Decode a whole block stream into at most `max` bytes.
pub fn decode_stream(input: &[u8], max: usize) -> Result<Vec<u8>, Lz4Error> {
    let mut out = Vec::new();
    let mut pos = 0;
    loop {
        if input.len() - pos < HEADER {
            return Err(Lz4Error::Truncated);
        }
        let header = &input[pos..pos + HEADER];
        if &header[..8] != MAGIC {
            return Err(Lz4Error::Corrupt);
        }
        let token = header[8];
        let method = token & 0xF0;
        let level = (token & 0x0F) as u32 + 10;
        let compressed = le32(&header[9..13]);
        let original = le32(&header[13..17]);
        let checksum = le32(&header[17..21]) as u32;
        pos += HEADER;
        if original < 0
            || compressed < 0
            || original as u64 > 1u64 << level
            || (original == 0 && compressed != 0)
            || (original != 0 && compressed == 0)
            || (method == STORED && original != compressed)
            || (method != STORED && method != LZ4)
        {
            return Err(Lz4Error::Corrupt);
        }
        if original == 0 {
            return if checksum == 0 {
                Ok(out)
            } else {
                Err(Lz4Error::Corrupt)
            };
        }
        let (compressed, original) = (compressed as usize, original as usize);
        if input.len() - pos < compressed {
            return Err(Lz4Error::Truncated);
        }
        if out.len() + original > max {
            return Err(Lz4Error::Limit);
        }
        let data = &input[pos..pos + compressed];
        pos += compressed;
        let start = out.len();
        if method == STORED {
            out.extend_from_slice(data);
        } else {
            decode_block(data, original, &mut out)?;
        }
        if xxh32(&out[start..], SEED) & 0x0FFF_FFFF != checksum {
            return Err(Lz4Error::Corrupt);
        }
    }
}

/// Append one LZ4 block that must decode to exactly `size` bytes.
fn decode_block(data: &[u8], size: usize, out: &mut Vec<u8>) -> Result<(), Lz4Error> {
    let start = out.len();
    let end = start + size;
    let mut i = 0;
    let length = |data: &[u8], i: &mut usize, mut n: usize| -> Result<usize, Lz4Error> {
        if n == 15 {
            loop {
                let byte = *data.get(*i).ok_or(Lz4Error::Corrupt)?;
                *i += 1;
                n += byte as usize;
                if byte != 255 {
                    break;
                }
            }
        }
        Ok(n)
    };
    loop {
        let token = *data.get(i).ok_or(Lz4Error::Corrupt)?;
        i += 1;
        let literals = length(data, &mut i, (token >> 4) as usize)?;
        if literals > data.len() - i || out.len() + literals > end {
            return Err(Lz4Error::Corrupt);
        }
        out.extend_from_slice(&data[i..i + literals]);
        i += literals;
        if i == data.len() {
            // The last sequence has literals only and fills the block exactly.
            return if out.len() == end {
                Ok(())
            } else {
                Err(Lz4Error::Corrupt)
            };
        }
        if data.len() - i < 2 {
            return Err(Lz4Error::Corrupt);
        }
        let offset = u16::from_le_bytes([data[i], data[i + 1]]) as usize;
        i += 2;
        let matched = length(data, &mut i, (token & 15) as usize)? + 4;
        if offset == 0 || offset > out.len() - start || out.len() + matched > end {
            return Err(Lz4Error::Corrupt);
        }
        // Matches may overlap their own output (offset < length): copy byte by byte.
        let from = out.len() - offset;
        for k in 0..matched {
            let byte = out[from + k];
            out.push(byte);
        }
    }
}

const P1: u32 = 2_654_435_761;
const P2: u32 = 2_246_822_519;
const P3: u32 = 3_266_489_917;
const P4: u32 = 668_265_263;
const P5: u32 = 374_761_393;

/// xxHash32 of `data` with `seed`.
pub fn xxh32(data: &[u8], seed: u32) -> u32 {
    let round = |acc: u32, lane: u32| {
        acc.wrapping_add(lane.wrapping_mul(P2))
            .rotate_left(13)
            .wrapping_mul(P1)
    };
    let lane = |bytes: &[u8]| u32::from_le_bytes(bytes.try_into().unwrap());
    let mut i = 0;
    let mut h = if data.len() >= 16 {
        let mut v = [
            seed.wrapping_add(P1).wrapping_add(P2),
            seed.wrapping_add(P2),
            seed,
            seed.wrapping_sub(P1),
        ];
        while data.len() - i >= 16 {
            for (k, acc) in v.iter_mut().enumerate() {
                *acc = round(*acc, lane(&data[i + 4 * k..i + 4 * k + 4]));
            }
            i += 16;
        }
        v[0].rotate_left(1)
            .wrapping_add(v[1].rotate_left(7))
            .wrapping_add(v[2].rotate_left(12))
            .wrapping_add(v[3].rotate_left(18))
    } else {
        seed.wrapping_add(P5)
    };
    h = h.wrapping_add(data.len() as u32);
    while data.len() - i >= 4 {
        h = h
            .wrapping_add(lane(&data[i..i + 4]).wrapping_mul(P3))
            .rotate_left(17)
            .wrapping_mul(P4);
        i += 4;
    }
    for &byte in &data[i..] {
        h = h
            .wrapping_add((byte as u32).wrapping_mul(P5))
            .rotate_left(11)
            .wrapping_mul(P1);
    }
    h ^= h >> 15;
    h = h.wrapping_mul(P2);
    h ^= h >> 13;
    h = h.wrapping_mul(P3);
    h ^ (h >> 16)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(token: u8, data: &[u8], original: &[u8]) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        out.push(token);
        out.extend((data.len() as i32).to_le_bytes());
        out.extend((original.len() as i32).to_le_bytes());
        let checksum = if original.is_empty() {
            0
        } else {
            xxh32(original, SEED) & 0x0FFF_FFFF
        };
        out.extend((checksum as i32).to_le_bytes());
        out.extend(data);
        out
    }

    #[test]
    fn xxh32_reference_values() {
        assert_eq!(xxh32(b"", 0), 0x02CC_5D05);
        assert_eq!(xxh32(b"a", 0), 0x550D_7456);
        assert_eq!(xxh32(b"abc", 0), 0x32D1_53FF);
        assert_eq!(
            xxh32(b"Nobody inspects the spammish repetition", 0),
            0xE229_3B2F
        );
    }

    #[test]
    fn stored_and_lz4_blocks_with_overlapping_matches() {
        // "abcabcabcabcabc!": literals "abc", then a 12-byte match at offset 3, then "!".
        let lz = [0x38, b'a', b'b', b'c', 3, 0, 0x10, b'!'];
        let plain = b"abcabcabcabcabc!";
        let mut stream = block(LZ4 | 6, &lz, plain);
        stream.extend(block(STORED | 6, b"xyz", b"xyz"));
        stream.extend(block(STORED | 6, b"", b""));
        stream.extend(b"trailing bytes are ignored");
        assert_eq!(
            decode_stream(&stream, 1 << 20).unwrap(),
            b"abcabcabcabcabc!xyz"
        );
        assert_eq!(decode_stream(&stream, 10), Err(Lz4Error::Limit));
    }

    #[test]
    fn corrupt_and_truncated_streams() {
        let plain = b"abcabcabcabcabc!";
        let good = {
            let mut s = block(LZ4 | 6, &[0x38, b'a', b'b', b'c', 3, 0, 0x10, b'!'], plain);
            s.extend(block(STORED | 6, b"", b""));
            s
        };
        for cut in 0..good.len() {
            assert!(decode_stream(&good[..cut], 1 << 20).is_err());
        }
        let mut bad_checksum = good.clone();
        bad_checksum[17] ^= 1;
        assert_eq!(
            decode_stream(&bad_checksum, 1 << 20),
            Err(Lz4Error::Corrupt)
        );
        let mut bad_offset = good.clone();
        bad_offset[HEADER + 4] = 9;
        assert_eq!(decode_stream(&bad_offset, 1 << 20), Err(Lz4Error::Corrupt));
        let mut bad_method = good.clone();
        bad_method[8] = 0x30 | 6;
        assert_eq!(decode_stream(&bad_method, 1 << 20), Err(Lz4Error::Corrupt));
    }
}
