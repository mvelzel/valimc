//! Encoded proto chunks (VMC-025d): a chunk at status `terrain` or
//! `features` as an immutable binary that live generation keeps, passes
//! between owners and writes to the proto log. It holds everything a later
//! decoration or the full chunk reads: blocks and chunk biomes (as a column
//! image), all six heightmaps (the worldgen two stay frozen at the terrain's,
//! so they cannot be recomputed from the blocks), post-processing marks,
//! scheduled ticks, block entity positions and created block entities.
//!
//! Layout (big-endian), version 2 (VMC-026b): version, chunk x and z, the
//! dimension's bottom Y and height, the column image's length and the image
//! (the dimension's sections of states, then of biome registry ids), 6 × 256
//! heightmap heights above the bottom, then counted lists of marks, block
//! ticks, fluid ticks, block entity positions, created block entities (with
//! an end gateway's exit) and the entities features added. A position inside
//! the chunk is one byte `z << 4 | x` and a two-byte Y. Version 1 (VMC-025d)
//! held overworld chunks without bounds, exits or entities. Version 3
//! (VMC-025f5) adds each created block entity's template NBT (a
//! four-byte-length string) and allows every block entity and entity type
//! structures place. Version 4 (VMC-025f6) ends with the structure pieces
//! that have placed what they place once: a count, then each structure id,
//! start chunk x and z and piece index.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use super::blocks::{BlockTable, Heightmap};
use super::region::{BlockEntityData, Entity, PlacedOnce, ProtoChunk, HEIGHT, MIN_Y};
use crate::column::{image_of_cells, Column};
use crate::section::{index as section_index, VOLUME};

const VERSION: u8 = 4;

/// The binary form of `chunk`.
pub fn encode(chunk: &ProtoChunk) -> Vec<u8> {
    let rows = chunk.height as usize;
    let sections = rows / 16;
    // Sections in index order (y, z, x), from the chunk's Y-fastest columns.
    let mut cells = vec![0u16; sections * VOLUME];
    for z in 0..16 {
        for x in 0..16 {
            let column = &chunk.blocks[(x + z * 16) * rows..(x + z * 16 + 1) * rows];
            for (y, &state) in column.iter().enumerate() {
                cells[(y / 16) * VOLUME + section_index(x, y % 16, z)] = state;
            }
        }
    }
    let mut biomes = chunk.biomes.chunks(64);
    let image = image_of_cells(cells.chunks(VOLUME), Some(&mut biomes));

    let mut out = Vec::with_capacity(image.len() + 4096);
    out.push(VERSION);
    out.extend(chunk.x.to_be_bytes());
    out.extend(chunk.z.to_be_bytes());
    out.extend(chunk.min_y.to_be_bytes());
    out.extend((chunk.height as u16).to_be_bytes());
    out.extend((image.len() as u32).to_be_bytes());
    out.extend(&image);
    for kind in Heightmap::ALL {
        for column in 0..256 {
            let height = chunk.height(kind, column & 15, column >> 4);
            out.extend(((height - chunk.min_y) as u16).to_be_bytes());
        }
    }
    let position = |out: &mut Vec<u8>, p: &[i32; 3]| {
        out.push(((p[2] & 15) << 4 | (p[0] & 15)) as u8);
        out.extend((p[1] as i16).to_be_bytes());
    };
    out.extend((chunk.marks.len() as u32).to_be_bytes());
    for p in &chunk.marks {
        position(&mut out, p);
    }
    out.extend((chunk.block_ticks.len() as u32).to_be_bytes());
    for (p, block) in &chunk.block_ticks {
        position(&mut out, p);
        out.extend(block.to_be_bytes());
    }
    out.extend((chunk.fluid_ticks.len() as u32).to_be_bytes());
    for (p, fluid) in &chunk.fluid_ticks {
        position(&mut out, p);
        out.push(*fluid);
    }
    out.extend((chunk.block_entities.len() as u32).to_be_bytes());
    for p in &chunk.block_entities {
        position(&mut out, p);
    }
    out.extend((chunk.block_entity_data.len() as u32).to_be_bytes());
    for (p, data) in &chunk.block_entity_data {
        position(&mut out, p);
        string(&mut out, Some(data.kind));
        string(&mut out, data.loot_table.as_deref());
        out.extend(data.loot_seed.to_be_bytes());
        string(&mut out, data.spawner_entity.as_deref());
        out.push(data.bees.len() as u8);
        for ticks in &data.bees {
            out.extend(ticks.to_be_bytes());
        }
        match data.exit {
            None => out.push(0),
            Some((exit, exact)) => {
                out.push(1 + exact as u8);
                for c in exit {
                    out.extend(c.to_be_bytes());
                }
            }
        }
        match &data.nbt {
            None => out.extend(u32::MAX.to_be_bytes()),
            Some(nbt) => {
                out.extend((nbt.len() as u32).to_be_bytes());
                out.extend(nbt.as_bytes());
            }
        }
    }
    out.extend((chunk.entities.len() as u32).to_be_bytes());
    for entity in &chunk.entities {
        string(&mut out, Some(entity.kind));
        for c in entity.pos {
            out.extend(c.to_be_bytes());
        }
        out.extend(entity.yaw.to_be_bytes());
    }
    out.extend((chunk.placed_once.len() as u32).to_be_bytes());
    for placed in &chunk.placed_once {
        string(&mut out, Some(&placed.structure));
        out.extend(placed.start.0.to_be_bytes());
        out.extend(placed.start.1.to_be_bytes());
        out.extend(placed.piece.to_be_bytes());
    }
    out
}

