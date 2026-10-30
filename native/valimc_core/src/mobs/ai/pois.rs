//! Points of interest as mobs read them (`Valimc.AI.Pois`, vanilla's
//! `PoiManager` read from the blocks): a block of one of a POI type's
//! states is that POI; its taken tickets are the level's claims
//! (`Level::pois`, the living villagers' memories over the group's
//! sections; `claims` and `store_claims` count them). What brain mobs read
//! and do: the POIs of some types around a block (`in_range`, `closest`),
//! a ticket taken or given back (`take`, `release`: the level counts it at
//! once for the mobs after); what an iron golem reads: whether a place is a
//! village (`sectionsToVillage`, the chessboard distance in sections to one
//! holding an occupied village POI), the section nearer one, and the
//! occupied POIs around a block.

use super::brain::{Brain, Mem, MemValue};
use crate::mobs::facts::families::PoiType;
use crate::mobs::level::Level;
use crate::mobs::term::Atom;
use std::collections::HashMap;

/// `PoiTypes.forState`: the POI type of block `state`.
fn of_state<'a>(level: &Level<'a>, state: u16) -> Option<&'a PoiType> {
    let facts = &level.facts.village;
    facts.poi_types.get(facts.poi_of_state(state)?)
}

/// `PoiRecord.isOccupied` of the POI of `ty` at `pos`.
fn occupied(level: &Level, ty: &PoiType, pos: [i32; 3]) -> bool {
    ty.max_tickets > 0 && level.pois.get(&pos).copied().unwrap_or(0) > 0
}

/// The 16-block section of a block.
pub fn section([x, y, z]: [i32; 3]) -> [i32; 3] {
    [x.div_euclid(16), y.div_euclid(16), z.div_euclid(16)]
}

/// `village_sections/1`: the sections holding an occupied village POI, from
/// the claims and blocks.
fn village_sections(level: &Level) -> Vec<[i32; 3]> {
    let mut out: Vec<[i32; 3]> = level
        .pois
        .iter()
        .filter(|&(_, &n)| n > 0)
        .filter_map(|(pos, _)| {
            let ty = of_state(level, level.block(*pos)?)?;
            (ty.tags.iter().any(|t| t == "minecraft:village") && ty.max_tickets > 0)
                .then(|| section(*pos))
        })
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// `sectionsToVillage` of a section: at most 7 (none nearer).
pub fn sections_to_village(level: &Level, [sx, sy, sz]: [i32; 3]) -> i32 {
    let computed;
    let villages = match &level.villages {
        Some(v) => v,
        None => {
            computed = village_sections(level);
            &computed
        }
    };
    villages
        .iter()
        .map(|&[vx, vy, vz]| (vx - sx).abs().max((vy - sy).abs()).max((vz - sz).abs()))
        .fold(7, i32::min)
        .min(7)
}

/// `SectionPos.cube(center, radius)` in its order: x, then y, then z
/// innermost-first as the Elixir's comprehension (z outermost).
pub fn cube([cx, cy, cz]: [i32; 3], radius: i32) -> Vec<[i32; 3]> {
    let mut out = Vec::new();
    for z in cz - radius..=cz + radius {
        for y in cy - radius..=cy + radius {
            for x in cx - radius..=cx + radius {
                out.push([x, y, z]);
            }
        }
    }
    out
}

/// `BehaviorUtils.findSectionClosestToVillage`: of the cube of sections
/// `radius` around `center`, the first nearest to a village of those
/// nearer than `center`, else `center`.
pub fn closest_village_section(level: &Level, center: [i32; 3], radius: i32) -> [i32; 3] {
    let here = sections_to_village(level, center);
    let mut best: Option<([i32; 3], i32)> = None;
    for s in cube(center, radius) {
        let d = sections_to_village(level, s);
        if d < here && best.is_none_or(|(_, b)| d < b) {
            best = Some((s, d));
        }
    }
    best.map_or(center, |(s, _)| s)
}

/// `ServerLevel.isVillage(pos)` (`isCloseToVillage(pos, 1)`).
pub fn village(level: &Level, pos: [i32; 3]) -> bool {
    sections_to_village(level, section(pos)) <= 1
}

/// `getInRange(every type, center, radius, :occupied)`: the occupied POIs
/// within `radius` of `center` (a square of chunks, then the square and
/// the sphere), in chunk and section order. An occupied POI is a claimed
/// block of a POI type, so the claims are what is searched.
pub fn occupied_in_range(level: &Level, center: [i32; 3], radius: i32) -> Vec<[i32; 3]> {
    let [cx, _, cz] = center;
    let chunks = radius.div_euclid(16) + 1;
    let (ccx, ccz) = (cx.div_euclid(16), cz.div_euclid(16));
    let mut found: Vec<[i32; 3]> = level
        .pois
        .keys()
        .copied()
        .filter(|&pos| {
            let (px, pz) = (pos[0].div_euclid(16), pos[2].div_euclid(16));
            (ccx - chunks..=ccx + chunks).contains(&px)
                && (ccz - chunks..=ccz + chunks).contains(&pz)
                && level
                    .block(pos)
                    .and_then(|s| of_state(level, s))
                    .is_some_and(|ty| occupied(level, ty, pos))
        })
        .collect();
    // `for x <- chunks, z <- chunks`, each chunk's blocks by section, y,
    // z, x.
    found.sort_by_key(|&[x, y, z]| {
        (
            x.div_euclid(16),
            z.div_euclid(16),
            y.div_euclid(16),
            y,
            z,
            x,
        )
    });
    found
        .into_iter()
        .filter(|&[px, py, pz]| {
            let (dx, dy, dz) = (px - cx, py - center[1], pz - cz);
            dx.abs() <= radius
                && dz.abs() <= radius
                && dx * dx + dy * dy + dz * dz <= radius * radius
        })
        .collect()
}

/// Which POIs a search takes (`PoiManager.Occupancy`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Occupancy {
    Any,
    HasSpace,
    Occupied,
}

