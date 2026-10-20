//! The features step's world (VMC-025): proto chunks at status `terrain`
//! (vanilla's `ProtoChunk`) and the region a chunk is decorated through
//! (`WorldGenRegion`): a 3 × 3 write zone around the centre, block reads up to
//! the area's bounds, chunk biomes of the 3 × 3 through the fuzzy zoom,
//! heightmaps, post-processing marks, scheduled ticks and pending block
//! entities.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use super::blocks::{BlockTable, Heightmap, BLOCK_ENTITY, POST_PROCESS, POST_PROCESS_ABOVE};
use super::random::Random;
use super::surface::ChunkZoom;

pub const MIN_Y: i32 = -64;
pub const HEIGHT: i32 = 384;
const SECTIONS: usize = (HEIGHT / 16) as usize;

/// A proto chunk after the terrain step.
#[derive(Clone)]
pub struct ProtoChunk {
    pub x: i32,
    pub z: i32,
    /// States, Y fastest from `MIN_Y`, then X, then Z.
    pub blocks: Vec<u16>,
    /// Biome registry ids: per section from the bottom, 64 in (y, z, x) order.
    pub biomes: Arc<Vec<u16>>,
    /// Per heightmap type, per column (z * 16 + x): the first free Y.
    heightmaps: [Box<[i32; 256]>; 6],
    /// Per section, its non-air blocks (`LevelChunkSection.hasOnlyAir`).
    non_air: [u16; SECTIONS],
    pub marks: BTreeSet<[i32; 3]>,
    /// Scheduled ticks, unique per position and type: block ids and fluid ids.
    pub block_ticks: BTreeSet<([i32; 3], u16)>,
    pub fluid_ticks: BTreeSet<([i32; 3], u8)>,
    /// Positions with a block entity, pending (vanilla's "DUMMY" entries)
    /// or created.
    pub block_entities: BTreeSet<[i32; 3]>,
    /// The block entities a feature asked for (`getBlockEntity` creates them
    /// from the pending entries), with what features write into them.
    pub block_entity_data: BTreeMap<[i32; 3], BlockEntityData>,
}

/// A created block entity (VMC-025c): its type and what decoration writes
/// into it (a container's loot table and seed, a spawner's entity).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockEntityData {
    pub kind: &'static str,
    pub loot_table: Option<String>,
    pub loot_seed: i64,
    pub spawner_entity: Option<String>,
}

/// The block entity type a block creates, for the blocks decoration fills.
fn block_entity_kind(name: &str) -> Option<&'static str> {
    Some(match name {
        "minecraft:chest" => "minecraft:chest",
        "minecraft:trapped_chest" => "minecraft:trapped_chest",
        "minecraft:spawner" => "minecraft:mob_spawner",
        "minecraft:bee_nest" | "minecraft:beehive" => "minecraft:beehive",
        "minecraft:suspicious_sand" | "minecraft:suspicious_gravel" => "minecraft:brushable_block",
        _ => return None,
    })
}

fn index(x: i32, y: i32, z: i32) -> usize {
    ((y - MIN_Y) + ((x & 15) + (z & 15) * 16) * HEIGHT) as usize
}

impl ProtoChunk {
    /// A chunk from its terrain, with every heightmap primed from it (the
    /// worldgen ones as the terrain step leaves them, the final ones as it
    /// primes them).
    pub fn new(
        x: i32,
        z: i32,
        blocks: Vec<u16>,
        biomes: Arc<Vec<u16>>,
        table: &BlockTable,
    ) -> ProtoChunk {
        let mut non_air = [0u16; SECTIONS];
        for column in 0..256 {
            for y in 0..HEIGHT as usize {
                if !table.is_air(blocks[column * HEIGHT as usize + y]) {
                    non_air[y / 16] += 1;
                }
            }
        }
        let mut chunk = ProtoChunk {
            x,
            z,
            blocks,
            biomes,
            heightmaps: std::array::from_fn(|_| Box::new([MIN_Y; 256])),
            non_air,
            marks: BTreeSet::new(),
            block_ticks: BTreeSet::new(),
            fluid_ticks: BTreeSet::new(),
            block_entities: BTreeSet::new(),
            block_entity_data: BTreeMap::new(),
        };
        for kind in Heightmap::ALL {
            for column in 0..256 {
                let base = column * HEIGHT as usize;
                let top = (0..HEIGHT as usize)
                    .rev()
                    .find(|&y| table.heightmap(chunk.blocks[base + y], kind));
                chunk.heightmaps[kind as usize][column] = match top {
                    Some(y) => MIN_Y + y as i32 + 1,
                    None => MIN_Y,
                };
            }
        }
        chunk
    }