fn string(out: &mut Vec<u8>, value: Option<&str>) {
    match value {
        Some(s) => {
            out.extend((s.len() as u16).to_be_bytes());
            out.extend(s.as_bytes());
        }
        None => out.extend(u16::MAX.to_be_bytes()),
    }
}

struct Reader<'a> {
    input: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let (head, rest) = self
            .input
            .split_at_checked(n)
            .ok_or("a proto chunk ends early")?;
        self.input = rest;
        Ok(head)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn i32(&mut self) -> Result<i32, String> {
        Ok(i32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn i64(&mut self) -> Result<i64, String> {
        Ok(i64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn f64(&mut self) -> Result<f64, String> {
        Ok(f64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn f32(&mut self) -> Result<f32, String> {
        Ok(f32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    /// A count whose entries take at least `entry` bytes each.
    fn count(&mut self, entry: usize) -> Result<usize, String> {
        let n = self.u32()? as usize;
        if n.saturating_mul(entry) > self.input.len() {
            return Err("a proto chunk list is longer than its data".into());
        }
        Ok(n)
    }

    fn position(
        &mut self,
        x: i32,
        z: i32,
        (min_y, height): (i32, i32),
    ) -> Result<[i32; 3], String> {
        let xz = self.u8()? as i32;
        let y = self.u16()? as i16 as i32;
        if !(min_y..min_y + height).contains(&y) {
            return Err("a proto chunk position outside the build height".into());
        }
        Ok([x * 16 + (xz & 15), y, z * 16 + (xz >> 4)])
    }

    /// A string with a four-byte length (template NBT).
    fn long_string(&mut self) -> Result<Option<String>, String> {
        match self.u32()? {
            u32::MAX => Ok(None),
            n => {
                let bytes = self.take(n as usize)?;
                Ok(Some(
                    String::from_utf8(bytes.to_vec()).map_err(|_| "a proto chunk string")?,
                ))
            }
        }
    }

    fn string(&mut self) -> Result<Option<String>, String> {
        match self.u16()? {
            u16::MAX => Ok(None),
            n => {
                let bytes = self.take(n as usize)?;
                Ok(Some(
                    String::from_utf8(bytes.to_vec()).map_err(|_| "a proto chunk string")?,
                ))
            }
        }
    }
}

/// Read `encode` output (versions 1 to 3); every state must be one of
/// `table`'s.
pub fn decode(bytes: &[u8], table: &BlockTable) -> Result<ProtoChunk, String> {
    let mut r = Reader { input: bytes };
    let version = r.u8()?;
    if !(1..=VERSION).contains(&version) {
        return Err("unknown proto chunk version".into());
    }
    let (x, z) = (r.i32()?, r.i32()?);
    let (min_y, height) = if version == 1 {
        (MIN_Y, HEIGHT)
    } else {
        (r.i32()?, r.u16()? as i32)
    };
    if height <= 0 || height % 16 != 0 || height > HEIGHT {
        return Err("a proto chunk's height".into());
    }
    let bounds = (min_y, height);
    let rows = height as usize;
    let sections = rows / 16;
    let length = r.u32()? as usize;
    let column = Column::from_image_sections(r.take(length)?, sections)
        .ok_or("a proto chunk's column image")?;
    let states = table.block_of.len();
    let mut blocks = vec![0u16; rows * 256];
    let mut valid = true;
    for (s, section) in column.sections.iter().enumerate() {
        section.for_each(|i, state| {
            let (sx, y, sz) = (i & 15, i >> 8, (i >> 4) & 15);
            valid &= (state as usize) < states;
            blocks[s * 16 + y + (sx + sz * 16) * rows] = state;
        });
    }
    if !valid || column.sections.len() != sections {
        return Err("a proto chunk state outside the registry".into());
    }
    let section_biomes = column.biomes.ok_or("a proto chunk without biomes")?;
    let mut biomes = Vec::with_capacity(sections * 64);
    for section in &section_biomes {
        biomes.extend((0..64).map(|i| section.get(i)));
    }
    let mut non_air = [0u16; super::region::MAX_SECTIONS];
    for column in 0..256 {
        for y in 0..rows {
            if !table.is_air(blocks[column * rows + y]) {
                non_air[y / 16] += 1;
            }
        }
    }
    let mut heightmaps: [Box<[i32; 256]>; 6] = std::array::from_fn(|_| Box::new([min_y; 256]));
    for map in heightmaps.iter_mut() {
        for first_free in map.iter_mut() {
            let h = r.u16()? as i32;
            if h > height {
                return Err("a proto chunk height above the world".into());
            }
            *first_free = min_y + h;
        }
    }
    let mut marks = BTreeSet::new();
    for _ in 0..r.count(3)? {
        marks.insert(r.position(x, z, bounds)?);
    }
    let mut block_ticks = BTreeSet::new();
    for _ in 0..r.count(5)? {
        let p = r.position(x, z, bounds)?;
        let block = r.u16()?;
        if block as usize >= table.names.len() {
            return Err("a proto chunk tick of an unknown block".into());
        }
        block_ticks.insert((p, block));
    }
    let mut fluid_ticks = BTreeSet::new();
    for _ in 0..r.count(4)? {
        let p = r.position(x, z, bounds)?;
        fluid_ticks.insert((p, r.u8()?));
    }
    let mut block_entities = BTreeSet::new();
    for _ in 0..r.count(3)? {
        block_entities.insert(r.position(x, z, bounds)?);
    }
    let mut block_entity_data = BTreeMap::new();
    for _ in 0..r.count(16)? {
        let p = r.position(x, z, bounds)?;
        let name = r.string()?.ok_or("a block entity without a type")?;
        let kind = super::region::entity_kind(&name);
        let loot_table = r.string()?;
        let loot_seed = r.i64()?;
        let spawner_entity = r.string()?;
        let bees = (0..r.u8()?).map(|_| r.i32()).collect::<Result<_, _>>()?;
        let exit = match if version == 1 { 0 } else { r.u8()? } {
            0 => None,
            tag @ (1 | 2) => Some(([r.i32()?, r.i32()?, r.i32()?], tag == 2)),
            _ => return Err("a proto chunk gateway exit".into()),
        };
        let nbt = if version >= 3 {
            r.long_string()?.map(Arc::from)
        } else {
            None
        };
        block_entity_data.insert(
            p,
            BlockEntityData {
                kind,
                loot_table,
                loot_seed,
                spawner_entity,
                bees,
                exit,
                nbt,
            },
        );
    }
    let mut entities = Vec::new();
    if version >= 2 {
        for _ in 0..r.count(30)? {
            let name = r.string()?.ok_or("an entity without a type")?;
            let kind = super::region::entity_kind(&name);
            let pos = [r.f64()?, r.f64()?, r.f64()?];
            entities.push(Entity {
                kind,
                pos,
                yaw: r.f32()?,
            });
        }
    }
    let mut placed_once = BTreeSet::new();
    if version >= 4 {
        for _ in 0..r.count(14)? {
            let structure = r.string()?.ok_or("a placed piece without a structure")?;
            placed_once.insert(PlacedOnce {
                structure,
                start: (r.i32()?, r.i32()?),
                piece: r.u32()?,
            });
        }
    }
    if !r.input.is_empty() {
        return Err("a proto chunk has trailing bytes".into());
    }
    Ok(ProtoChunk {
        x,
        z,
        min_y,
        height,
        blocks,
        biomes: Arc::new(biomes),
        heightmaps,
        non_air,
        marks,
        block_ticks,
        fluid_ticks,
        block_entities,
        block_entity_data,
        entities,
        placed_once,
        touched: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_strings_round_trip() {
        let mut out = Vec::new();
        let nbt = "x".repeat(70_000);
        out.extend((nbt.len() as u32).to_be_bytes());
        out.extend(nbt.as_bytes());
        out.extend(u32::MAX.to_be_bytes());
        let mut r = Reader { input: &out };
        assert_eq!(r.long_string().unwrap().as_deref(), Some(nbt.as_str()));
        assert_eq!(r.long_string().unwrap(), None);
    }
}
