//! Disk NBT reading (VMC-020): a bounded parser that reports values to a
//! `Visitor`, so the NIF builds Erlang terms without an intermediate tree.
//!
//! It mirrors `Valimc.NBT.read/2` exactly, including which error a malformed
//! input reports: a named compound root (name skipped), vanilla's container
//! limit, a node limit, Java modified UTF-8, and no trailing bytes. A repeated
//! compound name is reported twice; the visitor keeps the last (vanilla's rule).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NbtError {
    ByteLimit,
    NodeLimit,
    DepthLimit,
    Truncated,
    UnknownTag,
    InvalidList,
    InvalidArrayLength,
    InvalidUtf,
    RootNotCompound,
    Trailing,
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub bytes: usize,
    pub nodes: i64,
    pub depth: u32,
}

/// A string value: a range of the input that is already UTF-8, or a decoded copy.
pub enum Text {
    Slice(usize, usize),
    Owned(String),
}

pub trait Visitor {
    type Value;
    /// Byte, short, int and long tags (ids 1..=4).
    fn int(&mut self, value: i64) -> Self::Value;
    /// Float and double bits and dense arrays (ids 5, 6, 7, 11, 12): `len` input bytes at `start`.
    fn raw(&mut self, start: usize, len: usize) -> Self::Value;
    fn string(&mut self, text: Text) -> Self::Value;
    fn list(&mut self, element: u8, items: Vec<Self::Value>) -> Self::Value;
    /// Entries in input order as (name, tag id, value).
    fn compound(&mut self, entries: Vec<(Self::Value, u8, Self::Value)>) -> Self::Value;
}

struct Reader<'a, V> {
    input: &'a [u8],
    pos: usize,
    nodes: i64,
    depth_limit: u32,
    byte_limit: usize,
    visitor: &'a mut V,
}

/// Read an uncompressed world-file root; returns the root compound's value.
pub fn read<V: Visitor>(
    input: &[u8],
    limits: Limits,
    visitor: &mut V,
) -> Result<V::Value, NbtError> {
    if input.len() > limits.bytes {
        return Err(NbtError::ByteLimit);
    }
    match input.first() {
        Some(10) => {}
        _ => return Err(NbtError::RootNotCompound),
    }
    if input.len() < 3 {
        return Err(NbtError::Truncated);
    }
    let name = u16::from_be_bytes([input[1], input[2]]) as usize;
    if input.len() < 3 + name {
        return Err(NbtError::Truncated);
    }
    let mut reader = Reader {
        input,
        pos: 3 + name,
        nodes: limits.nodes - 1,
        depth_limit: limits.depth,
        byte_limit: limits.bytes,
        visitor,
    };
    let value = reader.compound(0)?;
    if reader.pos != input.len() {
        return Err(NbtError::Trailing);
    }
    Ok(value)
}

impl<'a, V: Visitor> Reader<'a, V> {
    fn take(&mut self, n: usize) -> Result<usize, NbtError> {
        let start = self.pos;
        if self.input.len() - start < n {
            return Err(NbtError::Truncated);
        }
        self.pos += n;
        Ok(start)
    }

    fn bytes<const N: usize>(&mut self) -> Result<[u8; N], NbtError> {
        let start = self.take(N)?;
        Ok(self.input[start..start + N].try_into().unwrap())
    }

    fn enter(&self, depth: u32) -> Result<u32, NbtError> {
        if depth < self.depth_limit {
            Ok(depth + 1)
        } else {
            Err(NbtError::DepthLimit)
        }
    }

