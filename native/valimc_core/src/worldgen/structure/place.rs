//! Structure placement into chunks (VMC-025f): `StructureStart.placeInChunk`,
//! the block helpers of `StructurePiece` and the order in which a chunk's
//! references are visited.

use std::cell::RefCell;
use std::collections::HashMap;

use super::super::blocks::{BlockSet, BlockTable, Heightmap, FLUID_EMPTY, LIQUID, SOLID_RENDER};
use super::super::feature::Decoration;
use super::super::random::Random;
use super::super::region::Region;
use super::super::template::{Mirror, Rotation, Templates};
use super::piece::{BoundingBox, Direction, Piece, PieceKind};
use super::{jigsaw_place, scattered, template_place, Start, StructureKind, StructureRegistry};

/// What placement shares across a decoration: the block table, state
/// transforms and states by name.
pub struct Placer<'d> {
    pub decoration: &'d Decoration,
    pub table: &'d BlockTable,
    pub templates: Option<&'d Templates>,
    pub seed: i64,
    states: RefCell<HashMap<&'static str, u16>>,
    /// `StructurePiece.SHAPE_CHECK_BLOCKS`: placed blocks whose shape
    /// follows their neighbours, marked for post-processing.
    shape_check: BlockSet,
    replaceable: BlockSet,
    pub air: u16,
}

impl<'d> Placer<'d> {
    pub fn new(decoration: &'d Decoration, seed: i64) -> Result<Placer<'d>, String> {
        let table = decoration.table.as_ref();
        let templates = decoration.templates().ok();
        let blocks = |names: &[&str]| {
            names
                .iter()
                .map(|n| table.block(n))
                .collect::<Result<Vec<_>, _>>()
                .map(BlockSet::from_blocks)
        };
        Ok(Placer {
            decoration,
            table,
            templates,
            seed,
            states: RefCell::new(HashMap::new()),
            shape_check: blocks(&[
                "nether_brick_fence",
                "torch",
                "wall_torch",
                "oak_fence",
                "spruce_fence",
                "dark_oak_fence",
                "pale_oak_fence",
                "acacia_fence",
                "birch_fence",
                "jungle_fence",
                "ladder",
                "iron_bars",
            ])?,
            replaceable: blocks(&["glow_lichen", "seagrass", "tall_seagrass"])?,
            air: table.default_state("air")?,
        })
    }

    /// A state by name with properties, `name[key=value,…]` (resolved once).
    pub fn state(&self, spec: &'static str) -> Result<u16, String> {
        if let Some(&state) = self.states.borrow().get(spec) {
            return Ok(state);
        }
        let (name, properties) = match spec.split_once('[') {
            Some((name, rest)) => (name, rest.strip_suffix(']').unwrap_or(rest)),
            None => (spec, ""),
        };
        let mut state = self.table.default_state(name)?;
        for pair in properties.split(',').filter(|p| !p.is_empty()) {
            let (key, value) = pair
                .split_once('=')
                .ok_or_else(|| format!("bad block state {spec}"))?;
            state = self
                .table
                .with(state, key, value)
                .ok_or_else(|| format!("bad block state {spec}"))?;
        }
        self.states.borrow_mut().insert(spec, state);
        Ok(state)
    }

    /// `state.setValue(property, value)`; the state itself without it.
    pub fn with(&self, state: u16, property: &str, value: &str) -> u16 {
        self.table.with(state, property, value).unwrap_or(state)
    }

    /// `state.mirror(mirror).rotate(rotation)`.
    pub fn transform(&self, state: u16, mirror: Mirror, rotation: Rotation) -> u16 {
        match self.templates {
            Some(t) => t.transform_state(state, mirror, rotation),
            None => state,
        }
    }

    /// `StructurePiece.isReplaceableByStructures`.
    pub fn replaceable_by_structures(&self, state: u16) -> bool {
        self.table.is_air(state)
            || self.table.flag(state, LIQUID)
            || self.replaceable.contains(self.table.block_of(state))
    }

    pub fn is(&self, state: u16, name: &'static str) -> bool {
        self.state(name)
            .is_ok_and(|s| self.table.block_of(s) == self.table.block_of(state))
    }
}

/// A piece's placement frame: its box and orientation, and the mirror and
/// rotation the orientation implies (`StructurePiece.setOrientation`).
#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bbox: BoundingBox,
    pub orientation: Option<Direction>,
    pub mirror: Mirror,
    pub rotation: Rotation,
}