/// The memories whose position claims a POI ticket (`POI_MEMORIES`).
pub const CLAIMING: [Mem; 4] = [
    Mem::Home,
    Mem::JobSite,
    Mem::PotentialJobSite,
    Mem::MeetingPoint,
];

/// The POI type at `pos` (`getType`).
pub fn type_at<'l>(level: &'l Level, pos: [i32; 3]) -> Option<&'l str> {
    level.facts.village.poi_of_state(level.block(pos)?)
}

fn max_tickets(level: &Level, ty: &str) -> i32 {
    level
        .facts
        .village
        .poi_types
        .get(ty)
        .map_or(0, |t| t.max_tickets)
}

/// A POI type's valid range.
pub fn valid_range(level: &Level, ty: &str) -> i32 {
    level
        .facts
        .village
        .poi_types
        .get(ty)
        .map_or(0, |t| t.valid_range)
}

/// `PoiRecord.hasSpace`.
pub fn space(level: &Level, ty: &str, pos: [i32; 3]) -> bool {
    level.pois.get(&pos).copied().unwrap_or(0) < max_tickets(level, ty)
}

/// `PoiRecord.isOccupied` of the POI of type `ty` (by name).
pub fn occupied_by(level: &Level, ty: &str, pos: [i32; 3]) -> bool {
    max_tickets(level, ty) > 0 && level.pois.get(&pos).copied().unwrap_or(0) > 0
}

