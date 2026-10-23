//! Single-piece structures: desert and jungle temples (`SinglePieceStructure`),
//! swamp huts and buried treasure.

use super::super::blocks::Heightmap;
use super::super::plants::shuffle;
use super::super::providers::between_inclusive;
use super::super::random::Random;
use super::super::region::Entity;
use super::piece::{
    encapsulating, make_bounding_box, BoundingBox, Direction, Piece, PieceKind, ScatteredKind,
};
use super::place::{block_pos_long, Ctx, Frame, Op};
use super::{GenContext, StructureDef, StructureKind};

/// A `ScatteredFeaturePiece` at a chunk's corner at y 64, facing a random
/// direction.
fn scattered(
    gc: &mut GenContext,
    kind: ScatteredKind,
    width: i32,
    height: i32,
    depth: i32,
) -> Piece {
    let direction = Direction::random(&mut gc.random);
    Piece {
        kind: PieceKind::Scattered {
            kind,
            width,
            height,
            depth,
            height_position: -1,
            placed: [false; 4],
        },
        bbox: make_bounding_box(
            gc.min_block_x(),
            64,
            gc.min_block_z(),
            direction,
            width,
            height,
            depth,
        ),
        orientation: Some(direction),
        gen_depth: 0,
    }
}

/// `SinglePieceStructure.findGenerationPoint`: an allowed biome somewhere in
/// the centre column, the lowest corner of the `width` × `depth` area at or
/// above sea level, then the start on top of the chunk's centre.
pub fn single_piece(
    gc: &mut GenContext,
    def: &StructureDef,
    width: i32,
    depth: i32,
) -> Result<Option<Vec<Piece>>, String> {
    if !gc.could_exist_on_top_of_chunk_center()? {
        return Ok(None);
    }
    if gc.lowest_y(gc.min_block_x(), gc.min_block_z(), width, depth)? < gc.sea_level() {
        return Ok(None);
    }
    let position = gc.top_of_chunk_center(Heightmap::WorldSurfaceWg)?;
    if !gc.is_valid_biome(position) {
        return Ok(None);
    }
    let piece = match def.kind {
        StructureKind::DesertPyramid => scattered(gc, ScatteredKind::DesertPyramid, 21, 15, 21),
        StructureKind::JungleTemple => scattered(gc, ScatteredKind::JungleTemple, 12, 10, 15),
        _ => return Err(format!("{} is not a single-piece structure", def.id)),
    };
    Ok(Some(vec![piece]))
}

/// `Structure.onTopOfChunkCenter`: an allowed biome somewhere in the centre
/// column, then the start on top of the chunk's centre.
pub(super) fn on_top_of_chunk_center(
    gc: &mut GenContext,
    heightmap: Heightmap,
) -> Result<bool, String> {
    if !gc.could_exist_on_top_of_chunk_center()? {
        return Ok(false);
    }
    let position = gc.top_of_chunk_center(heightmap)?;
    Ok(gc.is_valid_biome(position))
}

pub fn swamp_hut(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    if !on_top_of_chunk_center(gc, Heightmap::WorldSurfaceWg)? {
        return Ok(None);
    }
    Ok(Some(vec![scattered(gc, ScatteredKind::SwampHut, 7, 7, 9)]))
}

/// Buried treasure: one block at (9, 90, 9) in the chunk.
pub fn buried_treasure(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    if !on_top_of_chunk_center(gc, Heightmap::OceanFloorWg)? {
        return Ok(None);
    }
    Ok(Some(vec![Piece {
        kind: PieceKind::BuriedTreasure,
        bbox: BoundingBox::at(gc.min_block_x() + 9, 90, gc.min_block_z() + 9),
        orientation: None,
        gen_depth: 0,
    }]))
}

// Placement (VMC-025f): each piece's `postProcess`, and the desert
// pyramid's `afterPlace`.

/// A scattered piece's `postProcess`.
pub fn post_process(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    match &piece.kind {
        PieceKind::Scattered { kind, .. } => match kind {
            ScatteredKind::DesertPyramid => desert_pyramid(piece, c),
            ScatteredKind::JungleTemple => jungle_temple(piece, c),
            ScatteredKind::SwampHut => place_swamp_hut(piece, c),
        },
        PieceKind::BuriedTreasure => buried_treasure_chest(piece, c),
        _ => Err("not a scattered piece".into()),
    }
}

/// The ground height and what placement did once, of a scattered piece.
fn scattered_state(piece: &mut Piece) -> (&mut BoundingBox, &mut i32, &mut [bool; 4], i32, i32) {
    match &mut piece.kind {
        PieceKind::Scattered {
            height_position,
            placed,
            width,
            depth,
            ..
        } => (&mut piece.bbox, height_position, placed, *width, *depth),
        _ => unreachable!("only scattered pieces have a ground height"),
    }
}

/// `ScatteredFeaturePiece.updateAverageGroundHeight`: once, the piece moves
/// to the mean surface of its columns in the chunk being placed.
fn average_ground_height(piece: &mut Piece, c: &mut Ctx, offset: i32) -> bool {
    let (bbox, height_position, ..) = scattered_state(piece);
    if *height_position >= 0 {
        return true;
    }
    let (mut total, mut count) = (0, 0);
    for z in bbox.min_z..=bbox.max_z {
        for x in bbox.min_x..=bbox.max_x {
            if c.chunk_box.is_inside(x, 64, z) {
                total += c.region.height_at(Heightmap::MotionBlockingNoLeaves, x, z);
                count += 1;
            }
        }
    }
    if count == 0 {
        return false;
    }
    *height_position = total / count;
    *bbox = bbox.moved(0, *height_position - bbox.min_y + offset, 0);
    true
}

/// `ScatteredFeaturePiece.updateHeightPositionToLowestGroundHeight`: once,
/// the piece moves to the lowest surface under all of it.
fn lowest_ground_height(piece: &mut Piece, c: &mut Ctx, offset: i32) -> bool {
    let (bbox, height_position, ..) = scattered_state(piece);
    if *height_position >= 0 {
        return true;
    }
    let mut lowest = c.region.min_y() + c.region.height();
    for z in bbox.min_z..=bbox.max_z {
        for x in bbox.min_x..=bbox.max_x {
            lowest = lowest.min(c.region.height_at(Heightmap::MotionBlockingNoLeaves, x, z));
        }
    }
    *height_position = lowest;
    *bbox = bbox.moved(0, lowest - bbox.min_y + offset, 0);
    true
}

const DESERT_PYRAMID_LOOT: &str = "minecraft:chests/desert_pyramid";
const DESERT_PYRAMID_ARCHAEOLOGY: &str = "minecraft:archaeology/desert_pyramid";
const JUNGLE_TEMPLE_LOOT: &str = "minecraft:chests/jungle_temple";
const JUNGLE_TEMPLE_DISPENSER_LOOT: &str = "minecraft:chests/jungle_temple_dispenser";
const BURIED_TREASURE_LOOT: &str = "minecraft:chests/buried_treasure";

