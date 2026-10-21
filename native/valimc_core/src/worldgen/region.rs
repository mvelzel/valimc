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

/// The overworld's bounds, which live generation's proto chunk logs hold
/// (VMC-025d); decoration takes each dimension's (VMC-026a).
pub const MIN_Y: i32 = -64;
pub const HEIGHT: i32 = 384;
/// The most sections a dimension's chunk has (the overworld's 24).
pub(crate) const MAX_SECTIONS: usize = 24;

/// A proto chunk after the terrain step, as tall as its dimension.
#[derive(Clone)]
pub struct ProtoChunk {
    pub x: i32,
    pub z: i32,
    /// The dimension's bottom and height (a multiple of 16).
    pub min_y: i32,
    pub height: i32,
    /// States, Y fastest from `min_y`, then X, then Z.
    pub blocks: Vec<u16>,
    /// Biome registry ids: per section from the bottom, 64 in (y, z, x) order.
    pub biomes: Arc<Vec<u16>>,
    /// Per heightmap type, per column (z * 16 + x): the first free Y.
    pub(crate) heightmaps: [Box<[i32; 256]>; 6],
    /// Per section, its non-air blocks (`LevelChunkSection.hasOnlyAir`).
    pub(crate) non_air: [u16; MAX_SECTIONS],
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
    /// Entities features added (`addFreshEntity`), in order.
    pub entities: Vec<Entity>,
    /// Whether a decoration wrote anything into the chunk since it was made
    /// or decoded (live generation re-encodes only those, VMC-025d).
    pub touched: bool,
}

/// An entity a feature or structure added (VMC-026a: the End spikes'
/// crystals; VMC-025f: structures' mobs). A NaN yaw is one vanilla leaves
/// at random (a living entity's first yaw comes from `Math.random`, which
/// end city shulkers keep).
#[derive(Clone, Debug, PartialEq)]
pub struct Entity {
    pub kind: &'static str,
    pub pos: [f64; 3],
    pub yaw: f32,
}

/// A created block entity (VMC-025c): its type and what decoration writes
/// into it (a container's loot table and seed, a spawner's entity).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockEntityData {
    pub kind: &'static str,
    pub loot_table: Option<String>,
    pub loot_seed: i64,
    pub spawner_entity: Option<String>,
    /// A beehive's occupants: each bee's ticks in the hive
    /// (`BeehiveBlockEntity.Occupant.create`).
    pub bees: Vec<i32>,
    /// An end gateway's exit and whether it teleports exactly there.
    pub exit: Option<([i32; 3], bool)>,
    /// The NBT a structure template gave it (VMC-025f), as SNBT.
    pub nbt: Option<Arc<str>>,
}

/// An entity type identifier with a static lifetime: each distinct one is
/// kept once (entity types are a small fixed set).
pub fn entity_kind(id: &str) -> &'static str {
    use std::sync::Mutex;
    static KINDS: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    let mut kinds = KINDS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(&kind) = kinds.iter().find(|&&k| k == id) {
        return kind;
    }
    let kind: &'static str = Box::leak(id.to_string().into_boxed_str());
    kinds.push(kind);
    kind
}

/// The block entity type a block creates, for the blocks decoration and
/// structure pieces fill.
pub fn block_entity_kind(name: &str) -> Option<&'static str> {
    Some(match name {
        "minecraft:chest" => "minecraft:chest",
        "minecraft:trapped_chest" => "minecraft:trapped_chest",
        "minecraft:dispenser" => "minecraft:dispenser",
        "minecraft:spawner" => "minecraft:mob_spawner",
        "minecraft:bee_nest" | "minecraft:beehive" => "minecraft:beehive",
        "minecraft:suspicious_sand" | "minecraft:suspicious_gravel" => "minecraft:brushable_block",
        "minecraft:end_gateway" => "minecraft:end_gateway",
        _ => return None,
    })
}

