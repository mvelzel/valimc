//! Encoded proto chunks (VMC-025d): a chunk at status `terrain` or
//! `features` as an immutable binary that live generation keeps, passes
//! between owners and writes to the proto log. It holds everything a later
//! decoration or the full chunk reads: blocks and chunk biomes (as a column
//! image), all six heightmaps (the worldgen two stay frozen at the terrain's,
//! so they cannot be recomputed from the blocks), post-processing marks,
//! scheduled ticks, block entity positions and created block entities.
//!
//! Layout (big-endian): version, chunk x and z, the column image's length and
//! the image (24 sections of states, then 24 sections of biome registry ids),
//! 6 × 256 heightmap heights above the bottom, then counted lists of marks,
//! block ticks, fluid ticks, block entity positions and created block
//! entities. A position inside the chunk is one byte `z << 4 | x` and a
//! two-byte Y.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use super::blocks::{BlockTable, Heightmap};
use super::region::{BlockEntityData, ProtoChunk, HEIGHT, MIN_Y};
use crate::column::{image_of_cells, Column};
use crate::section::{index as section_index, VOLUME};

const VERSION: u8 = 1;
const SECTIONS: usize = (HEIGHT / 16) as usize;
const COLUMN: usize = HEIGHT as usize;

/// The binary form of `chunk`, an overworld chunk (live generation holds the
/// overworld only; the other dimensions' bounds, entities and gateway exits
/// wait for VMC-026b).
pub fn encode(chunk: &ProtoChunk) -> Vec<u8> {
    assert_eq!(
        (chunk.min_y, chunk.height),
        (MIN_Y, HEIGHT),
        "proto chunks hold the overworld's bounds"
    );
    // Sections in index order (y, z, x), from the chunk's Y-fastest columns.
    let mut cells = vec![0u16; SECTIONS * VOLUME];
    for z in 0..16 {
        for x in 0..16 {
            let column = &chunk.blocks[(x + z * 16) * COLUMN..(x + z * 16 + 1) * COLUMN];
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
    out.extend((image.len() as u32).to_be_bytes());
    out.extend(&image);
    for kind in Heightmap::ALL {
        for column in 0..256 {
            let height = chunk.height(kind, column & 15, column >> 4);
            out.extend(((height - MIN_Y) as u16).to_be_bytes());
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

    /// A count whose entries take at least `entry` bytes each.
    fn count(&mut self, entry: usize) -> Result<usize, String> {
        let n = self.u32()? as usize;
        if n.saturating_mul(entry) > self.input.len() {
            return Err("a proto chunk list is longer than its data".into());
        }
        Ok(n)
    }

    fn position(&mut self, x: i32, z: i32) -> Result<[i32; 3], String> {
        let xz = self.u8()? as i32;
        let y = self.u16()? as i16 as i32;
        if !(MIN_Y..MIN_Y + HEIGHT).contains(&y) {
            return Err("a proto chunk position outside the build height".into());
        }
        Ok([x * 16 + (xz & 15), y, z * 16 + (xz >> 4)])
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

/// Read `encode` output; every state must be one of `table`'s.
pub fn decode(bytes: &[u8], table: &BlockTable) -> Result<ProtoChunk, String> {
    let mut r = Reader { input: bytes };
    if r.u8()? != VERSION {
        return Err("unknown proto chunk version".into());
    }
    let (x, z) = (r.i32()?, r.i32()?);
    let length = r.u32()? as usize;
    let column = Column::from_image(r.take(length)?).ok_or("a proto chunk's column image")?;
    let states = table.block_of.len();
    let mut blocks = vec![0u16; COLUMN * 256];
    let mut valid = true;
    for (s, section) in column.sections.iter().enumerate() {
        section.for_each(|i, state| {
            let (sx, y, sz) = (i & 15, i >> 8, (i >> 4) & 15);
            valid &= (state as usize) < states;
            blocks[s * 16 + y + (sx + sz * 16) * COLUMN] = state;
        });
    }
    if !valid || column.sections.len() != SECTIONS {
        return Err("a proto chunk state outside the registry".into());
    }
    let section_biomes = column.biomes.ok_or("a proto chunk without biomes")?;
    let mut biomes = Vec::with_capacity(SECTIONS * 64);
    for section in &section_biomes {
        biomes.extend((0..64).map(|i| section.get(i)));
    }
    let mut non_air = [0u16; SECTIONS];
    for column in 0..256 {
        for y in 0..COLUMN {
            if !table.is_air(blocks[column * COLUMN + y]) {
                non_air[y / 16] += 1;
            }
        }
    }
    let mut heightmaps: [Box<[i32; 256]>; 6] = std::array::from_fn(|_| Box::new([MIN_Y; 256]));
    for map in heightmaps.iter_mut() {
        for height in map.iter_mut() {
            let h = r.u16()? as i32;
            if h > HEIGHT {
                return Err("a proto chunk height above the world".into());
            }
            *height = MIN_Y + h;
        }
    }
    let mut marks = BTreeSet::new();
    for _ in 0..r.count(3)? {
        marks.insert(r.position(x, z)?);
    }
    let mut block_ticks = BTreeSet::new();
    for _ in 0..r.count(5)? {
        let p = r.position(x, z)?;
        let block = r.u16()?;
        if block as usize >= table.names.len() {
            return Err("a proto chunk tick of an unknown block".into());
        }
        block_ticks.insert((p, block));
    }
    let mut fluid_ticks = BTreeSet::new();
    for _ in 0..r.count(4)? {
        let p = r.position(x, z)?;
        fluid_ticks.insert((p, r.u8()?));
    }
    let mut block_entities = BTreeSet::new();
    for _ in 0..r.count(3)? {
        block_entities.insert(r.position(x, z)?);
    }
    let mut block_entity_data = BTreeMap::new();
    for _ in 0..r.count(16)? {
        let p = r.position(x, z)?;
        let name = r.string()?.ok_or("a block entity without a type")?;
        let kind = KINDS
            .iter()
            .find(|k| **k == name)
            .copied()
            .ok_or("a block entity type decoration does not create")?;
        let loot_table = r.string()?;
        let loot_seed = r.i64()?;
        let spawner_entity = r.string()?;
        let bees = (0..r.u8()?).map(|_| r.i32()).collect::<Result<_, _>>()?;
        block_entity_data.insert(
            p,
            BlockEntityData {
                kind,
                loot_table,
                loot_seed,
                spawner_entity,
                bees,
                exit: None,
            },
        );
    }
    if !r.input.is_empty() {
        return Err("a proto chunk has trailing bytes".into());
    }
    Ok(ProtoChunk {
        x,
        z,
        min_y: MIN_Y,
        height: HEIGHT,
        blocks,
        biomes: Arc::new(biomes),
        heightmaps,
        non_air,
        marks,
        block_ticks,
        fluid_ticks,
        block_entities,
        block_entity_data,
        entities: Vec::new(),
        touched: false,
    })
}

/// The block entity types decoration creates.
const KINDS: [&str; 5] = [
    "minecraft:chest",
    "minecraft:trapped_chest",
    "minecraft:mob_spawner",
    "minecraft:beehive",
    "minecraft:brushable_block",
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worldgen::region::block_entity_kind;

    #[test]
    fn kinds_cover_every_created_block_entity() {
        for name in [
            "minecraft:chest",
            "minecraft:trapped_chest",
            "minecraft:spawner",
            "minecraft:bee_nest",
            "minecraft:beehive",
            "minecraft:suspicious_sand",
            "minecraft:suspicious_gravel",
        ] {
            assert!(KINDS.contains(&block_entity_kind(name).unwrap()));
        }
    }
}
