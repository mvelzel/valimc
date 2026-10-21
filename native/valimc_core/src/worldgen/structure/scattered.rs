//! Single-piece structures: desert and jungle temples (`SinglePieceStructure`),
//! swamp huts and buried treasure.

use super::super::blocks::Heightmap;
use super::piece::{make_bounding_box, BoundingBox, Direction, Piece, PieceKind, ScatteredKind};
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
fn on_top_of_chunk_center(gc: &mut GenContext, heightmap: Heightmap) -> Result<bool, String> {
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
