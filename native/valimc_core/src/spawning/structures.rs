//! Structure spawn overrides (VMC-042b): `NaturalSpawner.mobsAt` over the
//! starts a chunk references (kept with the chunk since its generation).
//! On nether bricks inside a fortress's box a monster is one of the
//! fortress's enemies; inside a start whose structure overrides the
//! category (any piece, or the start's whole box) its spawners replace the
//! biome's.

use super::facts::{Category, Spawner};
use super::rules::World;
use std::collections::HashMap;

/// A start a chunk references, of a structure that overrides spawns: the
/// structure (its index in the facts), the start's box and the boxes of its
/// pieces in the chunk, `[min x, min y, min z, max x, max y, max z]`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Area {
    pub structure: u16,
    pub bbox: [i32; 6],
    pub pieces: Vec<[i32; 6]>,
}

/// The kept starts by chunk.
pub type Areas = HashMap<(i32, i32), Vec<Area>>;

/// Where the kept starts of a chunk are read from: one map, or a group's
/// sections' (VMC-081g2).
pub trait Kept {
    fn kept(&self, chunk: (i32, i32)) -> &[Area];
}

impl Kept for Areas {
    fn kept(&self, chunk: (i32, i32)) -> &[Area] {
        self.get(&chunk).map_or(&[], Vec::as_slice)
    }
}

fn inside(b: &[i32; 6], p: [i32; 3]) -> bool {
    (b[0]..=b[3]).contains(&p[0]) && (b[1]..=b[4]).contains(&p[1]) && (b[2]..=b[5]).contains(&p[2])
}

/// The weighted spawners at `pos` when a structure there overrides
/// `category`, with their total weight; None for the biome's.
pub fn mobs_at<'w>(
    world: &'w World,
    areas: &dyn Kept,
    category: Category,
    pos: [i32; 3],
) -> Option<(&'w [Spawner], i32)> {
    let areas = areas.kept((pos[0] >> 4, pos[2] >> 4));
    if areas.is_empty() {
        return None;
    }
    let facts = world.facts;
    let category_index = category.index();
    // `isInNetherFortressBounds`: on nether bricks, inside a fortress's box.
    if category == Category::Monster {
        if let Some(fortress) = facts.fortress {
            let below = world.state([pos[0], pos[1] - 1, pos[2]]);
            if facts.has(below, facts.named.nether_bricks)
                && areas
                    .iter()
                    .any(|a| a.structure == fortress && inside(&a.bbox, pos))
            {
                let o = facts.structures[fortress as usize][category_index].as_ref()?;
                return Some((&o.spawns, o.total));
            }
        }
    }
    // `ChunkGenerator.getMobsAt`.
    for area in areas {
        let Some(o) = facts.structures[area.structure as usize][category_index].as_ref() else {
            continue;
        };
        let hit = if o.piece {
            area.pieces.iter().any(|b| inside(b, pos))
        } else {
            inside(&area.bbox, pos)
        };
        if hit {
            return Some((&o.spawns, o.total));
        }
    }
    None
}