fn desert_pyramid(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let offset = -c.random.next_int_bounded(3);
    if !lowest_ground_height(piece, c, offset) {
        return Ok(());
    }
    let f = Frame::new(piece.bbox, piece.orientation);
    let (_, _, placed, width, depth) = scattered_state(piece);
    let p = c.palette(pyramid::PALETTE)?;
    c.run(&f, &p, pyramid::BASE, None)?;
    for x in 0..width {
        for z in 0..depth {
            c.fill_column_down(&f, p[pyramid::SANDSTONE], x, -5, z);
        }
    }
    c.run(&f, &p, pyramid::BODY, None)?;
    // The trap room's chests, one per direction from its centre.
    for d in Direction::HORIZONTAL {
        let i = d.data_2d() as usize;
        if !placed[i] {
            let (dx, dz) = d.step();
            placed[i] =
                c.create_chest_at(&f, 10 + dx * 2, -11, 10 + dz * 2, DESERT_PYRAMID_LOOT)?;
        }
    }
    desert_cellar(&f, c)
}

/// `DesertPyramidPiece.addCellar`: the stairs down and the room around
/// (16, -4, 13), its sand ceiling partly collapsed (the level's random).
fn desert_cellar(f: &Frame, c: &mut Ctx) -> Result<(), String> {
    let p = c.palette(cellar::PALETTE)?;
    let stairs = c.state("sandstone_stairs[facing=west]")?;
    for (x, y) in [(13, -1), (14, -2), (15, -3)] {
        c.place(f, stairs, x, y, 17);
    }
    let (sand, sandstone) = (p[cellar::SAND], p[cellar::SANDSTONE]);
    let variant = c.region.random.next_bool();
    c.run(f, &p, cellar::STAIRS_SAND, None)?;
    c.place(f, if variant { sand } else { sandstone }, 15, -1, 17);
    c.place(f, if variant { sandstone } else { sand }, 16, -1, 17);
    c.run(f, &p, cellar::STAIRS_SAND_BELOW, None)?;
    c.run(f, &p, cellar::WALLS, None)?;
    for x in 14..=18 {
        for z in 11..=15 {
            let roof = if c.region.random.next_float() < 0.33 {
                sandstone
            } else {
                sand
            };
            c.place(f, roof, x, 0, z);
        }
    }
    c.run(f, &p, cellar::ROOM, None)
}

/// The cellar's sand that may become suspicious (`placeSand`), as world
/// positions.
fn cellar_sand(f: &Frame) -> Vec<[i32; 3]> {
    let mut out = Vec::with_capacity(83);
    for y in -3..=-1 {
        for x in 14..=18 {
            for z in 11..=15 {
                out.push(f.world(x, y, z));
            }
        }
    }
    for (x, z) in [(19, 13), (13, 13), (16, 16), (16, 10)] {
        out.push(f.world(x, -3, z));
        out.push(f.world(x, -2, z));
    }
    out
}

/// `randomCollapsedRoofPos`: a cellar ceiling block chosen from the seed.
fn collapsed_roof(f: &Frame, seed: i64) -> [i32; 3] {
    let at = f.world(14, 0, 11);
    let mut random = Random::legacy(seed)
        .fork_positional()
        .at(at[0], at[1], at[2]);
    let x = between_inclusive(&mut random, 14, 18);
    let z = between_inclusive(&mut random, 11, 15);
    [f.world_x(x, z), f.world_y(0), f.world_z(x, z)]
}

/// `DesertPyramidStructure.afterPlace`: the collapsed ceiling block and
/// five to seven of the cellar's sand blocks (shuffled from the seed at the
/// pieces' centre) become suspicious sand; the rest stays sand.
pub fn desert_pyramid_after_place(pieces: &[Piece], c: &mut Ctx) -> Result<(), String> {
    let mut sand = Vec::new();
    for piece in pieces {
        if let PieceKind::Scattered {
            kind: ScatteredKind::DesertPyramid,
            ..
        } = piece.kind
        {
            let f = Frame::new(piece.bbox, piece.orientation);
            sand.extend(cellar_sand(&f));
            suspicious_sand(c, collapsed_roof(&f, c.placer.seed))?;
        }
    }
    // `SortedArraySet` by `Vec3i.compareTo`: y, then z, then x.
    sand.sort_by_key(|p| (p[1], p[2], p[0]));
    sand.dedup();
    let Some(bbox) = encapsulating(pieces.iter().map(|p| &p.bbox)) else {
        return Ok(());
    };
    let (x, y, z) = bbox.center();
    let mut random = Random::legacy(c.placer.seed).fork_positional().at(x, y, z);
    shuffle(&mut sand, &mut random);
    let mut suspicious = (5 + random.next_int_bounded(3)).min(sand.len() as i32);
    let plain = c.state("sand")?;
    for pos in sand {
        if suspicious > 0 {
            suspicious -= 1;
            suspicious_sand(c, pos)?;
        } else if c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
            c.set(pos, plain, 2);
        }
    }
    Ok(())
}

/// `placeSuspiciousSand`: with the archaeology loot table, seeded by the
/// position.
fn suspicious_sand(c: &mut Ctx, pos: [i32; 3]) -> Result<(), String> {
    if !c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
        return Ok(());
    }
    let state = c.state("suspicious_sand")?;
    c.set(pos, state, 2);
    if let Some(entity) = c.region.block_entity(pos)? {
        if entity.kind == "minecraft:brushable_block" {
            entity.loot_table = Some(DESERT_PYRAMID_ARCHAEOLOGY.to_string());
            entity.loot_seed = block_pos_long(pos);
        }
    }
    Ok(())
}

fn jungle_temple(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    if !average_ground_height(piece, c, 0) {
        return Ok(());
    }
    let f = Frame::new(piece.bbox, piece.orientation);
    let (_, _, placed, ..) = scattered_state(piece);
    let p = c.palette(jungle::PALETTE)?;
    // `MossStoneSelector`.
    let (cobblestone, mossy) = (c.state("cobblestone")?, p[jungle::MOSSY_COBBLESTONE]);
    let mut stone = move |random: &mut Random, _: [i32; 3], _: bool| {
        if random.next_float() < 0.4 {
            cobblestone
        } else {
            mossy
        }
    };
    c.run(&f, &p, jungle::TEMPLE_1, Some(&mut stone))?;
    if !placed[2] {
        placed[2] =
            c.create_dispenser(&f, 3, -2, 1, Direction::North, JUNGLE_TEMPLE_DISPENSER_LOOT)?;
    }
    c.run(&f, &p, jungle::TEMPLE_2, Some(&mut stone))?;
    if !placed[3] {
        placed[3] =
            c.create_dispenser(&f, 9, -2, 3, Direction::West, JUNGLE_TEMPLE_DISPENSER_LOOT)?;
    }
    c.run(&f, &p, jungle::TEMPLE_3, Some(&mut stone))?;
    if !placed[0] {
        placed[0] = c.create_chest_at(&f, 8, -3, 3, JUNGLE_TEMPLE_LOOT)?;
    }
    c.run(&f, &p, jungle::TEMPLE_4, Some(&mut stone))?;
    if !placed[1] {
        placed[1] = c.create_chest_at(&f, 9, -3, 10, JUNGLE_TEMPLE_LOOT)?;
    }
    Ok(())
}