    pub fn get(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        if !(MIN_Y..MIN_Y + HEIGHT).contains(&y) {
            return None;
        }
        Some(self.blocks[index(x, y, z)])
    }

    /// The first free Y of a column (`getHeight + 1`).
    pub fn height(&self, kind: Heightmap, x: i32, z: i32) -> i32 {
        self.heightmaps[kind as usize][((x & 15) + (z & 15) * 16) as usize]
    }

    /// `ProtoChunk.setBlockState` at status `terrain`; the previous state.
    pub fn set(
        &mut self,
        table: &BlockTable,
        x: i32,
        y: i32,
        z: i32,
        state: u16,
        air: u16,
    ) -> Option<u16> {
        if !(MIN_Y..MIN_Y + HEIGHT).contains(&y) {
            return None;
        }
        let section = ((y - MIN_Y) / 16) as usize;
        if self.non_air[section] == 0 && state == air {
            return Some(state);
        }
        let old = self.set_raw(table, x, y, z, state);
        for kind in [
            Heightmap::OceanFloor,
            Heightmap::WorldSurface,
            Heightmap::MotionBlocking,
            Heightmap::MotionBlockingNoLeaves,
        ] {
            self.update_heightmap(table, kind, x, y, z, state);
        }
        Some(old)
    }

    /// A section write without heightmaps (`LevelChunkSection.setBlockState`,
    /// as ore placement writes).
    pub fn set_raw(&mut self, table: &BlockTable, x: i32, y: i32, z: i32, state: u16) -> u16 {
        let i = index(x, y, z);
        let old = self.blocks[i];
        let section = ((y - MIN_Y) / 16) as usize;
        match (table.is_air(old), table.is_air(state)) {
            (true, false) => self.non_air[section] += 1,
            (false, true) => self.non_air[section] -= 1,
            _ => {}
        }
        self.blocks[i] = state;
        old
    }

    /// `Heightmap.update`.
    fn update_heightmap(
        &mut self,
        table: &BlockTable,
        kind: Heightmap,
        x: i32,
        y: i32,
        z: i32,
        state: u16,
    ) {
        let column = ((x & 15) + (z & 15) * 16) as usize;
        let first = self.heightmaps[kind as usize][column];
        if y <= first - 2 {
            return;
        }
        if table.heightmap(state, kind) {
            if y >= first {
                self.heightmaps[kind as usize][column] = y + 1;
            }
        } else if first - 1 == y {
            let base = column * HEIGHT as usize;
            let mut height = MIN_Y;
            for below in (MIN_Y..y).rev() {
                if table.heightmap(self.blocks[base + (below - MIN_Y) as usize], kind) {
                    height = below + 1;
                    break;
                }
            }
            self.heightmaps[kind as usize][column] = height;
        }
    }

    pub fn mark(&mut self, pos: [i32; 3]) {
        if (MIN_Y..MIN_Y + HEIGHT).contains(&pos[1]) {
            self.marks.insert(pos);
        }
    }
}

/// The chunks of a decoration area, `size` × `size` from (`x`, `z`).
pub struct Area {
    pub x: i32,
    pub z: i32,
    pub size: i32,
    pub chunks: Vec<ProtoChunk>,
}

impl Area {
    fn slot(&self, chunk_x: i32, chunk_z: i32) -> Option<usize> {
        let (dx, dz) = (chunk_x - self.x, chunk_z - self.z);
        if dx < 0 || dz < 0 || dx >= self.size || dz >= self.size {
            return None;
        }
        Some((dz * self.size + dx) as usize)
    }

    pub fn chunk(&self, chunk_x: i32, chunk_z: i32) -> Option<&ProtoChunk> {
        self.slot(chunk_x, chunk_z).map(|i| &self.chunks[i])
    }