impl ProtoChunk {
    /// A chunk from its terrain (`blocks` as tall as the dimension, `min_y`
    /// up), with every heightmap primed from it (the worldgen ones as the
    /// terrain step leaves them, the final ones as it primes them).
    pub fn new(
        x: i32,
        z: i32,
        (min_y, height): (i32, i32),
        blocks: Vec<u16>,
        biomes: Arc<Vec<u16>>,
        table: &BlockTable,
    ) -> ProtoChunk {
        assert!(height % 16 == 0 && height as usize <= MAX_SECTIONS * 16);
        assert_eq!(blocks.len(), 256 * height as usize);
        let mut non_air = [0u16; MAX_SECTIONS];
        for column in 0..256 {
            for y in 0..height as usize {
                if !table.is_air(blocks[column * height as usize + y]) {
                    non_air[y / 16] += 1;
                }
            }
        }
        let mut chunk = ProtoChunk {
            x,
            z,
            min_y,
            height,
            blocks,
            biomes,
            heightmaps: std::array::from_fn(|_| Box::new([min_y; 256])),
            non_air,
            marks: BTreeSet::new(),
            block_ticks: BTreeSet::new(),
            fluid_ticks: BTreeSet::new(),
            block_entities: BTreeSet::new(),
            block_entity_data: BTreeMap::new(),
            entities: Vec::new(),
            touched: false,
        };
        // Every heightmap in one scan down each column.
        for column in 0..256 {
            let base = column * height as usize;
            let mut missing = Heightmap::ALL.len();
            for y in (0..height as usize).rev() {
                let state = chunk.blocks[base + y];
                for kind in Heightmap::ALL {
                    let first_free = &mut chunk.heightmaps[kind as usize][column];
                    if *first_free == min_y && table.heightmap(state, kind) {
                        *first_free = min_y + y as i32 + 1;
                        missing -= 1;
                    }
                }
                if missing == 0 {
                    break;
                }
            }
        }
        chunk
    }

    fn index(&self, x: i32, y: i32, z: i32) -> usize {
        ((y - self.min_y) + ((x & 15) + (z & 15) * 16) * self.height) as usize
    }

    fn contains_y(&self, y: i32) -> bool {
        (self.min_y..self.min_y + self.height).contains(&y)
    }

    pub fn get(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        if !self.contains_y(y) {
            return None;
        }
        Some(self.blocks[self.index(x, y, z)])
    }

    /// Whether the section holding `y` has only air-like states
    /// (`LevelChunkSection.hasOnlyAir`): vanilla reads it as plain air
    /// throughout (cave air a structure left in the open sky included).
    pub fn only_air(&self, y: i32) -> bool {
        self.contains_y(y) && self.non_air[((y - self.min_y) / 16) as usize] == 0
    }

    /// The blocks as `ProtoChunk.getBlockState` reads them: sections with
    /// only air-like states as `air`.
    pub fn observed_blocks(&self, air: u16) -> Vec<u16> {
        let rows = self.height as usize;
        let mut out = self.blocks.clone();
        for (section, &count) in self.non_air.iter().enumerate().take(rows / 16) {
            if count != 0 {
                continue;
            }
            for column in 0..256 {
                let start = column * rows + section * 16;
                out[start..start + 16].fill(air);
            }
        }
        out
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
        if !self.contains_y(y) {
            return None;
        }
        let section = ((y - self.min_y) / 16) as usize;
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
        let i = self.index(x, y, z);
        let old = self.blocks[i];
        self.touched = true;
        let section = ((y - self.min_y) / 16) as usize;
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
            let base = column * self.height as usize;
            let mut height = self.min_y;
            for below in (self.min_y..y).rev() {
                if table.heightmap(self.blocks[base + (below - self.min_y) as usize], kind) {
                    height = below + 1;
                    break;
                }
            }
            self.heightmaps[kind as usize][column] = height;
        }
    }

    pub fn mark(&mut self, pos: [i32; 3]) {
        if self.contains_y(pos[1]) {
            self.touched |= self.marks.insert(pos);
        }
    }
}

/// The chunks of a decoration area, `size` × `size` from (`x`, `z`), Z
/// outer and X inner, all of one dimension's bounds; live generation leaves
/// out chunks it does not hold (VMC-025d).
pub struct Area {
    pub x: i32,
    pub z: i32,
    pub size: i32,
    pub min_y: i32,
    pub height: i32,
    pub chunks: Vec<Option<ProtoChunk>>,
}