fn place_swamp_hut(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    if !average_ground_height(piece, c, 0) {
        return Ok(());
    }
    let f = Frame::new(piece.bbox, piece.orientation);
    let (_, _, placed, ..) = scattered_state(piece);
    let p = c.palette(hut::PALETTE)?;
    c.run(&f, &p, hut::HUT_1, None)?;
    // The witch, then the cat, inside at (2, 2, 5). Entities are recorded
    // (type, position, yaw); `finalizeSpawn` draws from the level's random:
    // the follow range bonus and left-handedness, and the cat's variant and
    // sound variant.
    let pos = f.world(2, 2, 5);
    for (i, kind) in [(0, "minecraft:witch"), (1, "minecraft:cat")] {
        if placed[i] || !c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
            continue;
        }
        placed[i] = true;
        c.region.add_entity(Entity {
            kind,
            pos: [pos[0] as f64 + 0.5, pos[1] as f64, pos[2] as f64 + 0.5],
            persistent: true,
            ..Entity::default()
        });
        let random = &mut c.region.random;
        random.next_double();
        random.next_double();
        random.next_float();
        if kind == "minecraft:cat" {
            random.next_int_bounded(1);
            random.next_int_bounded(CAT_SOUND_VARIANTS);
        }
    }
    Ok(())
}

/// The cat sound variant registry's size (classic, royal).
const CAT_SOUND_VARIANTS: i32 = 2;

/// `BuriedTreasurePieces.BuriedTreasurePiece.postProcess`: down from the
/// ocean floor to the first block over stone-like ground, which is walled
/// in and becomes the chest (and the piece's box).
fn buried_treasure_chest(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let table = c.placer.table;
    let (x, z) = (piece.bbox.min_x, piece.bbox.min_z);
    let mut y = c.region.height_at(Heightmap::OceanFloorWg, x, z);
    let ground = ["sandstone", "stone", "andesite", "granite", "diorite"]
        .iter()
        .map(|n| table.block(n))
        .collect::<Result<Vec<_>, _>>()?;
    let (water, lava) = (table.block("water")?, table.block("lava")?);
    let liquid = |state: u16| {
        let block = table.block_of(state);
        block == water || block == lava
    };
    let sand = c.state("sand")?;
    while y > c.region.min_y() {
        let here = c.region.get([x, y, z]);
        let below = c.region.get([x, y - 1, z]);
        if ground.contains(&table.block_of(below)) {
            let soft = if !table.is_air(here) && !liquid(here) {
                here
            } else {
                sand
            };
            // `Direction.values()`: down, up, north, south, west, east.
            for (dx, dy, dz) in [
                (0, -1, 0),
                (0, 1, 0),
                (0, 0, -1),
                (0, 0, 1),
                (-1, 0, 0),
                (1, 0, 0),
            ] {
                let at = [x + dx, y + dy, z + dz];
                let state = c.region.get(at);
                if table.is_air(state) || liquid(state) {
                    let under = c.region.get([at[0], at[1] - 1, at[2]]);
                    let fill = if (table.is_air(under) || liquid(under)) && dy != 1 {
                        below
                    } else {
                        soft
                    };
                    c.set(at, fill, 3);
                }
            }
            piece.bbox = BoundingBox::at(x, y, z);
            c.create_chest([x, y, z], BURIED_TREASURE_LOOT, None)?;
            return Ok(());
        }
        y -= 1;
    }
    Ok(())
}
mod pyramid {
    use super::Op::{self, *};

