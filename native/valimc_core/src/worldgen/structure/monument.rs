//! Ocean monuments (VMC-025e5, `OceanMonumentStructure`): every biome within
//! 29 blocks of the chunk's (9, sea level, 9) must be an ocean or river, then
//! the building at y 39 facing a random direction. A start saves only the
//! building; vanilla rebuilds its rooms from the seed when it loads one, and
//! placing them is VMC-025f.

use super::super::blocks::Heightmap;
use super::piece::{make_bounding_box, Direction, Piece, PieceKind};
use super::scattered::on_top_of_chunk_center;
use super::{BiomeSet, GenContext};

pub fn generate(gc: &mut GenContext, surrounding: &BiomeSet) -> Result<Option<Vec<Piece>>, String> {
    let (x, z) = (gc.min_block_x() + 9, gc.min_block_z() + 9);
    let y = gc.sea_level();
    // `BiomeResolver.getBiomesWithin`: every quart of the box.
    for qz in (z - 29) >> 2..=(z + 29) >> 2 {
        for qx in (x - 29) >> 2..=(x + 29) >> 2 {
            for qy in (y - 29) >> 2..=(y + 29) >> 2 {
                if !surrounding.contains(gc.env.biomes.point(gc.ctx, qx, qy, qz)) {
                    return Ok(None);
                }
            }
        }
    }
    if !on_top_of_chunk_center(gc, Heightmap::OceanFloorWg)? {
        return Ok(None);
    }
    let direction = Direction::random(&mut gc.random);
    let (west, north) = (gc.min_block_x() - 29, gc.min_block_z() - 29);
    Ok(Some(vec![Piece {
        kind: PieceKind::Monument,
        bbox: make_bounding_box(west, 39, north, direction, 58, 23, 58),
        orientation: Some(direction),
        gen_depth: 0,
    }]))
}
