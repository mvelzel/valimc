//! `/locate structure` (VMC-053o): vanilla's `ChunkGenerator.findNearestMapStructure`
//! without creating references. Concentric ring sets try their ring positions
//! from the nearest; random spread sets search square rings of grid cells
//! outwards and the first ring with a hit ends the search. A candidate chunk
//! has the structure when the placement's frequency allows it and the chunk's
//! own `createStructures` makes a start for it, which is what vanilla finds
//! when it loads the chunk to `STRUCTURE_STARTS`.

use super::placement::Placement;
use super::{Start, StructureEnv};
use std::collections::HashMap;

/// A found structure: its locate position and structure index.
pub type Located = ((i32, i32, i32), usize);

struct Search<'a> {
    env: &'a StructureEnv,
    starts: HashMap<(i32, i32), Vec<Start>>,
}

impl Search<'_> {
    /// `getStructureGeneratingAt`: the first wanted structure that starts in
    /// `chunk`, at the placement's locate position.
    fn generating_at(
        &mut self,
        structures: &[usize],
        set: usize,
        chunk: (i32, i32),
    ) -> Result<Option<Located>, String> {
        let placement = &self.env.registry.sets[set].placement;
        let common = placement.common();
        if !common.frequency_allows(self.env.seed, chunk.0, chunk.1) {
            return Ok(None);
        }
        let starts = match self.starts.get(&chunk) {
            Some(starts) => starts,
            None => {
                let (starts, _) = self.env.create_structures(chunk.0, chunk.1)?;
                self.starts.entry(chunk).or_insert(starts)
            }
        };
        for &structure in structures {
            if starts.iter().any(|start| start.structure == structure) {
                let [ox, oy, oz] = common.locate_offset;
                let pos = (
                    (chunk.0 << 4).wrapping_add(ox),
                    oy,
                    (chunk.1 << 4).wrapping_add(oz),
                );
                return Ok(Some((pos, structure)));
            }
        }
        Ok(None)
    }
}

fn dist_sqr(a: (i32, i32, i32), b: (i32, i32, i32)) -> f64 {
    let d = |p: i32, q: i32| p as f64 - q as f64;
    d(a.0, b.0) * d(a.0, b.0) + d(a.1, b.1) * d(a.1, b.1) + d(a.2, b.2) * d(a.2, b.2)
}

impl StructureEnv {
    /// The nearest of `wanted` (structure indices in holder set order) from
    /// block `pos`, searching random spread sets up to `max_radius` grid rings.
    pub fn find_nearest_structure(
        &self,
        wanted: &[usize],
        pos: (i32, i32, i32),
        max_radius: i32,
    ) -> Result<Option<Located>, String> {
        // `getPlacementsForStructure`: the possible sets holding the structure,
        // when one of the structure's own biomes can occur.
        let possible_biomes = self.biomes.possible();
        let mut scans: Vec<(usize, Vec<usize>)> = Vec::new();
        for &structure in wanted {
            let def = &self.registry.structures[structure];
            if !possible_biomes.iter().any(|&b| def.biomes.contains(b)) {
                continue;
            }
            for &set in &self.possible {
                if !self.registry.sets[set]
                    .structures
                    .iter()
                    .any(|&(s, _)| s == structure)
                {
                    continue;
                }
                match scans.iter_mut().find(|(s, _)| *s == set) {
                    Some((_, structures)) if !structures.contains(&structure) => {
                        structures.push(structure)
                    }
                    Some(_) => {}
                    None => scans.push((set, vec![structure])),
                }
            }
        }
        let mut search = Search {
            env: self,
            starts: HashMap::new(),
        };
        let mut nearest: Option<Located> = None;
        let mut nearest_dist = f64::MAX;
        let mut spread = Vec::new();
        for (set, structures) in &scans {
            match &self.registry.sets[*set].placement {
                Placement::ConcentricRings { .. } => {
                    let Some(positions) = self.ring_positions(*set) else {
                        return Err("ring positions for a set that cannot occur".into());
                    };
                    let mut closest: Option<Located> = None;
                    let mut closest_dist = f64::MAX;
                    for &(x, z) in positions {
                        let d = dist_sqr(((x << 4) + 8, 32, (z << 4) + 8), pos);
                        if closest.is_none() || d < closest_dist {
                            if let Some(found) = search.generating_at(structures, *set, (x, z))? {
                                closest = Some(found);
                                closest_dist = d;
                            }
                        }
                    }
                    if let Some(found) = closest {
                        let d = dist_sqr(pos, found.0);
                        if d < nearest_dist {
                            nearest_dist = d;
                            nearest = Some(found);
                        }
                    }
                }
                Placement::RandomSpread { spacing, .. } => {
                    spread.push((*set, structures, *spacing))
                }
            }
        }
        if spread.is_empty() {
            return Ok(nearest);
        }
        let (origin_x, origin_z) = (pos.0 >> 4, pos.2 >> 4);
        for radius in 0..=max_radius {
            let mut found_something = false;
            for &(set, structures, spacing) in &spread {
                let placement = &self.registry.sets[set].placement;
                let mut hit = None;
                'ring: for x in -radius..=radius {
                    let x_edge = x == -radius || x == radius;
                    for z in -radius..=radius {
                        if !(x_edge || z == -radius || z == radius) {
                            continue;
                        }
                        let sector_x = origin_x.wrapping_add(spacing.wrapping_mul(x));
                        let sector_z = origin_z.wrapping_add(spacing.wrapping_mul(z));
                        let chunk = placement
                            .potential_chunk(self.seed, sector_x, sector_z)
                            .expect("random spread placement");
                        if let Some(found) = search.generating_at(structures, set, chunk)? {
                            hit = Some(found);
                            break 'ring;
                        }
                    }
                }
                if let Some(found) = hit {
                    found_something = true;
                    let d = dist_sqr(pos, found.0);
                    if d < nearest_dist {
                        nearest_dist = d;
                        nearest = Some(found);
                    }
                }
            }
            if found_something {
                return Ok(nearest);
            }
        }
        Ok(nearest)
    }
}