impl Frame {
    pub fn new(bbox: BoundingBox, orientation: Option<Direction>) -> Frame {
        let (mirror, rotation) = match orientation {
            Some(Direction::South) => (Mirror::LeftRight, Rotation::None),
            Some(Direction::West) => (Mirror::LeftRight, Rotation::Clockwise90),
            Some(Direction::East) => (Mirror::None, Rotation::Clockwise90),
            _ => (Mirror::None, Rotation::None),
        };
        Frame {
            bbox,
            orientation,
            mirror,
            rotation,
        }
    }

    /// `getWorldX`.
    pub fn world_x(&self, x: i32, z: i32) -> i32 {
        match self.orientation {
            None => x,
            Some(Direction::North | Direction::South) => self.bbox.min_x + x,
            Some(Direction::West) => self.bbox.max_x - z,
            Some(Direction::East) => self.bbox.min_x + z,
        }
    }

    /// `getWorldY`.
    pub fn world_y(&self, y: i32) -> i32 {
        match self.orientation {
            None => y,
            Some(_) => y + self.bbox.min_y,
        }
    }

    /// `getWorldZ`.
    pub fn world_z(&self, x: i32, z: i32) -> i32 {
        match self.orientation {
            None => z,
            Some(Direction::North) => self.bbox.max_z - z,
            Some(Direction::South) => self.bbox.min_z + z,
            Some(Direction::West | Direction::East) => self.bbox.min_z + x,
        }
    }

    /// `getWorldPos`.
    pub fn world(&self, x: i32, y: i32, z: i32) -> [i32; 3] {
        [self.world_x(x, z), self.world_y(y), self.world_z(x, z)]
    }
}

/// One start's placement into one chunk: the level, the random the chunk's
/// structure step seeded, the chunk's writable box and the start's
/// reference position (`postProcess`'s arguments).
pub struct Ctx<'c, 'a> {
    pub placer: &'c Placer<'c>,
    pub region: &'c mut Region<'a>,
    pub random: &'c mut Random,
    pub chunk_box: BoundingBox,
    pub chunk: (i32, i32),
    pub reference: [i32; 3],
}

/// A `BlockSelector`: the state for a position of a box, and whether the
/// position is on the box's edge.
pub type Selector<'s> = dyn FnMut(&mut Random, [i32; 3], bool) -> u16 + 's;

/// A piece's block call with constant arguments, its states as indices into
/// the piece's palette; runs of them replay a `postProcess` in order.
#[derive(Clone, Copy, Debug)]
pub enum Op {
    /// `generateBox` from (x0, y0, z0) to (x1, y1, z1) with an edge and a
    /// fill state.
    B(i32, i32, i32, i32, i32, i32, usize, usize),
    /// The same, leaving air alone.
    S(i32, i32, i32, i32, i32, i32, usize, usize),
    /// `generateBox` with the piece's block selector.
    R(i32, i32, i32, i32, i32, i32),
    /// `generateAirBox`.
    A(i32, i32, i32, i32, i32, i32),
    /// `placeBlock`.
    P(usize, i32, i32, i32),
    /// `fillColumnDown`.
    F(usize, i32, i32, i32),
}

impl Ctx<'_, '_> {
    pub fn state(&self, spec: &'static str) -> Result<u16, String> {
        self.placer.state(spec)
    }