    pub const SANDSTONE: usize = 0;
    pub const AIR: usize = 1;
    pub const SANDSTONE_STAIRS_FACING_NORTH: usize = 2;
    pub const SANDSTONE_STAIRS_FACING_SOUTH: usize = 3;
    pub const SANDSTONE_STAIRS_FACING_EAST: usize = 4;
    pub const SANDSTONE_STAIRS_FACING_WEST: usize = 5;
    pub const CUT_SANDSTONE: usize = 6;
    pub const SANDSTONE_SLAB: usize = 7;
    pub const CHISELED_SANDSTONE: usize = 8;
    pub const ORANGE_TERRACOTTA: usize = 9;
    pub const BLUE_TERRACOTTA: usize = 10;
    pub const STONE_PRESSURE_PLATE: usize = 11;
    pub const TNT: usize = 12;
    pub const PALETTE: &[&str] = &[
        "sandstone",
        "air",
        "sandstone_stairs[facing=north]",
        "sandstone_stairs[facing=south]",
        "sandstone_stairs[facing=east]",
        "sandstone_stairs[facing=west]",
        "cut_sandstone",
        "sandstone_slab",
        "chiseled_sandstone",
        "orange_terracotta",
        "blue_terracotta",
        "stone_pressure_plate",
        "tnt",
    ];
    /// The base and its steps.
    pub const BASE: &[Op] = &[
        B(0, -4, 0, 20, 0, 20, SANDSTONE, SANDSTONE),
        B(1, 1, 1, 19, 1, 19, SANDSTONE, SANDSTONE),
        B(2, 1, 2, 18, 1, 18, AIR, AIR),
        B(2, 2, 2, 18, 2, 18, SANDSTONE, SANDSTONE),
        B(3, 2, 3, 17, 2, 17, AIR, AIR),
        B(3, 3, 3, 17, 3, 17, SANDSTONE, SANDSTONE),
        B(4, 3, 4, 16, 3, 16, AIR, AIR),
        B(4, 4, 4, 16, 4, 16, SANDSTONE, SANDSTONE),
        B(5, 4, 5, 15, 4, 15, AIR, AIR),
        B(5, 5, 5, 15, 5, 15, SANDSTONE, SANDSTONE),
        B(6, 5, 6, 14, 5, 14, AIR, AIR),
        B(6, 6, 6, 14, 6, 14, SANDSTONE, SANDSTONE),
        B(7, 6, 7, 13, 6, 13, AIR, AIR),
        B(7, 7, 7, 13, 7, 13, SANDSTONE, SANDSTONE),
        B(8, 7, 8, 12, 7, 12, AIR, AIR),
        B(8, 8, 8, 12, 8, 12, SANDSTONE, SANDSTONE),
        B(9, 8, 9, 11, 8, 11, AIR, AIR),
        B(9, 9, 9, 11, 9, 11, SANDSTONE, SANDSTONE),
        B(10, 9, 10, 10, 9, 10, AIR, AIR),
    ];
    /// The towers, entrance, rooms, decoration and the trap room.
    pub const BODY: &[Op] = &[
        B(0, 0, 0, 4, 9, 4, SANDSTONE, AIR),
        B(1, 10, 1, 3, 10, 3, SANDSTONE, SANDSTONE),
        P(SANDSTONE_STAIRS_FACING_NORTH, 2, 10, 0),
        P(SANDSTONE_STAIRS_FACING_SOUTH, 2, 10, 4),
        P(SANDSTONE_STAIRS_FACING_EAST, 0, 10, 2),
        P(SANDSTONE_STAIRS_FACING_WEST, 4, 10, 2),
        B(16, 0, 0, 20, 9, 4, SANDSTONE, AIR),
        B(17, 10, 1, 19, 10, 3, SANDSTONE, SANDSTONE),
        P(SANDSTONE_STAIRS_FACING_NORTH, 18, 10, 0),
        P(SANDSTONE_STAIRS_FACING_SOUTH, 18, 10, 4),
        P(SANDSTONE_STAIRS_FACING_EAST, 16, 10, 2),
        P(SANDSTONE_STAIRS_FACING_WEST, 20, 10, 2),
        B(8, 0, 0, 12, 4, 4, SANDSTONE, AIR),
        B(9, 1, 0, 11, 3, 4, AIR, AIR),
        P(CUT_SANDSTONE, 9, 1, 1),
        P(CUT_SANDSTONE, 9, 2, 1),
        P(CUT_SANDSTONE, 9, 3, 1),
        P(CUT_SANDSTONE, 10, 3, 1),
        P(CUT_SANDSTONE, 11, 3, 1),
        P(CUT_SANDSTONE, 11, 2, 1),
        P(CUT_SANDSTONE, 11, 1, 1),
        B(4, 1, 1, 8, 3, 3, SANDSTONE, AIR),
        B(4, 1, 2, 8, 2, 2, AIR, AIR),
        B(12, 1, 1, 16, 3, 3, SANDSTONE, AIR),
        B(12, 1, 2, 16, 2, 2, AIR, AIR),
        B(5, 4, 5, 15, 4, 15, SANDSTONE, SANDSTONE),
        B(9, 4, 9, 11, 4, 11, AIR, AIR),
        B(8, 1, 8, 8, 3, 8, CUT_SANDSTONE, CUT_SANDSTONE),
        B(12, 1, 8, 12, 3, 8, CUT_SANDSTONE, CUT_SANDSTONE),
        B(8, 1, 12, 8, 3, 12, CUT_SANDSTONE, CUT_SANDSTONE),
        B(12, 1, 12, 12, 3, 12, CUT_SANDSTONE, CUT_SANDSTONE),
        B(1, 1, 5, 4, 4, 11, SANDSTONE, SANDSTONE),
        B(16, 1, 5, 19, 4, 11, SANDSTONE, SANDSTONE),
        B(6, 7, 9, 6, 7, 11, SANDSTONE, SANDSTONE),
        B(14, 7, 9, 14, 7, 11, SANDSTONE, SANDSTONE),
        B(5, 5, 9, 5, 7, 11, CUT_SANDSTONE, CUT_SANDSTONE),
        B(15, 5, 9, 15, 7, 11, CUT_SANDSTONE, CUT_SANDSTONE),
        P(AIR, 5, 5, 10),
        P(AIR, 5, 6, 10),
        P(AIR, 6, 6, 10),
        P(AIR, 15, 5, 10),
        P(AIR, 15, 6, 10),
        P(AIR, 14, 6, 10),
        B(2, 4, 4, 2, 6, 4, AIR, AIR),
        B(18, 4, 4, 18, 6, 4, AIR, AIR),
        P(SANDSTONE_STAIRS_FACING_NORTH, 2, 4, 5),
        P(SANDSTONE_STAIRS_FACING_NORTH, 2, 3, 4),
        P(SANDSTONE_STAIRS_FACING_NORTH, 18, 4, 5),
        P(SANDSTONE_STAIRS_FACING_NORTH, 18, 3, 4),
        B(1, 1, 3, 2, 2, 3, SANDSTONE, SANDSTONE),
        B(18, 1, 3, 19, 2, 3, SANDSTONE, SANDSTONE),
        P(SANDSTONE, 1, 1, 2),
        P(SANDSTONE, 19, 1, 2),
        P(SANDSTONE_SLAB, 1, 2, 2),
        P(SANDSTONE_SLAB, 19, 2, 2),
        P(SANDSTONE_STAIRS_FACING_WEST, 2, 1, 2),
        P(SANDSTONE_STAIRS_FACING_EAST, 18, 1, 2),
        B(4, 3, 5, 4, 3, 17, SANDSTONE, SANDSTONE),
        B(16, 3, 5, 16, 3, 17, SANDSTONE, SANDSTONE),
        B(3, 1, 5, 4, 2, 16, AIR, AIR),
        B(15, 1, 5, 16, 2, 16, AIR, AIR),
        P(CUT_SANDSTONE, 4, 1, 5),
        P(CHISELED_SANDSTONE, 4, 2, 5),
        P(CUT_SANDSTONE, 16, 1, 5),
        P(CHISELED_SANDSTONE, 16, 2, 5),
        P(CUT_SANDSTONE, 4, 1, 7),
        P(CHISELED_SANDSTONE, 4, 2, 7),
        P(CUT_SANDSTONE, 16, 1, 7),
        P(CHISELED_SANDSTONE, 16, 2, 7),
        P(CUT_SANDSTONE, 4, 1, 9),
        P(CHISELED_SANDSTONE, 4, 2, 9),
        P(CUT_SANDSTONE, 16, 1, 9),
        P(CHISELED_SANDSTONE, 16, 2, 9),
        P(CUT_SANDSTONE, 4, 1, 11),
        P(CHISELED_SANDSTONE, 4, 2, 11),
        P(CUT_SANDSTONE, 16, 1, 11),
        P(CHISELED_SANDSTONE, 16, 2, 11),
        P(CUT_SANDSTONE, 4, 1, 13),
        P(CHISELED_SANDSTONE, 4, 2, 13),
        P(CUT_SANDSTONE, 16, 1, 13),
        P(CHISELED_SANDSTONE, 16, 2, 13),
        P(CUT_SANDSTONE, 4, 1, 15),
        P(CHISELED_SANDSTONE, 4, 2, 15),
        P(CUT_SANDSTONE, 16, 1, 15),
        P(CHISELED_SANDSTONE, 16, 2, 15),
        P(CUT_SANDSTONE, 4, 1, 17),
        P(CHISELED_SANDSTONE, 4, 2, 17),
        P(CUT_SANDSTONE, 16, 1, 17),
        P(CHISELED_SANDSTONE, 16, 2, 17),
        P(ORANGE_TERRACOTTA, 10, 0, 7),
        P(ORANGE_TERRACOTTA, 10, 0, 8),
        P(ORANGE_TERRACOTTA, 9, 0, 9),
        P(ORANGE_TERRACOTTA, 11, 0, 9),
        P(ORANGE_TERRACOTTA, 8, 0, 10),
        P(ORANGE_TERRACOTTA, 12, 0, 10),
        P(ORANGE_TERRACOTTA, 7, 0, 10),
        P(ORANGE_TERRACOTTA, 13, 0, 10),
        P(ORANGE_TERRACOTTA, 9, 0, 11),
        P(ORANGE_TERRACOTTA, 11, 0, 11),
        P(ORANGE_TERRACOTTA, 10, 0, 12),
        P(ORANGE_TERRACOTTA, 10, 0, 13),
        P(BLUE_TERRACOTTA, 10, 0, 10),
        P(CUT_SANDSTONE, 0, 2, 1),
        P(ORANGE_TERRACOTTA, 0, 2, 2),
        P(CUT_SANDSTONE, 0, 2, 3),
        P(CUT_SANDSTONE, 0, 3, 1),
        P(ORANGE_TERRACOTTA, 0, 3, 2),
        P(CUT_SANDSTONE, 0, 3, 3),
        P(ORANGE_TERRACOTTA, 0, 4, 1),
        P(CHISELED_SANDSTONE, 0, 4, 2),
        P(ORANGE_TERRACOTTA, 0, 4, 3),
        P(CUT_SANDSTONE, 0, 5, 1),
        P(ORANGE_TERRACOTTA, 0, 5, 2),
        P(CUT_SANDSTONE, 0, 5, 3),
        P(ORANGE_TERRACOTTA, 0, 6, 1),
        P(CHISELED_SANDSTONE, 0, 6, 2),
        P(ORANGE_TERRACOTTA, 0, 6, 3),
        P(ORANGE_TERRACOTTA, 0, 7, 1),
        P(ORANGE_TERRACOTTA, 0, 7, 2),
        P(ORANGE_TERRACOTTA, 0, 7, 3),
        P(CUT_SANDSTONE, 0, 8, 1),
        P(CUT_SANDSTONE, 0, 8, 2),
        P(CUT_SANDSTONE, 0, 8, 3),
        P(CUT_SANDSTONE, 20, 2, 1),
        P(ORANGE_TERRACOTTA, 20, 2, 2),
        P(CUT_SANDSTONE, 20, 2, 3),
        P(CUT_SANDSTONE, 20, 3, 1),
        P(ORANGE_TERRACOTTA, 20, 3, 2),
        P(CUT_SANDSTONE, 20, 3, 3),
        P(ORANGE_TERRACOTTA, 20, 4, 1),
        P(CHISELED_SANDSTONE, 20, 4, 2),
        P(ORANGE_TERRACOTTA, 20, 4, 3),
        P(CUT_SANDSTONE, 20, 5, 1),
        P(ORANGE_TERRACOTTA, 20, 5, 2),
        P(CUT_SANDSTONE, 20, 5, 3),
        P(ORANGE_TERRACOTTA, 20, 6, 1),
        P(CHISELED_SANDSTONE, 20, 6, 2),
        P(ORANGE_TERRACOTTA, 20, 6, 3),
        P(ORANGE_TERRACOTTA, 20, 7, 1),
        P(ORANGE_TERRACOTTA, 20, 7, 2),
        P(ORANGE_TERRACOTTA, 20, 7, 3),
        P(CUT_SANDSTONE, 20, 8, 1),
        P(CUT_SANDSTONE, 20, 8, 2),
        P(CUT_SANDSTONE, 20, 8, 3),
        P(CUT_SANDSTONE, 1, 2, 0),
        P(ORANGE_TERRACOTTA, 2, 2, 0),
        P(CUT_SANDSTONE, 3, 2, 0),
        P(CUT_SANDSTONE, 1, 3, 0),
        P(ORANGE_TERRACOTTA, 2, 3, 0),
        P(CUT_SANDSTONE, 3, 3, 0),
        P(ORANGE_TERRACOTTA, 1, 4, 0),
        P(CHISELED_SANDSTONE, 2, 4, 0),
        P(ORANGE_TERRACOTTA, 3, 4, 0),
        P(CUT_SANDSTONE, 1, 5, 0),
        P(ORANGE_TERRACOTTA, 2, 5, 0),
        P(CUT_SANDSTONE, 3, 5, 0),
        P(ORANGE_TERRACOTTA, 1, 6, 0),
        P(CHISELED_SANDSTONE, 2, 6, 0),
        P(ORANGE_TERRACOTTA, 3, 6, 0),
        P(ORANGE_TERRACOTTA, 1, 7, 0),
        P(ORANGE_TERRACOTTA, 2, 7, 0),
        P(ORANGE_TERRACOTTA, 3, 7, 0),
        P(CUT_SANDSTONE, 1, 8, 0),
        P(CUT_SANDSTONE, 2, 8, 0),
        P(CUT_SANDSTONE, 3, 8, 0),
        P(CUT_SANDSTONE, 17, 2, 0),
        P(ORANGE_TERRACOTTA, 18, 2, 0),
        P(CUT_SANDSTONE, 19, 2, 0),
        P(CUT_SANDSTONE, 17, 3, 0),
        P(ORANGE_TERRACOTTA, 18, 3, 0),
        P(CUT_SANDSTONE, 19, 3, 0),
        P(ORANGE_TERRACOTTA, 17, 4, 0),
        P(CHISELED_SANDSTONE, 18, 4, 0),
        P(ORANGE_TERRACOTTA, 19, 4, 0),
        P(CUT_SANDSTONE, 17, 5, 0),
        P(ORANGE_TERRACOTTA, 18, 5, 0),
        P(CUT_SANDSTONE, 19, 5, 0),
        P(ORANGE_TERRACOTTA, 17, 6, 0),
        P(CHISELED_SANDSTONE, 18, 6, 0),
        P(ORANGE_TERRACOTTA, 19, 6, 0),
        P(ORANGE_TERRACOTTA, 17, 7, 0),
        P(ORANGE_TERRACOTTA, 18, 7, 0),
        P(ORANGE_TERRACOTTA, 19, 7, 0),
        P(CUT_SANDSTONE, 17, 8, 0),
        P(CUT_SANDSTONE, 18, 8, 0),
        P(CUT_SANDSTONE, 19, 8, 0),
        B(8, 4, 0, 12, 6, 0, CUT_SANDSTONE, CUT_SANDSTONE),
        P(AIR, 8, 6, 0),
        P(AIR, 12, 6, 0),
        P(ORANGE_TERRACOTTA, 9, 5, 0),
        P(CHISELED_SANDSTONE, 10, 5, 0),
        P(ORANGE_TERRACOTTA, 11, 5, 0),
        B(8, -14, 8, 12, -11, 12, CUT_SANDSTONE, CUT_SANDSTONE),
        B(
            8,
            -10,
            8,
            12,
            -10,
            12,
            CHISELED_SANDSTONE,
            CHISELED_SANDSTONE,
        ),
        B(8, -9, 8, 12, -9, 12, CUT_SANDSTONE, CUT_SANDSTONE),
        B(8, -8, 8, 12, -1, 12, SANDSTONE, SANDSTONE),
        B(9, -11, 9, 11, -1, 11, AIR, AIR),
        P(STONE_PRESSURE_PLATE, 10, -11, 10),
        B(9, -13, 9, 11, -13, 11, TNT, AIR),
        P(AIR, 8, -11, 10),
        P(AIR, 8, -10, 10),
        P(CHISELED_SANDSTONE, 7, -10, 10),
        P(CUT_SANDSTONE, 7, -11, 10),
        P(AIR, 12, -11, 10),
        P(AIR, 12, -10, 10),
        P(CHISELED_SANDSTONE, 13, -10, 10),
        P(CUT_SANDSTONE, 13, -11, 10),
        P(AIR, 10, -11, 8),
        P(AIR, 10, -10, 8),
        P(CHISELED_SANDSTONE, 10, -10, 7),
        P(CUT_SANDSTONE, 10, -11, 7),
        P(AIR, 10, -11, 12),
        P(AIR, 10, -10, 12),
        P(CHISELED_SANDSTONE, 10, -10, 13),
        P(CUT_SANDSTONE, 10, -11, 13),
    ];
}