/// The block states of POI types `names`.
pub fn states(level: &Level, names: &[&str]) -> Vec<u16> {
    let mut out: Vec<u16> = names
        .iter()
        .filter_map(|n| level.facts.village.poi_types.get(*n))
        .flat_map(|t| t.states.iter().copied())
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// `BlockPos.distSqr`.
pub fn dist_sq(a: [i32; 3], b: [i32; 3]) -> i64 {
    (0..3)
        .map(|i| {
            let d = (a[i] - b[i]) as i64;
            d * d
        })
        .sum()
}

/// `getInRange(types, center, radius, occupancy)`: the POIs of `types`
/// within `radius` of block `center` (a square of chunks, then the square
/// and the sphere), in chunk and section order, as `(type, pos)`.
pub fn in_range(
    level: &Level,
    types: &[&str],
    center: [i32; 3],
    radius: i32,
    occupancy: Occupancy,
) -> Vec<(String, [i32; 3])> {
    let states = states(level, types);
    let chunks = radius.div_euclid(16) + 1;
    let (ccx, ccz) = (center[0].div_euclid(16), center[2].div_euclid(16));
    let mut out = Vec::new();
    for x in ccx - chunks..=ccx + chunks {
        for z in ccz - chunks..=ccz + chunks {
            let (x0, z0) = (x * 16, z * 16);
            let mut found = level.find_blocks(
                [x0, level.min_y, z0],
                [x0 + 15, level.max_y, z0 + 15],
                &states,
            );
            found.sort_by_key(|([px, py, pz], _)| (py.div_euclid(16), *py, *pz, *px));
            for (pos, state) in found {
                if (pos[0] - center[0]).abs() > radius || (pos[2] - center[2]).abs() > radius {
                    continue;
                }
                if dist_sq(pos, center) > (radius as i64) * (radius as i64) {
                    continue;
                }
                let Some(ty) = level.facts.village.poi_of_state(state) else {
                    continue;
                };
                let fits = match occupancy {
                    Occupancy::Any => true,
                    Occupancy::HasSpace => space(level, ty, pos),
                    Occupancy::Occupied => occupied_by(level, ty, pos),
                };
                if fits {
                    out.push((ty.to_owned(), pos));
                }
            }
        }
    }
    out
}

/// `findAllClosestFirstWithType`: `in_range` sorted by distance to `center`
/// (stably).
pub fn closest_first(
    level: &Level,
    types: &[&str],
    center: [i32; 3],
    radius: i32,
    occupancy: Occupancy,
) -> Vec<(String, [i32; 3])> {
    let mut found = in_range(level, types, center, radius, occupancy);
    found.sort_by_key(|(_, p)| dist_sq(*p, center));
    found
}

/// `findClosest`.
pub fn closest(
    level: &Level,
    types: &[&str],
    center: [i32; 3],
    radius: i32,
    occupancy: Occupancy,
) -> Option<[i32; 3]> {
    closest_first(level, types, center, radius, occupancy)
        .first()
        .map(|(_, p)| *p)
}

/// `PoiManager.take` of the POI at `pos`: the level counts it at once.
pub fn take(level: &mut Level, pos: [i32; 3]) {
    *level.pois.entry(pos).or_insert(0) += 1;
}

/// `PoiManager.release` of the POI at `pos`.
pub fn release(level: &mut Level, pos: [i32; 3]) {
    if let Some(n) = level.pois.get_mut(&pos) {
        if *n > 1 {
            *n -= 1;
        } else {
            level.pois.remove(&pos);
        }
    }
}

/// The tickets a living villager's brain holds in `dimension`: each
/// claiming memory names a position (`Pois.claims/1`); added to `claims`.
pub fn claims(brain: &Brain, dimension: &Atom, claims: &mut HashMap<[i32; 3], i32>) {
    for m in CLAIMING {
        if let Some(MemValue::Global(g)) = brain.memories.get(m) {
            if &g.dimension == dimension {
                *claims.entry(g.pos).or_insert(0) += 1;
            }
        }
    }
}

/// `Pois.store_claims/2`: the tickets the living villagers of `mobs` hold
/// in `dimension`, from their brains (or what a record kept).
pub fn store_claims<'a>(
    facts: &crate::mobs::facts::MobFacts,
    mobs: impl IntoIterator<Item = &'a crate::mobs::model::NativeMob>,
    dimension: &Atom,
) -> HashMap<[i32; 3], i32> {
    let villager = facts.entities.id("minecraft:villager");
    let mut out = HashMap::new();
    for mob in mobs {
        let ty = facts.entities.id(&mob.body.entity_type);
        if ty.is_none() || ty != villager || !crate::mobs::living::mob::alive(&mob.body.mob) {
            continue;
        }
        let Some(mind) = &mob.body.mob.ai else {
            continue;
        };
        match mind.state.as_ref().and_then(|s| s.brain.as_deref()) {
            Some(brain) => claims(brain, dimension, &mut out),
            None => {
                if let Some(kept) = &mind.memories {
                    let memories = super::brain::restore_memories(kept);
                    for m in CLAIMING {
                        if let Some(g) = memories.global(m) {
                            if &g.dimension == dimension {
                                *out.entry(g.pos).or_insert(0) += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    out
}