    fn value(&mut self, id: u8, depth: u32) -> Result<V::Value, NbtError> {
        Ok(match id {
            1 => {
                let value = i8::from_be_bytes(self.bytes()?) as i64;
                self.visitor.int(value)
            }
            2 => {
                let value = i16::from_be_bytes(self.bytes()?) as i64;
                self.visitor.int(value)
            }
            3 => {
                let value = i32::from_be_bytes(self.bytes()?) as i64;
                self.visitor.int(value)
            }
            4 => {
                let value = i64::from_be_bytes(self.bytes()?);
                self.visitor.int(value)
            }
            5 => {
                let start = self.take(4)?;
                self.visitor.raw(start, 4)
            }
            6 => {
                let start = self.take(8)?;
                self.visitor.raw(start, 8)
            }
            7 | 11 | 12 => {
                let count = i32::from_be_bytes(self.bytes()?);
                if count < 0 {
                    return Err(NbtError::InvalidArrayLength);
                }
                let size = count as usize
                    * if id == 7 {
                        1
                    } else if id == 11 {
                        4
                    } else {
                        8
                    };
                if size > self.byte_limit {
                    return Err(NbtError::ByteLimit);
                }
                let start = self.take(size)?;
                self.visitor.raw(start, size)
            }
            8 => {
                let text = self.string()?;
                self.visitor.string(text)
            }
            9 => {
                if self.input.len() - self.pos < 5 {
                    return Err(NbtError::Truncated);
                }
                let depth = self.enter(depth)?;
                let [element] = self.bytes::<1>()?;
                let count = i32::from_be_bytes(self.bytes()?);
                if element > 12 {
                    return Err(NbtError::UnknownTag);
                }
                if count < 0 || (element == 0 && count > 0) {
                    return Err(NbtError::InvalidList);
                }
                self.nodes -= count as i64;
                if self.nodes < 0 {
                    return Err(NbtError::NodeLimit);
                }
                let mut items = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    items.push(self.value(element, depth)?);
                }
                self.visitor.list(element, items)
            }
            10 => self.compound(depth)?,
            _ => return Err(NbtError::UnknownTag),
        })
    }

    fn compound(&mut self, depth: u32) -> Result<V::Value, NbtError> {
        let depth = self.enter(depth)?;
        let mut entries = Vec::new();
        loop {
            let [id] = self.bytes::<1>()?;
            if id == 0 {
                return Ok(self.visitor.compound(entries));
            }
            if id > 12 {
                return Err(NbtError::UnknownTag);
            }
            let text = self.string()?;
            let name = self.visitor.string(text);
            self.nodes -= 1;
            if self.nodes < 0 {
                return Err(NbtError::NodeLimit);
            }
            let value = self.value(id, depth)?;
            entries.push((name, id, value));
        }
    }

    fn string(&mut self) -> Result<Text, NbtError> {
        let size = u16::from_be_bytes(self.bytes()?) as usize;
        let start = self.take(size)?;
        let raw = &self.input[start..start + size];
        if raw.iter().all(|&b| b < 0xF0) && std::str::from_utf8(raw).is_ok() {
            return Ok(Text::Slice(start, size));
        }
        decode_modified(raw).map(Text::Owned)
    }
}