mod cellar {
    use super::Op::{self, *};

    pub const SAND: usize = 0;
    pub const SANDSTONE: usize = 1;
    pub const CUT_SANDSTONE: usize = 2;
    pub const CHISELED_SANDSTONE: usize = 3;
    pub const BLUE_TERRACOTTA: usize = 4;
    pub const ORANGE_TERRACOTTA: usize = 5;
    pub const PALETTE: &[&str] = &[
        "sand",
        "sandstone",
        "cut_sandstone",
        "chiseled_sandstone",
        "blue_terracotta",
        "orange_terracotta",
    ];
    /// The sand over the stairs, before and after its two random blocks.
    pub const STAIRS_SAND: &[Op] = &[
        P(SAND, 12, 0, 17),
        P(SAND, 13, 0, 17),
        P(SAND, 14, 0, 17),
        P(SAND, 15, 0, 17),
        P(SAND, 16, 0, 17),
        P(SAND, 14, -1, 17),
    ];
    pub const STAIRS_SAND_BELOW: &[Op] = &[
        P(SAND, 15, -2, 17),
        P(SANDSTONE, 16, -2, 17),
        P(SAND, 16, -3, 17),
    ];
    /// The room's walls.
    pub const WALLS: &[Op] = &[
        S(13, -3, 10, 13, -3, 15, CUT_SANDSTONE, CUT_SANDSTONE),
        S(19, -3, 10, 19, -3, 15, CUT_SANDSTONE, CUT_SANDSTONE),
        S(13, -3, 10, 19, -3, 11, CUT_SANDSTONE, CUT_SANDSTONE),
        S(13, -3, 16, 19, -3, 16, CUT_SANDSTONE, CUT_SANDSTONE),
        S(
            13,
            -2,
            10,
            13,
            -2,
            15,
            CHISELED_SANDSTONE,
            CHISELED_SANDSTONE,
        ),
        S(
            19,
            -2,
            10,
            19,
            -2,
            15,
            CHISELED_SANDSTONE,
            CHISELED_SANDSTONE,
        ),
        S(
            13,
            -2,
            10,
            19,
            -2,
            11,
            CHISELED_SANDSTONE,
            CHISELED_SANDSTONE,
        ),
        S(
            13,
            -2,
            16,
            19,
            -2,
            16,
            CHISELED_SANDSTONE,
            CHISELED_SANDSTONE,
        ),
        S(13, -1, 10, 13, -1, 15, CUT_SANDSTONE, CUT_SANDSTONE),
        S(19, -1, 10, 19, -1, 15, CUT_SANDSTONE, CUT_SANDSTONE),
        S(13, -1, 10, 19, -1, 11, CUT_SANDSTONE, CUT_SANDSTONE),
        S(13, -1, 16, 19, -1, 16, CUT_SANDSTONE, CUT_SANDSTONE),
    ];
    /// The room's floor and the ends of its sand columns.
    pub const ROOM: &[Op] = &[
        P(BLUE_TERRACOTTA, 16, -4, 13),
        P(ORANGE_TERRACOTTA, 17, -4, 12),
        P(ORANGE_TERRACOTTA, 17, -4, 14),
        P(ORANGE_TERRACOTTA, 15, -4, 12),
        P(ORANGE_TERRACOTTA, 15, -4, 14),
        P(ORANGE_TERRACOTTA, 18, -4, 13),
        P(ORANGE_TERRACOTTA, 14, -4, 13),
        P(ORANGE_TERRACOTTA, 16, -4, 15),
        P(ORANGE_TERRACOTTA, 16, -4, 11),
        P(ORANGE_TERRACOTTA, 19, -4, 13),
        P(CUT_SANDSTONE, 20, -3, 13),
        P(CHISELED_SANDSTONE, 20, -2, 13),
        P(ORANGE_TERRACOTTA, 13, -4, 13),
        P(CUT_SANDSTONE, 12, -3, 13),
        P(CHISELED_SANDSTONE, 12, -2, 13),
        P(ORANGE_TERRACOTTA, 16, -4, 16),
        P(ORANGE_TERRACOTTA, 16, -4, 10),
        P(CUT_SANDSTONE, 16, -3, 9),
        P(CHISELED_SANDSTONE, 16, -2, 9),
    ];
}

