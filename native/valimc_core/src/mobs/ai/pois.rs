//! Points of interest as mobs read them (`Valimc.AI.Pois`, vanilla's
//! `PoiManager` read from the blocks): a block of one of a POI type's
//! states is that POI; its taken tickets are the level's claims
//! (`Level::pois`, the living villagers' memories over the group's
//! sections). What an iron golem reads: whether a place is a village
//! (`sectionsToVillage`, the chessboard distance in sections to one holding
//! an occupied village POI), the section nearer one, and the occupied POIs
//! around a block.

use crate::mobs::facts::families::PoiType;
use crate::mobs::level::Level;

/// `PoiTypes.forState`: the POI type of block `state`.
fn of_state<'a>(level: &Level<'a>, state: u16) -> Option<&'a PoiType> {
    level
        .facts
        .village
        .poi_types
        .values()
        .find(|t| t.states.contains(&state))
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