    pub fn chunk_mut(&mut self, chunk_x: i32, chunk_z: i32) -> Option<&mut ProtoChunk> {
        self.slot(chunk_x, chunk_z)
            .map(move |i| &mut self.chunks[i])
    }
}

/// The world one chunk is decorated through (`WorldGenRegion`).
pub struct Region<'a> {
    pub area: &'a mut Area,
    pub table: &'a BlockTable,
    pub centre: (i32, i32),
    pub seed: i64,
    pub sea_level: i32,
    zoom: ChunkZoom,
    pub air: u16,
    pub void_air: u16,
    /// `WorldGenRegion.getRandom`: positional from the seed by the name
    /// `worldgen_region_random`, at the centre chunk's origin; features that
    /// ask the level for its random (mossy carpets) share it.
    pub random: Random,
    /// The first read or request vanilla would refuse (a chunk outside the
    /// area or a biome outside the 3 × 3); decoration fails with it.
    pub fault: Option<String>,
}

impl<'a> Region<'a> {
    pub fn new(
        area: &'a mut Area,
        table: &'a BlockTable,
        centre: (i32, i32),
        seed: i64,
        zoom_seed: i64,
        sea_level: i32,
    ) -> Result<Region<'a>, String> {
        Ok(Region {
            area,
            table,
            centre,
            seed,
            sea_level,
            zoom: ChunkZoom::new(zoom_seed, centre.0, centre.1, MIN_Y, HEIGHT),
            air: table.default_state("air")?,
            void_air: table.default_state("void_air")?,
            random: Random::xoroshiro(seed)
                .fork_positional()
                .from_hash_of("minecraft:worldgen_region_random")
                .fork_positional()
                .at(centre.0 * 16, 0, centre.1 * 16),
            fault: None,
        })
    }

    fn fail(&mut self, message: String) {
        if self.fault.is_none() {
            self.fault = Some(message);
        }
    }

    fn distance(&self, chunk_x: i32, chunk_z: i32) -> i32 {
        (chunk_x - self.centre.0)
            .abs()
            .max((chunk_z - self.centre.1).abs())
    }

    pub fn min_y(&self) -> i32 {
        MIN_Y
    }

    pub fn height(&self) -> i32 {
        HEIGHT
    }

    pub fn is_outside_build_height(&self, y: i32) -> bool {
        !(MIN_Y..MIN_Y + HEIGHT).contains(&y)
    }

    /// `getBlockState`.
    pub fn get(&mut self, pos: [i32; 3]) -> u16 {
        let (cx, cz) = (pos[0] >> 4, pos[2] >> 4);
        match self.area.chunk(cx, cz) {
            Some(chunk) if self.distance(cx, cz) <= 8 => {
                chunk.get(pos[0], pos[1], pos[2]).unwrap_or(self.void_air)
            }
            _ => {
                self.fail(format!("read of chunk {cx}, {cz} outside the area"));
                self.void_air
            }
        }
    }

    pub fn is_air_at(&mut self, pos: [i32; 3]) -> bool {
        let state = self.get(pos);
        self.table.is_air(state)
    }

    /// `ensureCanWrite`: the 3 × 3 around the centre.
    pub fn can_write(&self, pos: [i32; 3]) -> bool {
        self.distance(pos[0] >> 4, pos[2] >> 4) <= 1
    }

    /// `WorldGenRegion.setBlock`.
    pub fn set(&mut self, pos: [i32; 3], state: u16, flags: i32) -> bool {
        if !self.can_write(pos) {
            return false;
        }
        let (table, air) = (self.table, self.air);
        let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) else {
            return false;
        };
        let old = chunk.set(table, pos[0], pos[1], pos[2], state, air);
        // A created block entity stays when a block with one replaces it
        // (`setBlockEntityNbt` keeps it).
        if table.flag(state, BLOCK_ENTITY) {
            chunk.block_entities.insert(pos);
        } else if old.is_some_and(|old| table.flag(old, BLOCK_ENTITY)) {
            chunk.block_entities.remove(&pos);
            chunk.block_entity_data.remove(&pos);
        }
        if flags & 16 == 0 && table.flag(state, POST_PROCESS) {
            chunk.mark(pos);
        }
        if flags & 16 == 0 && table.flag(state, POST_PROCESS_ABOVE) {
            self.mark([pos[0], pos[1] + 1, pos[2]]);
        }
        true
    }

    /// `getBlockEntity`: the block entity at `pos`, created from its pending
    /// entry when the block has one; `None` without one.
    pub fn block_entity(&mut self, pos: [i32; 3]) -> Result<Option<&mut BlockEntityData>, String> {
        let state = self.get(pos);
        let table = self.table;
        let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) else {
            return Ok(None);
        };
        if !chunk.block_entity_data.contains_key(&pos) {
            if !chunk.block_entities.contains(&pos) || !table.flag(state, BLOCK_ENTITY) {
                return Ok(None);
            }
            let name = &table.names[table.block_of(state) as usize];
            let kind = block_entity_kind(name)
                .ok_or_else(|| format!("the block entity of {name} is not modelled"))?;
            chunk.block_entity_data.insert(
                pos,
                BlockEntityData {
                    kind,
                    loot_table: None,
                    loot_seed: 0,
                    spawner_entity: None,
                },
            );
        }
        Ok(chunk.block_entity_data.get_mut(&pos))
    }

    /// `getBlockTicks().hasScheduledTick(pos, block)`.
    pub fn has_block_tick(&self, pos: [i32; 3], block: u16) -> bool {
        self.area
            .chunk(pos[0] >> 4, pos[2] >> 4)
            .is_some_and(|c| c.block_ticks.contains(&(pos, block)))
    }

    /// A section write without heightmaps, marks or block entities.
    pub fn set_raw(&mut self, pos: [i32; 3], state: u16) {
        let table = self.table;
        if let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) {
            if (MIN_Y..MIN_Y + HEIGHT).contains(&pos[1]) {
                chunk.set_raw(table, pos[0], pos[1], pos[2], state);
            }
        }
    }

    /// `markPosForPostProcessing` on the chunk holding `pos`.
    pub fn mark(&mut self, pos: [i32; 3]) {
        let (cx, cz) = (pos[0] >> 4, pos[2] >> 4);
        match self.area.chunk_mut(cx, cz) {
            Some(chunk) => chunk.mark(pos),
            None => self.fail(format!("mark in chunk {cx}, {cz} outside the area")),
        }
    }

    /// `getHeight(type, x, z)`: the first free Y.
    pub fn height_at(&mut self, kind: Heightmap, x: i32, z: i32) -> i32 {
        let (cx, cz) = (x >> 4, z >> 4);
        match self.area.chunk(cx, cz) {
            Some(chunk) if self.distance(cx, cz) <= 8 => chunk.height(kind, x, z),
            _ => {
                self.fail(format!("heightmap of chunk {cx}, {cz} outside the area"));
                MIN_Y
            }
        }
    }

    /// `getBiome(pos)`: the fuzzy zoom over the chunk biomes of the 3 × 3.
    pub fn biome(&mut self, pos: [i32; 3]) -> u16 {
        let (qx, qy, qz) = self.zoom.zoom(pos[0], pos[1], pos[2]);
        let (cx, cz) = (qx >> 2, qz >> 2);
        if self.distance(cx, cz) > 1 {
            self.fail(format!("biome of chunk {cx}, {cz} outside the 3 × 3"));
            return 0;
        }
        let Some(chunk) = self.area.chunk(cx, cz) else {
            self.fail(format!("biome of chunk {cx}, {cz} outside the area"));
            return 0;
        };
        let min_quart = MIN_Y >> 2;
        let qy = qy.clamp(min_quart, min_quart + HEIGHT / 4 - 1) - min_quart;
        chunk.biomes[((qy >> 2) * 64 + ((qy & 3) * 4 + (qz & 3)) * 4 + (qx & 3)) as usize]
    }

    /// `scheduleTick` for a block: stored at delay 0, once per position and
    /// block.
    pub fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16) {
        if let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) {
            chunk.block_ticks.insert((pos, block));
        }
    }

    pub fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8) {
        if let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) {
            chunk.fluid_ticks.insert((pos, fluid));
        }
    }
}