mod jungle {
    use super::Op::{self, *};

    pub const AIR: usize = 0;
    pub const COBBLESTONE_STAIRS_FACING_NORTH: usize = 1;
    pub const COBBLESTONE_STAIRS_FACING_SOUTH: usize = 2;
    pub const COBBLESTONE_STAIRS_FACING_EAST: usize = 3;
    pub const COBBLESTONE_STAIRS_FACING_WEST: usize = 4;
    pub const TRIPWIRE_HOOK_FACING_EAST_ATTACHED_TRUE: usize = 5;
    pub const TRIPWIRE_HOOK_FACING_WEST_ATTACHED_TRUE: usize = 6;
    pub const TRIPWIRE_EAST_TRUE_WEST_TRUE_ATTACHED_TRUE: usize = 7;
    pub const REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE: usize = 8;
    pub const REDSTONE_WIRE_NORTH_SIDE_WEST_SIDE: usize = 9;
    pub const REDSTONE_WIRE_EAST_SIDE_WEST_SIDE: usize = 10;
    pub const MOSSY_COBBLESTONE: usize = 11;
    pub const VINE_SOUTH_TRUE: usize = 12;
    pub const TRIPWIRE_HOOK_FACING_NORTH_ATTACHED_TRUE: usize = 13;
    pub const TRIPWIRE_HOOK_FACING_SOUTH_ATTACHED_TRUE: usize = 14;
    pub const TRIPWIRE_NORTH_TRUE_SOUTH_TRUE_ATTACHED_TRUE: usize = 15;
    pub const REDSTONE_WIRE_WEST_SIDE_SOUTH_SIDE: usize = 16;
    pub const REDSTONE_WIRE_NORTH_SIDE_SOUTH_UP: usize = 17;
    pub const VINE_EAST_TRUE: usize = 18;
    pub const CHISELED_STONE_BRICKS: usize = 19;
    pub const LEVER_FACING_NORTH_FACE_WALL: usize = 20;
    pub const REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE_EAST_SIDE_WEST_SIDE: usize = 21;
    pub const STICKY_PISTON_FACING_UP: usize = 22;
    pub const STICKY_PISTON_FACING_WEST: usize = 23;
    pub const REPEATER_FACING_NORTH: usize = 24;
    pub const PALETTE: &[&str] = &[
        "air",
        "cobblestone_stairs[facing=north]",
        "cobblestone_stairs[facing=south]",
        "cobblestone_stairs[facing=east]",
        "cobblestone_stairs[facing=west]",
        "tripwire_hook[facing=east,attached=true]",
        "tripwire_hook[facing=west,attached=true]",
        "tripwire[east=true,west=true,attached=true]",
        "redstone_wire[north=side,south=side]",
        "redstone_wire[north=side,west=side]",
        "redstone_wire[east=side,west=side]",
        "mossy_cobblestone",
        "vine[south=true]",
        "tripwire_hook[facing=north,attached=true]",
        "tripwire_hook[facing=south,attached=true]",
        "tripwire[north=true,south=true,attached=true]",
        "redstone_wire[west=side,south=side]",
        "redstone_wire[north=side,south=up]",
        "vine[east=true]",
        "chiseled_stone_bricks",
        "lever[facing=north,face=wall]",
        "redstone_wire[north=side,south=side,east=side,west=side]",
        "sticky_piston[facing=up]",
        "sticky_piston[facing=west]",
        "repeater[facing=north]",
    ];
    pub const TEMPLE_1: &[Op] = &[
        R(0, -4, 0, 11, 0, 14),
        R(2, 1, 2, 9, 2, 2),
        R(2, 1, 12, 9, 2, 12),
        R(2, 1, 3, 2, 2, 11),
        R(9, 1, 3, 9, 2, 11),
        R(1, 3, 1, 10, 6, 1),
        R(1, 3, 13, 10, 6, 13),
        R(1, 3, 2, 1, 6, 12),
        R(10, 3, 2, 10, 6, 12),
        R(2, 3, 2, 9, 3, 12),
        R(2, 6, 2, 9, 6, 12),
        R(3, 7, 3, 8, 7, 11),
        R(4, 8, 4, 7, 8, 10),
        A(3, 1, 3, 8, 2, 11),
        A(4, 3, 6, 7, 3, 9),
        A(2, 4, 2, 9, 5, 12),
        A(4, 6, 5, 7, 6, 9),
        A(5, 7, 6, 6, 7, 8),
        A(5, 1, 2, 6, 2, 2),
        A(5, 2, 12, 6, 2, 12),
        A(5, 5, 1, 6, 5, 1),
        A(5, 5, 13, 6, 5, 13),
        P(AIR, 1, 5, 5),
        P(AIR, 10, 5, 5),
        P(AIR, 1, 5, 9),
        P(AIR, 10, 5, 9),
        R(2, 4, 0, 2, 5, 0),
        R(4, 4, 0, 4, 5, 0),
        R(7, 4, 0, 7, 5, 0),
        R(9, 4, 0, 9, 5, 0),
        R(2, 4, 14, 2, 5, 14),
        R(4, 4, 14, 4, 5, 14),
        R(7, 4, 14, 7, 5, 14),
        R(9, 4, 14, 9, 5, 14),
        R(5, 6, 0, 6, 6, 0),
        R(0, 4, 2, 0, 5, 2),
        R(0, 4, 4, 0, 5, 4),
        R(0, 4, 6, 0, 5, 6),
        R(0, 4, 8, 0, 5, 8),
        R(0, 4, 10, 0, 5, 10),
        R(0, 4, 12, 0, 5, 12),
        R(0, 6, 5, 0, 6, 5),
        R(0, 6, 9, 0, 6, 9),
        R(11, 4, 2, 11, 5, 2),
        R(11, 4, 4, 11, 5, 4),
        R(11, 4, 6, 11, 5, 6),
        R(11, 4, 8, 11, 5, 8),
        R(11, 4, 10, 11, 5, 10),
        R(11, 4, 12, 11, 5, 12),
        R(11, 6, 5, 11, 6, 5),
        R(11, 6, 9, 11, 6, 9),
        R(2, 7, 2, 2, 9, 2),
        R(9, 7, 2, 9, 9, 2),
        R(2, 7, 12, 2, 9, 12),
        R(9, 7, 12, 9, 9, 12),
        R(4, 9, 4, 4, 9, 4),
        R(7, 9, 4, 7, 9, 4),
        R(4, 9, 10, 4, 9, 10),
        R(7, 9, 10, 7, 9, 10),
        R(5, 9, 7, 6, 9, 7),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 5, 9, 6),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 6, 9, 6),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 5, 9, 8),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 6, 9, 8),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 4, 0, 0),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 5, 0, 0),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 6, 0, 0),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 7, 0, 0),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 4, 1, 8),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 4, 2, 9),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 4, 3, 10),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 7, 1, 8),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 7, 2, 9),
        P(COBBLESTONE_STAIRS_FACING_NORTH, 7, 3, 10),
        R(4, 1, 9, 4, 1, 9),
        R(7, 1, 9, 7, 1, 9),
        R(4, 1, 10, 7, 2, 10),
        R(5, 4, 5, 6, 4, 5),
        P(COBBLESTONE_STAIRS_FACING_EAST, 4, 4, 5),
        P(COBBLESTONE_STAIRS_FACING_WEST, 7, 4, 5),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 5, 0, 6),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 6, 0, 6),
        A(5, 0, 7, 6, 0, 9),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 5, -1, 7),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 6, -1, 7),
        A(5, -1, 8, 6, -1, 10),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 5, -2, 8),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 6, -2, 8),
        A(5, -2, 9, 6, -2, 11),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 5, -3, 9),
        P(COBBLESTONE_STAIRS_FACING_SOUTH, 6, -3, 9),
        A(5, -3, 10, 6, -3, 12),
        A(1, -3, 12, 10, -1, 13),
        A(1, -3, 1, 3, -1, 13),
        A(1, -3, 1, 9, -1, 5),
        R(1, -3, 1, 1, -2, 1),
        R(1, -3, 3, 1, -2, 3),
        R(1, -3, 5, 1, -2, 5),
        R(1, -3, 7, 1, -2, 7),
        R(1, -3, 9, 1, -2, 9),
        R(1, -3, 11, 1, -2, 11),
        R(1, -3, 13, 1, -2, 13),
        R(1, -1, 2, 3, -1, 2),
        R(1, -1, 4, 3, -1, 4),
        R(1, -1, 6, 3, -1, 6),
        R(1, -1, 8, 3, -1, 8),
        R(1, -1, 10, 3, -1, 10),
        R(1, -1, 12, 3, -1, 12),
        R(2, -2, 1, 5, -2, 1),
        R(7, -2, 1, 9, -2, 1),
        R(6, -3, 1, 6, -3, 1),
        R(6, -1, 1, 6, -1, 1),
        P(TRIPWIRE_HOOK_FACING_EAST_ATTACHED_TRUE, 1, -3, 8),
        P(TRIPWIRE_HOOK_FACING_WEST_ATTACHED_TRUE, 4, -3, 8),
        P(TRIPWIRE_EAST_TRUE_WEST_TRUE_ATTACHED_TRUE, 2, -3, 8),
        P(TRIPWIRE_EAST_TRUE_WEST_TRUE_ATTACHED_TRUE, 3, -3, 8),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 7),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 6),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 5),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 4),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 3),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 5, -3, 2),
        P(REDSTONE_WIRE_NORTH_SIDE_WEST_SIDE, 5, -3, 1),
        P(REDSTONE_WIRE_EAST_SIDE_WEST_SIDE, 4, -3, 1),
        P(MOSSY_COBBLESTONE, 3, -3, 1),
    ];
    pub const TEMPLE_2: &[Op] = &[
        P(VINE_SOUTH_TRUE, 3, -2, 2),
        P(TRIPWIRE_HOOK_FACING_NORTH_ATTACHED_TRUE, 7, -3, 1),
        P(TRIPWIRE_HOOK_FACING_SOUTH_ATTACHED_TRUE, 7, -3, 5),
        P(TRIPWIRE_NORTH_TRUE_SOUTH_TRUE_ATTACHED_TRUE, 7, -3, 2),
        P(TRIPWIRE_NORTH_TRUE_SOUTH_TRUE_ATTACHED_TRUE, 7, -3, 3),
        P(TRIPWIRE_NORTH_TRUE_SOUTH_TRUE_ATTACHED_TRUE, 7, -3, 4),
        P(REDSTONE_WIRE_EAST_SIDE_WEST_SIDE, 8, -3, 6),
        P(REDSTONE_WIRE_WEST_SIDE_SOUTH_SIDE, 9, -3, 6),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_UP, 9, -3, 5),
        P(MOSSY_COBBLESTONE, 9, -3, 4),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 9, -2, 4),
    ];
    pub const TEMPLE_3: &[Op] = &[P(VINE_EAST_TRUE, 8, -1, 3), P(VINE_EAST_TRUE, 8, -2, 3)];
    pub const TEMPLE_4: &[Op] = &[
        P(MOSSY_COBBLESTONE, 9, -3, 2),
        P(MOSSY_COBBLESTONE, 8, -3, 1),
        P(MOSSY_COBBLESTONE, 4, -3, 5),
        P(MOSSY_COBBLESTONE, 5, -2, 5),
        P(MOSSY_COBBLESTONE, 5, -1, 5),
        P(MOSSY_COBBLESTONE, 6, -3, 5),
        P(MOSSY_COBBLESTONE, 7, -2, 5),
        P(MOSSY_COBBLESTONE, 7, -1, 5),
        P(MOSSY_COBBLESTONE, 8, -3, 5),
        R(9, -1, 1, 9, -1, 5),
        A(8, -3, 8, 10, -1, 10),
        P(CHISELED_STONE_BRICKS, 8, -2, 11),
        P(CHISELED_STONE_BRICKS, 9, -2, 11),
        P(CHISELED_STONE_BRICKS, 10, -2, 11),
        P(LEVER_FACING_NORTH_FACE_WALL, 8, -2, 12),
        P(LEVER_FACING_NORTH_FACE_WALL, 9, -2, 12),
        P(LEVER_FACING_NORTH_FACE_WALL, 10, -2, 12),
        R(8, -3, 8, 8, -3, 10),
        R(10, -3, 8, 10, -3, 10),
        P(MOSSY_COBBLESTONE, 10, -2, 9),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 8, -2, 9),
        P(REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE, 8, -2, 10),
        P(
            REDSTONE_WIRE_NORTH_SIDE_SOUTH_SIDE_EAST_SIDE_WEST_SIDE,
            10,
            -1,
            9,
        ),
        P(STICKY_PISTON_FACING_UP, 9, -2, 8),
        P(STICKY_PISTON_FACING_WEST, 10, -2, 8),
        P(STICKY_PISTON_FACING_WEST, 10, -1, 8),
        P(REPEATER_FACING_NORTH, 10, -2, 10),
    ];
}
mod hut {
    use super::Op::{self, *};