impl Area {
    /// The smallest square area holding `chunks` (at most 64 × 64 chunks).
    pub fn of(chunks: Vec<ProtoChunk>) -> Result<Area, String> {
        let first = chunks.first().ok_or("an area needs a chunk")?;
        let (mut x0, mut z0, mut x1, mut z1) = (first.x, first.z, first.x, first.z);
        for c in &chunks {
            (x0, z0, x1, z1) = (x0.min(c.x), z0.min(c.z), x1.max(c.x), z1.max(c.z));
        }
        let size = (x1 - x0).max(z1 - z0) + 1;
        if size > 64 {
            return Err("an area spans at most 64 chunks".into());
        }
        let (min_y, height) = (first.min_y, first.height);
        if chunks
            .iter()
            .any(|c| (c.min_y, c.height) != (min_y, height))
        {
            return Err("an area's chunks have one dimension's bounds".into());
        }
        let mut area = Area {
            x: x0,
            z: z0,
            size,
            min_y,
            height,
            chunks: (0..size * size).map(|_| None).collect(),
        };
        for c in chunks {
            let slot = area.slot(c.x, c.z).expect("inside its bounds");
            if area.chunks[slot].replace(c).is_some() {
                return Err("a chunk appears twice in an area".into());
            }
        }
        Ok(area)
    }

    fn slot(&self, chunk_x: i32, chunk_z: i32) -> Option<usize> {
        let (dx, dz) = (chunk_x - self.x, chunk_z - self.z);
        if dx < 0 || dz < 0 || dx >= self.size || dz >= self.size {
            return None;
        }
        Some((dz * self.size + dx) as usize)
    }

    pub fn chunk(&self, chunk_x: i32, chunk_z: i32) -> Option<&ProtoChunk> {
        self.slot(chunk_x, chunk_z)
            .and_then(|i| self.chunks[i].as_ref())
    }

    pub fn chunk_mut(&mut self, chunk_x: i32, chunk_z: i32) -> Option<&mut ProtoChunk> {
        self.slot(chunk_x, chunk_z)
            .and_then(move |i| self.chunks[i].as_mut())
    }

    /// The chunks it holds, Z outer and X inner.
    pub fn held(&self) -> impl Iterator<Item = &ProtoChunk> {
        self.chunks.iter().flatten()
    }
}