    /// A palette's states.
    pub fn palette(&self, specs: &[&'static str]) -> Result<Vec<u16>, String> {
        specs.iter().map(|s| self.placer.state(s)).collect()
    }

    /// Replay `ops` with `palette`'s states (and `selector` for its `R`s).
    pub fn run(
        &mut self,
        f: &Frame,
        palette: &[u16],
        ops: &[Op],
        mut selector: Option<&mut Selector>,
    ) -> Result<(), String> {
        for op in ops {
            match *op {
                Op::B(x0, y0, z0, x1, y1, z1, edge, fill) => self.generate_box(
                    f,
                    (x0, y0, z0),
                    (x1, y1, z1),
                    palette[edge],
                    palette[fill],
                    false,
                ),
                Op::S(x0, y0, z0, x1, y1, z1, edge, fill) => self.generate_box(
                    f,
                    (x0, y0, z0),
                    (x1, y1, z1),
                    palette[edge],
                    palette[fill],
                    true,
                ),
                Op::R(x0, y0, z0, x1, y1, z1) => {
                    let selector = selector
                        .as_deref_mut()
                        .ok_or("a selector box without a selector")?;
                    self.generate_box_with(f, (x0, y0, z0), (x1, y1, z1), false, selector)
                }
                Op::A(x0, y0, z0, x1, y1, z1) => self.air_box(f, x0, y0, z0, x1, y1, z1),
                Op::P(state, x, y, z) => self.place(f, palette[state], x, y, z),
                Op::F(state, x, y, z) => self.fill_column_down(f, palette[state], x, y, z),
            }
        }
        Ok(())
    }

    fn inside(&self, pos: [i32; 3]) -> bool {
        self.chunk_box.is_inside(pos[0], pos[1], pos[2])
    }

    /// `StructurePiece.placeBlock`.
    pub fn place(&mut self, f: &Frame, state: u16, x: i32, y: i32, z: i32) {
        let pos = f.world(x, y, z);
        if !self.inside(pos) {
            return;
        }
        let state = self.placer.transform(state, f.mirror, f.rotation);
        self.set(pos, state, 2);
        let fluid = self.placer.table.fluid(self.region.get(pos));
        if fluid != FLUID_EMPTY {
            self.region.schedule_fluid_tick(pos, fluid);
        }
        if self
            .placer
            .shape_check
            .contains(self.placer.table.block_of(state))
        {
            self.region.mark(pos);
        }
    }

    /// `level.setBlock`.
    pub fn set(&mut self, pos: [i32; 3], state: u16, flags: i32) {
        self.region.set(pos, state, flags);
    }

    /// `StructurePiece.getBlock`: air outside the chunk's box.
    pub fn get_block(&mut self, f: &Frame, x: i32, y: i32, z: i32) -> u16 {
        let pos = f.world(x, y, z);
        if !self.inside(pos) {
            return self.placer.air;
        }
        self.region.get(pos)
    }

    /// `StructurePiece.isInterior`: below the ocean floor, inside the box.
    pub fn is_interior(&mut self, f: &Frame, x: i32, y: i32, z: i32) -> bool {
        let pos = f.world(x, y + 1, z);
        self.inside(pos)
            && pos[1]
                < self
                    .region
                    .height_at(Heightmap::OceanFloorWg, pos[0], pos[2])
    }

    fn skipped(&mut self, f: &Frame, skip_air: bool, x: i32, y: i32, z: i32) -> bool {
        if !skip_air {
            return false;
        }
        let state = self.get_block(f, x, y, z);
        self.placer.table.is_air(state)
    }

    /// `generateAirBox`.
    #[allow(clippy::too_many_arguments)]
    pub fn air_box(&mut self, f: &Frame, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) {
        let air = self.placer.air;
        for y in y0..=y1 {
            for x in x0..=x1 {
                for z in z0..=z1 {
                    self.place(f, air, x, y, z);
                }
            }
        }
    }

    /// `generateBox` with an edge and a fill state.
    #[allow(clippy::too_many_arguments)]
    pub fn generate_box(
        &mut self,
        f: &Frame,
        (x0, y0, z0): (i32, i32, i32),
        (x1, y1, z1): (i32, i32, i32),
        edge: u16,
        fill: u16,
        skip_air: bool,
    ) {
        for y in y0..=y1 {
            for x in x0..=x1 {
                for z in z0..=z1 {
                    if self.skipped(f, skip_air, x, y, z) {
                        continue;
                    }
                    let interior = y != y0 && y != y1 && x != x0 && x != x1 && z != z0 && z != z1;
                    self.place(f, if interior { fill } else { edge }, x, y, z);
                }
            }
        }
    }

    /// `generateBox` with a block selector, which draws for every position
    /// it is asked for, inside the chunk or not.
    pub fn generate_box_with(
        &mut self,
        f: &Frame,
        (x0, y0, z0): (i32, i32, i32),
        (x1, y1, z1): (i32, i32, i32),
        skip_air: bool,
        selector: &mut Selector,
    ) {
        for y in y0..=y1 {
            for x in x0..=x1 {
                for z in z0..=z1 {
                    if self.skipped(f, skip_air, x, y, z) {
                        continue;
                    }
                    let edge = y == y0 || y == y1 || x == x0 || x == x1 || z == z0 || z == z1;
                    let state = selector(self.random, [x, y, z], edge);
                    self.place(f, state, x, y, z);
                }
            }
        }
    }

    /// `generateMaybeBox`.
    #[allow(clippy::too_many_arguments)]
    pub fn maybe_box(
        &mut self,
        f: &Frame,
        probability: f32,
        (x0, y0, z0): (i32, i32, i32),
        (x1, y1, z1): (i32, i32, i32),
        edge: u16,
        fill: u16,
        skip_air: bool,
        has_to_be_inside: bool,
    ) {
        for y in y0..=y1 {
            for x in x0..=x1 {
                for z in z0..=z1 {
                    if self.random.next_float() > probability
                        || self.skipped(f, skip_air, x, y, z)
                        || (has_to_be_inside && !self.is_interior(f, x, y, z))
                    {
                        continue;
                    }
                    let interior = y != y0 && y != y1 && x != x0 && x != x1 && z != z0 && z != z1;
                    self.place(f, if interior { fill } else { edge }, x, y, z);
                }
            }
        }
    }

    /// `maybeGenerateBlock`.
    pub fn maybe_block(&mut self, f: &Frame, probability: f32, x: i32, y: i32, z: i32, state: u16) {
        if self.random.next_float() < probability {
            self.place(f, state, x, y, z);
        }
    }

    /// `generateUpperHalfSphere`.
    pub fn upper_half_sphere(
        &mut self,
        f: &Frame,
        (x0, y0, z0): (i32, i32, i32),
        (x1, y1, z1): (i32, i32, i32),
        fill: u16,
        skip_air: bool,
    ) {
        let diag_x = (x1 - x0 + 1) as f32;
        let diag_y = (y1 - y0 + 1) as f32;
        let diag_z = (z1 - z0 + 1) as f32;
        let cx = x0 as f32 + diag_x / 2.0;
        let cz = z0 as f32 + diag_z / 2.0;
        for y in y0..=y1 {
            let ny = (y - y0) as f32 / diag_y;
            for x in x0..=x1 {
                let nx = (x as f32 - cx) / (diag_x * 0.5);
                for z in z0..=z1 {
                    let nz = (z as f32 - cz) / (diag_z * 0.5);
                    if self.skipped(f, skip_air, x, y, z) {
                        continue;
                    }
                    if nx * nx + ny * ny + nz * nz <= 1.05 {
                        self.place(f, fill, x, y, z);
                    }
                }
            }
        }
    }

    /// `fillColumnDown`: down from (x, y, z) through what structures may
    /// replace, to one above the bottom.
    pub fn fill_column_down(&mut self, f: &Frame, state: u16, x: i32, y: i32, z: i32) {
        let mut pos = f.world(x, y, z);
        if !self.inside(pos) {
            return;
        }
        let bottom = self.region.min_y() + 1;
        loop {
            let here = self.region.get(pos);
            if !self.placer.replaceable_by_structures(here) || pos[1] <= bottom {
                break;
            }
            self.set(pos, state, 2);
            pos[1] -= 1;
        }
    }

    /// `StructurePiece.reorient`: a chest facing away from its one solid
    /// neighbour, else turned off solid blocks.
    pub fn reorient(&mut self, pos: [i32; 3], state: u16) -> u16 {
        let table = self.placer.table;
        let chest = self.placer.state("chest").unwrap_or(state);
        let solid = |region: &mut Region, d: Direction| {
            let (dx, dz) = d.step();
            table.flag(region.get([pos[0] + dx, pos[1], pos[2] + dz]), SOLID_RENDER)
        };
        let mut solid_neighbour = None;
        for d in Direction::HORIZONTAL {
            let (dx, dz) = d.step();
            let neighbour = self.region.get([pos[0] + dx, pos[1], pos[2] + dz]);
            if table.block_of(neighbour) == table.block_of(chest) {
                return state;
            }
            if table.flag(neighbour, SOLID_RENDER) {
                if solid_neighbour.is_some() {
                    solid_neighbour = None;
                    break;
                }
                solid_neighbour = Some(d);
            }
        }
        if let Some(d) = solid_neighbour {
            return self.placer.with(state, "facing", d.opposite().name());
        }
        let mut lock = table
            .value(state, "facing")
            .and_then(Direction::parse)
            .unwrap_or(Direction::North);
        if solid(self.region, lock) {
            lock = lock.opposite();
        }
        if solid(self.region, lock) {
            lock = lock.clockwise();
        }
        if solid(self.region, lock) {
            lock = lock.opposite();
        }
        self.placer.with(state, "facing", lock.name())
    }

    /// `createChest` at a world position; whether it placed one.
    pub fn create_chest(
        &mut self,
        pos: [i32; 3],
        loot_table: &str,
        state: Option<u16>,
    ) -> Result<bool, String> {
        let chest = self.state("chest")?;
        if !self.inside(pos) || self.placer.is(self.region.get(pos), "chest") {
            return Ok(false);
        }
        let state = match state {
            Some(state) => state,
            None => self.reorient(pos, chest),
        };
        self.set(pos, state, 2);
        self.loot(pos, loot_table, "minecraft:chest")?;
        Ok(true)
    }

    /// `createChest` at a piece position.
    pub fn create_chest_at(
        &mut self,
        f: &Frame,
        x: i32,
        y: i32,
        z: i32,
        loot_table: &str,
    ) -> Result<bool, String> {
        self.create_chest(f.world(x, y, z), loot_table, None)
    }

    /// `createDispenser`: a dispenser facing `facing` (in piece space) with
    /// a loot table.
    #[allow(clippy::too_many_arguments)]
    pub fn create_dispenser(
        &mut self,
        f: &Frame,
        x: i32,
        y: i32,
        z: i32,
        facing: Direction,
        loot_table: &str,
    ) -> Result<bool, String> {
        let pos = f.world(x, y, z);
        let dispenser = self.state("dispenser")?;
        if !self.inside(pos) || self.placer.is(self.region.get(pos), "dispenser") {
            return Ok(false);
        }
        let state = self.placer.with(dispenser, "facing", facing.name());
        self.place(f, state, x, y, z);
        self.loot(pos, loot_table, "minecraft:dispenser")?;
        Ok(true)
    }

    /// `setLootTable(table, random.nextLong())` on the block entity at `pos`
    /// when it has the type `kind`; the seed is drawn either way.
    fn loot(&mut self, pos: [i32; 3], loot_table: &str, kind: &str) -> Result<(), String> {
        let seed = self.random.next_long();
        if let Some(entity) = self.region.block_entity(pos)? {
            if entity.kind == kind {
                entity.loot_table = Some(loot_table.to_string());
                entity.loot_seed = seed;
            }
        }
        Ok(())
    }
}

/// `StructureStart.placeInChunk`: every piece that reaches into the chunk's
/// writable box places its part, then the structure's `afterPlace`; the
/// reference position is the first piece's centre at its bottom.
pub fn place_in_chunk(
    start: &mut Start,
    c: &mut Ctx,
    registry: &StructureRegistry,
) -> Result<(), String> {
    let Some(first) = start.pieces.first() else {
        return Ok(());
    };
    let (x, _, z) = first.bbox.center();
    c.reference = [x, first.bbox.min_y, z];
    for piece in start.pieces.iter_mut() {
        if piece.bbox.intersects(&c.chunk_box) {
            post_process(piece, c, &registry.structures[start.structure].kind)?;
        }
    }
    match registry.structures[start.structure].kind {
        StructureKind::DesertPyramid => scattered::desert_pyramid_after_place(&start.pieces, c),
        StructureKind::WoodlandMansion => template_place::mansion_after_place(&start.pieces, c),
        _ => Ok(()),
    }
}

/// `StructurePiece.postProcess` by piece type.
fn post_process(piece: &mut Piece, c: &mut Ctx, kind: &StructureKind) -> Result<(), String> {
    match piece.kind {
        PieceKind::Scattered { .. } | PieceKind::BuriedTreasure => {
            scattered::post_process(piece, c)
        }
        PieceKind::Template(_) => template_place::post_process(piece, c, kind),
        PieceKind::Jigsaw(_) => jigsaw_place::post_process(piece, c),
        _ => Err(format!("placing {} pieces is not implemented", piece.id())),
    }
}

/// `ChunkGenerator.getWritableArea`: the chunk's column above the bottom
/// block.
pub fn writable_area(chunk: (i32, i32), min_y: i32, height: i32) -> BoundingBox {
    let (x, z) = (chunk.0 * 16, chunk.1 * 16);
    BoundingBox::new(x, min_y + 1, z, x + 15, min_y + height - 1, z + 15)
}

/// The order a chunk visits the starts of each structure that references
/// it: per structure (by index), the start chunks in the order of the
/// chunk's reference set, from `references` in the order
/// `createReferences` adds them.
pub fn visit_order(references: &[(usize, (i32, i32))]) -> HashMap<usize, Vec<(i32, i32)>> {
    let mut keys: HashMap<usize, Vec<i64>> = HashMap::new();
    for &(structure, (x, z)) in references {
        keys.entry(structure).or_default().push(chunk_key(x, z));
    }
    keys.into_iter()
        .map(|(structure, keys)| {
            let chunks = long_hash_set_order(&keys)
                .into_iter()
                .map(|k| (k as i32, (k >> 32) as i32))
                .collect();
            (structure, chunks)
        })
        .collect()
}

/// `BlockPos.asLong`.
pub fn block_pos_long(pos: [i32; 3]) -> i64 {
    ((pos[0] as i64 & 0x3FF_FFFF) << 38)
        | (pos[1] as i64 & 0xFFF)
        | ((pos[2] as i64 & 0x3FF_FFFF) << 12)
}

/// `ChunkPos.pack`.
pub fn chunk_key(x: i32, z: i32) -> i64 {
    (x as u32 as i64) | ((z as u32 as i64) << 32)
}

/// `HashCommon.mix` of fastutil.
fn mix(key: i64) -> i64 {
    let h = key.wrapping_mul(-7_046_029_254_386_353_131);
    let h = h ^ ((h as u64) >> 32) as i64;
    h ^ ((h as u64) >> 16) as i64
}

/// The order a fastutil `LongOpenHashSet` made with its default capacity
/// (16, load factor 0.75) iterates after `keys` are added in order: the
/// zero key first, then the table from its last slot down, rehashed as it
/// grows (vanilla visits a chunk's references for a structure this way).
pub fn long_hash_set_order(keys: &[i64]) -> Vec<i64> {
    fn array_size(expected: usize) -> usize {
        let wanted = (expected as f32 / 0.75f32).ceil() as usize;
        wanted.next_power_of_two().max(2)
    }
    fn max_fill(n: usize) -> usize {
        ((n as f32 * 0.75f32).ceil() as usize).min(n - 1)
    }
    fn insert(table: &mut [i64], key: i64) -> bool {
        let mask = table.len() - 1;
        let mut pos = mix(key) as i32 as usize & mask;
        while table[pos] != 0 {
            if table[pos] == key {
                return false;
            }
            pos = (pos + 1) & mask;
        }
        table[pos] = key;
        true
    }
    let mut table = vec![0i64; array_size(16)];
    let mut fill = max_fill(table.len());
    let mut has_zero = false;
    let mut size = 0usize;
    for &key in keys {
        if key == 0 {
            if has_zero {
                continue;
            }
            has_zero = true;
        } else if !insert(&mut table, key) {
            continue;
        }
        let before = size;
        size += 1;
        if before >= fill {
            let mut grown = vec![0i64; array_size(size + 1)];
            for &old in table.iter().rev().filter(|&&k| k != 0) {
                insert(&mut grown, old);
            }
            table = grown;
            fill = max_fill(table.len());
        }
    }
    let mut out = Vec::with_capacity(size);
    if has_zero {
        out.push(0);
    }
    out.extend(table.iter().rev().filter(|&&k| k != 0));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_set_order_follows_fastutil() {
        // The chunks within 8 of (3, -2), x outer and z inner, as `createReferences` adds them;
        // fastutil's iteration orders after 5, 30 (one rehash) and all 289 keys (zero first).
        let keys: Vec<i64> = (3 - 8..=3 + 8)
            .flat_map(|x| (-2 - 8..=-2 + 8).map(move |z| chunk_key(x, z)))
            .collect();
        assert_eq!(
            long_hash_set_order(&keys[..5]),
            [
                -21474836485,
                -25769803781,
                -38654705669,
                -34359738373,
                -30064771077
            ]
        );
        assert_eq!(
            long_hash_set_order(&keys[..30]),
            [
                -8589934597,
                17179869179,
                4294967292,
                -4294967301,
                -12884901893,
                -38654705669,
                -34359738373,
                -30064771077,
                25769803771,
                8589934587,
                -4294967300,
                -21474836484,
                -30064771076,
                -38654705668,
                -12884901892,
                12884901884,
                -21474836485,
                4294967291,
                30064771067,
                -5,
                -25769803781,
                -17179869189,
                8589934588,
                21474836475,
                12884901883,
                -8589934596,
                -34359738372,
                -25769803780,
                -17179869188,
                -4
            ]
        );
        let all = long_hash_set_order(&keys);
        assert_eq!(all.len(), 289);
        assert_eq!(all[0], 0);
        let digest = all
            .iter()
            .fold(0i64, |h, &k| h.wrapping_mul(31).wrapping_add(k));
        assert_eq!(digest, -4823920158717336583);
    }

    #[test]
    fn block_pos_packs_as_vanilla() {
        assert_eq!(block_pos_long([0, 0, 0]), 0);
        assert_eq!(block_pos_long([1, 2, 3]), (1 << 38) | 2 | (3 << 12));
        assert_eq!(block_pos_long([-1, -1, -1]), -1);
    }
}