    pub const SPRUCE_PLANKS: usize = 0;
    pub const OAK_LOG: usize = 1;
    pub const OAK_FENCE: usize = 2;
    pub const AIR: usize = 3;
    pub const POTTED_RED_MUSHROOM: usize = 4;
    pub const CRAFTING_TABLE: usize = 5;
    pub const CAULDRON: usize = 6;
    pub const SPRUCE_STAIRS_FACING_NORTH: usize = 7;
    pub const SPRUCE_STAIRS_FACING_EAST: usize = 8;
    pub const SPRUCE_STAIRS_FACING_WEST: usize = 9;
    pub const SPRUCE_STAIRS_FACING_SOUTH: usize = 10;
    pub const SPRUCE_STAIRS_FACING_NORTH_SHAPE_OUTER_RIGHT: usize = 11;
    pub const SPRUCE_STAIRS_FACING_NORTH_SHAPE_OUTER_LEFT: usize = 12;
    pub const SPRUCE_STAIRS_FACING_SOUTH_SHAPE_OUTER_LEFT: usize = 13;
    pub const SPRUCE_STAIRS_FACING_SOUTH_SHAPE_OUTER_RIGHT: usize = 14;
    pub const PALETTE: &[&str] = &[
        "spruce_planks",
        "oak_log",
        "oak_fence",
        "air",
        "potted_red_mushroom",
        "crafting_table",
        "cauldron",
        "spruce_stairs[facing=north]",
        "spruce_stairs[facing=east]",
        "spruce_stairs[facing=west]",
        "spruce_stairs[facing=south]",
        "spruce_stairs[facing=north,shape=outer_right]",
        "spruce_stairs[facing=north,shape=outer_left]",
        "spruce_stairs[facing=south,shape=outer_left]",
        "spruce_stairs[facing=south,shape=outer_right]",
    ];
    pub const HUT_1: &[Op] = &[
        B(1, 1, 1, 5, 1, 7, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(1, 4, 2, 5, 4, 7, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(2, 1, 0, 4, 1, 0, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(2, 2, 2, 3, 3, 2, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(1, 2, 3, 1, 3, 6, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(5, 2, 3, 5, 3, 6, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(2, 2, 7, 4, 3, 7, SPRUCE_PLANKS, SPRUCE_PLANKS),
        B(1, 0, 2, 1, 3, 2, OAK_LOG, OAK_LOG),
        B(5, 0, 2, 5, 3, 2, OAK_LOG, OAK_LOG),
        B(1, 0, 7, 1, 3, 7, OAK_LOG, OAK_LOG),
        B(5, 0, 7, 5, 3, 7, OAK_LOG, OAK_LOG),
        P(OAK_FENCE, 2, 3, 2),
        P(OAK_FENCE, 3, 3, 7),
        P(AIR, 1, 3, 4),
        P(AIR, 5, 3, 4),
        P(AIR, 5, 3, 5),
        P(POTTED_RED_MUSHROOM, 1, 3, 5),
        P(CRAFTING_TABLE, 3, 2, 6),
        P(CAULDRON, 4, 2, 6),
        P(OAK_FENCE, 1, 2, 1),
        P(OAK_FENCE, 5, 2, 1),
        B(
            0,
            4,
            1,
            6,
            4,
            1,
            SPRUCE_STAIRS_FACING_NORTH,
            SPRUCE_STAIRS_FACING_NORTH,
        ),
        B(
            0,
            4,
            2,
            0,
            4,
            7,
            SPRUCE_STAIRS_FACING_EAST,
            SPRUCE_STAIRS_FACING_EAST,
        ),
        B(
            6,
            4,
            2,
            6,
            4,
            7,
            SPRUCE_STAIRS_FACING_WEST,
            SPRUCE_STAIRS_FACING_WEST,
        ),
        B(
            0,
            4,
            8,
            6,
            4,
            8,
            SPRUCE_STAIRS_FACING_SOUTH,
            SPRUCE_STAIRS_FACING_SOUTH,
        ),
        P(SPRUCE_STAIRS_FACING_NORTH_SHAPE_OUTER_RIGHT, 0, 4, 1),
        P(SPRUCE_STAIRS_FACING_NORTH_SHAPE_OUTER_LEFT, 6, 4, 1),
        P(SPRUCE_STAIRS_FACING_SOUTH_SHAPE_OUTER_LEFT, 0, 4, 8),
        P(SPRUCE_STAIRS_FACING_SOUTH_SHAPE_OUTER_RIGHT, 6, 4, 8),
        F(OAK_LOG, 1, -1, 2),
        F(OAK_LOG, 5, -1, 2),
        F(OAK_LOG, 1, -1, 7),
        F(OAK_LOG, 5, -1, 7),
    ];
}