/// Java `DataInput.readUTF`: one-, two- and three-byte forms of UTF-16 units (no
/// overlong checks, as Java), then UTF-16. Unpaired surrogates are refused.
pub fn decode_modified(raw: &[u8]) -> Result<String, NbtError> {
    let mut units = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        let b = raw[i];
        if b < 0x80 {
            units.push(b as u16);
            i += 1;
        } else if (0xC0..=0xDF).contains(&b) && i + 1 < raw.len() && raw[i + 1] & 0xC0 == 0x80 {
            units.push(((b as u16 & 31) << 6) | (raw[i + 1] as u16 & 63));
            i += 2;
        } else if (0xE0..=0xEF).contains(&b)
            && i + 2 < raw.len()
            && raw[i + 1] & 0xC0 == 0x80
            && raw[i + 2] & 0xC0 == 0x80
        {
            units.push(
                ((b as u16 & 15) << 12)
                    | ((raw[i + 1] as u16 & 63) << 6)
                    | (raw[i + 2] as u16 & 63),
            );
            i += 3;
        } else {
            return Err(NbtError::InvalidUtf);
        }
    }
    String::from_utf16(&units).map_err(|_| NbtError::InvalidUtf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A visitor that renders values as text, for checking structure.
    struct Show<'a>(&'a [u8]);

    impl Visitor for Show<'_> {
        type Value = String;
        fn int(&mut self, value: i64) -> String {
            value.to_string()
        }
        fn raw(&mut self, start: usize, len: usize) -> String {
            format!("{:?}", &self.0[start..start + len])
        }
        fn string(&mut self, text: Text) -> String {
            match text {
                Text::Slice(start, len) => {
                    String::from_utf8(self.0[start..start + len].to_vec()).unwrap()
                }
                Text::Owned(s) => s,
            }
        }
        fn list(&mut self, element: u8, items: Vec<String>) -> String {
            format!("{element}[{}]", items.join(","))
        }
        fn compound(&mut self, entries: Vec<(String, u8, String)>) -> String {
            let parts: Vec<String> = entries
                .into_iter()
                .map(|(k, id, v)| format!("{k}:{id}={v}"))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }

    const LIMITS: Limits = Limits {
        bytes: 1 << 20,
        nodes: 1000,
        depth: 512,
    };

    fn read_show(input: &[u8], limits: Limits) -> Result<String, NbtError> {
        let mut show = Show(input);
        read(input, limits, &mut show)
    }

    #[test]
    fn reads_every_tag_kind() {
        let mut input = vec![10, 0, 4, b'r', b'o', b'o', b't'];
        input.extend([1, 0, 1, b'b', 0xFF]);
        input.extend([4, 0, 1, b'l', 0, 0, 0, 0, 0, 0, 0, 7]);
        input.extend([9, 0, 1, b'i', 3, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2]);
        input.extend([12, 0, 1, b'a', 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8]);
        input.extend([8, 0, 1, b's', 0, 2, 0xC0, 0x80]);
        input.extend([10, 0, 1, b'c', 0, 0]);
        assert_eq!(
            read_show(&input, LIMITS).unwrap(),
            "{b:1=-1,l:4=7,i:9=3[1,2],a:12=[1, 2, 3, 4, 5, 6, 7, 8],s:8=\u{0},c:10={}}"
        );
    }

    #[test]
    fn modified_utf8_surrogate_pairs_and_refusals() {
        assert_eq!(
            decode_modified(&[0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]).unwrap(),
            "😀"
        );
        assert_eq!(decode_modified(&[0xC1, 0x81]).unwrap(), "A");
        assert_eq!(
            decode_modified(&[0xED, 0xA0, 0x80]),
            Err(NbtError::InvalidUtf)
        );
        assert_eq!(
            decode_modified(&[0xF0, 0x9F, 0x98, 0x80]),
            Err(NbtError::InvalidUtf)
        );
        assert_eq!(decode_modified(&[0xC3]), Err(NbtError::InvalidUtf));
    }

    #[test]
    fn limits_and_malformed_inputs() {
        let ok = [10, 0, 0, 3, 0, 1, b'x', 0, 0, 0, 5, 0];
        assert!(read_show(&ok, LIMITS).is_ok());
        assert_eq!(
            read_show(&ok, Limits { bytes: 5, ..LIMITS }),
            Err(NbtError::ByteLimit)
        );
        assert_eq!(
            read_show(&ok, Limits { nodes: 1, ..LIMITS }),
            Err(NbtError::NodeLimit)
        );
        assert_eq!(
            read_show(&ok, Limits { depth: 0, ..LIMITS }),
            Err(NbtError::DepthLimit)
        );
        assert_eq!(
            read_show(&[3, 0, 0, 0, 0, 0, 5], LIMITS),
            Err(NbtError::RootNotCompound)
        );
        assert_eq!(read_show(&[], LIMITS), Err(NbtError::RootNotCompound));
        assert_eq!(read_show(&[10, 0], LIMITS), Err(NbtError::Truncated));
        let mut trailing = ok.to_vec();
        trailing.push(0);
        assert_eq!(read_show(&trailing, LIMITS), Err(NbtError::Trailing));
        for cut in 0..ok.len() {
            assert!(read_show(&ok[..cut], LIMITS).is_err());
        }
        assert_eq!(
            read_show(&[10, 0, 0, 13, 0, 0, 0], LIMITS),
            Err(NbtError::UnknownTag)
        );
        assert_eq!(
            read_show(&[10, 0, 0, 9, 0, 0, 0, 0, 0, 0, 1, 0], LIMITS),
            Err(NbtError::InvalidList)
        );
        assert_eq!(
            read_show(&[10, 0, 0, 9, 0, 0, 3, 255, 255, 255, 255, 0], LIMITS),
            Err(NbtError::InvalidList)
        );
        assert_eq!(
            read_show(&[10, 0, 0, 11, 0, 0, 255, 255, 255, 255, 0], LIMITS),
            Err(NbtError::InvalidArrayLength)
        );
    }

    #[test]
    fn depth_counts_containers_including_the_root() {
        // Root plus 511 nested lists: 512 containers.
        let nested = |lists: usize| {
            let mut input = vec![10, 0, 0, 9, 0, 0];
            for _ in 1..lists {
                input.extend([9, 0, 0, 0, 1]);
            }
            input.extend([0, 0, 0, 0, 0]);
            input.push(0);
            input
        };
        assert!(read_show(&nested(511), LIMITS).is_ok());
        assert_eq!(read_show(&nested(512), LIMITS), Err(NbtError::DepthLimit));
    }
}
