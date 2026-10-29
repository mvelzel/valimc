//! A tick-local grid of sensed mob boxes (`Valimc.AI.Spatial`): 8-block
//! columns over x and z holding the section-order indexes of the mobs whose
//! box reaches them. A query's candidates come back in section order, so a
//! filtered query equals the linear scan; wide queries (more than 128
//! columns) scan linearly instead. Sections with fewer than 32 mobs keep no
//! grid.

use crate::physics::Aabb;
use std::collections::HashMap;

/// Mob count from which a section keeps a grid.
pub const THRESHOLD: usize = 32;
/// Columns past which a query scans every mob.
const WIDE: i64 = 128;

#[derive(Debug, Default, Clone)]
pub struct Grid {
    cells: HashMap<(i32, i32), Vec<u32>>,
    /// Per mob the columns it is in (`members`).
    members: Vec<(i32, i32, i32, i32)>,
}

fn bounds(b: &Aabb) -> (i32, i32, i32, i32) {
    let column = |v: f64| (v.floor() as i32).div_euclid(8);
    (
        column(b.min[0]),
        column(b.min[2]),
        column(b.max[0]),
        column(b.max[2]),
    )
}

impl Grid {
    /// The grid of `boxes` (in section order).
    pub fn new(boxes: impl ExactSizeIterator<Item = Aabb>) -> Grid {
        let mut grid = Grid {
            cells: HashMap::new(),
            members: Vec::with_capacity(boxes.len()),
        };
        for (i, b) in boxes.enumerate() {
            let r = bounds(&b);
            grid.members.push(r);
            grid.add(i as u32, r);
        }
        grid
    }

    fn add(&mut self, id: u32, (a, b, c, d): (i32, i32, i32, i32)) {
        for x in a..=c {
            for z in b..=d {
                self.cells.entry((x, z)).or_default().push(id);
            }
        }
    }

    fn remove(&mut self, id: u32, (a, b, c, d): (i32, i32, i32, i32)) {
        for x in a..=c {
            for z in b..=d {
                if let Some(ids) = self.cells.get_mut(&(x, z)) {
                    ids.retain(|&i| i != id);
                    if ids.is_empty() {
                        self.cells.remove(&(x, z));
                    }
                }
            }
        }
    }

    /// Mob `i` sensed again with box `b` (`Spatial.put/2`).
    pub fn put(&mut self, i: usize, b: &Aabb) {
        let r = bounds(b);
        let old = self.members[i];
        if r != old {
            self.remove(i as u32, old);
            self.add(i as u32, r);
            self.members[i] = r;
        }
    }

    /// The mobs whose columns a query box reaches, in section order; None
    /// for a wide query (every mob).
    pub fn candidates(&self, b: &Aabb) -> Option<Vec<usize>> {
        let (a, bz, c, d) = bounds(b);
        if (c as i64 - a as i64 + 1) * (d as i64 - bz as i64 + 1) > WIDE {
            return None;
        }
        let mut out = Vec::new();
        for x in a..=c {
            for z in bz..=d {
                if let Some(ids) = self.cells.get(&(x, z)) {
                    out.extend(ids.iter().map(|&i| i as usize));
                }
            }
        }
        out.sort_unstable();
        out.dedup();
        Some(out)
    }
}