/// The world one chunk is decorated through (`WorldGenRegion`).
pub struct Region<'a> {
    pub area: &'a mut Area,
    pub table: &'a BlockTable,
    pub centre: (i32, i32),
    pub seed: i64,
    pub sea_level: i32,
    min_y: i32,
    height: i32,
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
    /// Live generation (VMC-025d): a block or heightmap read of a chunk the
    /// area does not hold sees an empty chunk, as vanilla's region sees a
    /// neighbour that has not reached the noise step, and is counted instead
    /// of failing. Decorations have not been seen to read outside their 3 × 3.
    pub lenient: bool,
    pub lenient_reads: u32,
    /// How far from the centre writes reach, in chunks: 1 for a
    /// `WorldGenRegion`; `/place` (VMC-053) writes the level, as far as the
    /// area it holds.
    pub write_radius: i32,
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
        let (min_y, height) = (area.min_y, area.height);
        Ok(Region {
            area,
            table,
            centre,
            seed,
            sea_level,
            min_y,
            height,
            zoom: ChunkZoom::new(zoom_seed, centre.0, centre.1, min_y, height),
            air: table.default_state("air")?,
            void_air: table.default_state("void_air")?,
            random: Random::xoroshiro(seed)
                .fork_positional()
                .from_hash_of("minecraft:worldgen_region_random")
                .fork_positional()
                .at(centre.0 * 16, 0, centre.1 * 16),
            fault: None,
            lenient: false,
            lenient_reads: 0,
            write_radius: 1,
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
        self.min_y
    }

    pub fn height(&self) -> i32 {
        self.height
    }

    pub fn is_outside_build_height(&self, y: i32) -> bool {
        !(self.min_y..self.min_y + self.height).contains(&y)
    }

    /// `getBlockState`.
    pub fn get(&mut self, pos: [i32; 3]) -> u16 {
        let (cx, cz) = (pos[0] >> 4, pos[2] >> 4);
        match self.area.chunk(cx, cz) {
            Some(chunk) if self.distance(cx, cz) <= 8 => match chunk.get(pos[0], pos[1], pos[2]) {
                Some(_) if chunk.only_air(pos[1]) => self.air,
                Some(state) => state,
                None => self.void_air,
            },
            None if self.lenient && self.distance(cx, cz) <= 8 => {
                self.lenient_reads += 1;
                if self.is_outside_build_height(pos[1]) {
                    self.void_air
                } else {
                    self.air
                }
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

    /// `ensureCanWrite`: the 3 × 3 around the centre (`write_radius`).
    pub fn can_write(&self, pos: [i32; 3]) -> bool {
        self.distance(pos[0] >> 4, pos[2] >> 4) <= self.write_radius
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
            chunk.touched |= chunk.block_entities.insert(pos);
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
            let kind = table
                .block_entity_type(state)
                .or_else(|| block_entity_kind(name))
                .ok_or_else(|| format!("the block entity of {name} is not modelled"))?;
            chunk.block_entity_data.insert(
                pos,
                BlockEntityData {
                    kind,
                    loot_table: None,
                    loot_seed: 0,
                    spawner_entity: None,
                    bees: Vec::new(),
                    exit: None,
                    nbt: None,
                },
            );
        }
        chunk.touched = true;
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
            if chunk.contains_y(pos[1]) {
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
            None if self.lenient && self.distance(cx, cz) <= 8 => {
                self.lenient_reads += 1;
                self.min_y
            }
            _ => {
                self.fail(format!("heightmap of chunk {cx}, {cz} outside the area"));
                self.min_y
            }
        }
    }

    /// `getBiome(pos)`: the fuzzy zoom over the chunk biomes of the 3 × 3.
    pub fn biome(&mut self, pos: [i32; 3]) -> u16 {
        let (qx, qy, qz) = self.zoom.zoom(pos[0], pos[1], pos[2]);
        let (cx, cz) = (qx >> 2, qz >> 2);
        // `/place` reads the level's biomes as far as it writes.
        if self.distance(cx, cz) > self.write_radius.max(1) {
            self.fail(format!("biome of chunk {cx}, {cz} outside the 3 × 3"));
            return 0;
        }
        let Some(chunk) = self.area.chunk(cx, cz) else {
            self.fail(format!("biome of chunk {cx}, {cz} outside the area"));
            return 0;
        };
        let min_quart = self.min_y >> 2;
        let qy = qy.clamp(min_quart, min_quart + self.height / 4 - 1) - min_quart;
        chunk.biomes[((qy >> 2) * 64 + ((qy & 3) * 4 + (qz & 3)) * 4 + (qx & 3)) as usize]
    }

    /// `scheduleTick` for a block: stored at delay 0, once per position and
    /// block.
    pub fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16) {
        if let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) {
            chunk.touched |= chunk.block_ticks.insert((pos, block));
        }
    }

    /// `addFreshEntity`: into the chunk holding the entity's block position.
    pub fn add_entity(&mut self, entity: Entity) {
        let (cx, cz) = (
            (entity.pos[0].floor() as i32) >> 4,
            (entity.pos[2].floor() as i32) >> 4,
        );
        let near = self.distance(cx, cz) <= self.write_radius.max(1);
        match self.area.chunk_mut(cx, cz) {
            Some(chunk) if near => {
                chunk.entities.push(entity);
                chunk.touched = true;
            }
            _ => self.fail(format!("entity in chunk {cx}, {cz} outside the 3 × 3")),
        }
    }

    pub fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8) {
        if let Some(chunk) = self.area.chunk_mut(pos[0] >> 4, pos[2] >> 4) {
            chunk.touched |= chunk.fluid_ticks.insert((pos, fluid));
        }
    }
}

impl crate::rules::BlockAccess for Region<'_> {
    fn get(&mut self, pos: [i32; 3]) -> u16 {
        Region::get(self, pos)
    }

    /// Proto chunks keep a tick's block, not its delay.
    fn schedule_block_tick(&mut self, pos: [i32; 3], block: u16, _delay: i32) {
        Region::schedule_block_tick(self, pos, block)
    }

    fn schedule_fluid_tick(&mut self, pos: [i32; 3], fluid: u8, _delay: i32) {
        Region::schedule_fluid_tick(self, pos, fluid)
    }

    fn has_block_tick(&mut self, pos: [i32; 3], block: u16) -> bool {
        Region::has_block_tick(self, pos, block)
    }

    fn next_int(&mut self, bound: i32) -> i32 {
        self.random.next_int_bounded(bound)
    }
}
