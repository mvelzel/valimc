//! Voxel collision shapes (vanilla's `VoxelShape`): a grid of cells between
//! per-axis coordinates, some filled. Shapes are block-local; a shape placed
//! in the world adds the block's offset and position to each coordinate when
//! it is read, as vanilla's offset coordinate lists do, so no placed copy is
//! ever built.

use super::aabb::Aabb;

/// Vanilla's `Shapes.EPSILON` and the collision epsilon.
pub const EPSILON: f64 = 1.0e-7;

/// Where a block-local shape is placed: its block's own offset, then the
/// block position, each added to every coordinate in that order (vanilla's
/// nested offset coordinate lists); an unmoved shape keeps its coordinates
/// exactly (negative zero included).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Place {
    pub offset: Option<[f64; 3]>,
    pub position: Option<[f64; 3]>,
}

impl Place {
    pub const ORIGIN: Place = Place {
        offset: None,
        position: None,
    };

    pub fn at(position: [f64; 3]) -> Place {
        Place {
            offset: None,
            position: Some(position),
        }
    }

    #[inline]
    pub fn coord(&self, axis: usize, local: f64) -> f64 {
        let v = match self.offset {
            Some(o) => local + o[axis],
            None => local,
        };
        match self.position {
            Some(p) => v + p[axis],
            None => v,
        }
    }
}

/// A discrete grid shape. Cell `(x, y, z)` is bit `(x * ny + y) * nz + z`.
#[derive(Clone, Debug, PartialEq)]
pub struct VoxelShape {
    pub axes: [Vec<f64>; 3],
    pub sizes: [usize; 3],
    pub bits: Vec<u64>,
    /// Vanilla's `Shapes.block()` itself: block collisions test it as a box.
    pub full_block: bool,
}

impl VoxelShape {
    pub fn empty() -> VoxelShape {
        VoxelShape {
            axes: [vec![0.0], vec![0.0], vec![0.0]],
            sizes: [0, 0, 0],
            bits: Vec::new(),
            full_block: false,
        }
    }

    pub fn block() -> VoxelShape {
        let mut shape = VoxelShape::from_box([0.0; 3], [1.0; 3]);
        shape.full_block = true;
        shape
    }

    /// One filled cell spanning the box exactly (vanilla's array shape).
    pub fn from_box(min: [f64; 3], max: [f64; 3]) -> VoxelShape {
        VoxelShape {
            axes: [
                vec![min[0], max[0]],
                vec![min[1], max[1]],
                vec![min[2], max[2]],
            ],
            sizes: [1, 1, 1],
            bits: vec![1],
            full_block: false,
        }
    }

    /// A grid from its parts; `None` when they disagree.
    pub fn new(axes: [Vec<f64>; 3], sizes: [usize; 3], filled: &[bool]) -> Option<VoxelShape> {
        let cells = sizes[0] * sizes[1] * sizes[2];
        if filled.len() != cells || (0..3).any(|a| axes[a].len() != sizes[a] + 1) {
            return None;
        }
        // Strictly increasing (NaN fails too).
        if (0..3).any(|a| {
            axes[a]
                .windows(2)
                .any(|w| w[0].partial_cmp(&w[1]) != Some(std::cmp::Ordering::Less))
        }) {
            return None;
        }
        if cells > 0 && !filled.iter().any(|&f| f) {
            return None;
        }
        let mut bits = vec![0u64; cells.div_ceil(64)];
        for (i, _) in filled.iter().enumerate().filter(|(_, &f)| f) {
            bits[i / 64] |= 1 << (i % 64);
        }
        Some(VoxelShape {
            axes,
            sizes,
            bits,
            full_block: false,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.sizes[0] * self.sizes[1] * self.sizes[2] == 0
    }

    /// Whether cell `(x, y, z)` is filled; outside the grid it is not.
    pub fn full(&self, x: isize, y: isize, z: isize) -> bool {
        let [nx, ny, nz] = self.sizes;
        if x < 0 || y < 0 || z < 0 || x as usize >= nx || y as usize >= ny || z as usize >= nz {
            return false;
        }
        let i = (x as usize * ny + y as usize) * nz + z as usize;
        self.bits[i / 64] >> (i % 64) & 1 == 1
    }

    fn full_at(&self, cell: [isize; 3]) -> bool {
        self.full(cell[0], cell[1], cell[2])
    }

    /// The number of coordinates `<= value` minus one: `-1` below the grid,
    /// `size` above it (vanilla's `findIndex`).
    fn find_index(coords: &[f64], place: &Place, axis: usize, value: f64) -> isize {
        let (mut low, mut high) = (0usize, coords.len());
        while low < high {
            let mid = (low + high) / 2;
            if value < place.coord(axis, coords[mid]) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        low as isize - 1
    }

    /// `VoxelShape.collide` of this shape placed at `place`: how far `body`
    /// may move `delta` along `axis` before entering a filled cell.
    pub fn collide(&self, place: &Place, axis: usize, body: &Aabb, delta: f64) -> f64 {
        if self.is_empty() {
            return delta;
        }
        if delta.abs() < EPSILON {
            return 0.0;
        }
        let (a, b) = match axis {
            0 => (1, 2),
            1 => (0, 2),
            _ => (0, 1),
        };
        let coords = |i: usize| &self.axes[i];
        let range = |i: usize| {
            let from = Self::find_index(coords(i), place, i, body.min[i] + EPSILON).max(0);
            let to = (Self::find_index(coords(i), place, i, body.max[i] - EPSILON) + 1)
                .min(self.sizes[i] as isize);
            (from, to)
        };
        let (a_range, b_range) = (range(a), range(b));
        if a_range.0 >= a_range.1 || b_range.0 >= b_range.1 {
            return delta;
        }
        let size = self.sizes[axis] as isize;
        let occupied = |index: isize| {
            (a_range.0..a_range.1).any(|ai| {
                (b_range.0..b_range.1).any(|bi| {
                    let mut cell = [0isize; 3];
                    cell[axis] = index;
                    cell[a] = ai;
                    cell[b] = bi;
                    self.full_at(cell)
                })
            })
        };
        if delta > 0.0 {
            let start = Self::find_index(coords(axis), place, axis, body.max[axis] - EPSILON) + 1;
            for index in start.max(0)..size {
                if occupied(index) {
                    let gap = place.coord(axis, coords(axis)[index as usize]) - body.max[axis];
                    return if gap >= -EPSILON {
                        delta.min(gap)
                    } else {
                        delta
                    };
                }
            }
        } else {
            let start = Self::find_index(coords(axis), place, axis, body.min[axis] + EPSILON) - 1;
            let mut index = start.min(size - 1);
            while index >= 0 {
                if occupied(index) {
                    let gap = place.coord(axis, coords(axis)[index as usize + 1]) - body.min[axis];
                    return if gap <= EPSILON {
                        delta.max(gap)
                    } else {
                        delta
                    };
                }
                index -= 1;
            }
        }
        delta
    }

    /// Whether this shape at `place` and `other` at `other_place` share a
    /// filled cell once their coordinates are merged within the epsilon
    /// (vanilla's `Shapes.joinIsNotEmpty` with `AND`).
    pub fn intersects(&self, place: &Place, other: &VoxelShape, other_place: &Place) -> bool {
        if self.is_empty() || other.is_empty() {
            return false;
        }
        let maps: [Vec<(isize, isize)>; 3] = std::array::from_fn(|a| {
            let (x, y) = (&self.axes[a], &other.axes[a]);
            let identical = x.len() == y.len()
                && x.iter()
                    .zip(y)
                    .all(|(&u, &v)| place.coord(a, u) == other_place.coord(a, v));
            if identical {
                // Vanilla's `IdenticalMerger`: every coordinate, no collapse.
                (0..x.len() as isize).map(|i| (i, i)).collect()
            } else {
                merge_intersection(x, place, y, other_place, a)
            }
        });
        let cells = |a: usize| maps[a].len().saturating_sub(1);
        for x in 0..cells(0) {
            for y in 0..cells(1) {
                for z in 0..cells(2) {
                    let (lx, rx) = maps[0][x];
                    let (ly, ry) = maps[1][y];
                    let (lz, rz) = maps[2][z];
                    if self.full(lx, ly, lz) && other.full(rx, ry, rz) {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// One block-local box per filled cell.
    pub fn cells(&self) -> Vec<Aabb> {
        let [nx, ny, nz] = self.sizes;
        let mut out = Vec::new();
        for x in 0..nx {
            for y in 0..ny {
                for z in 0..nz {
                    if self.full(x as isize, y as isize, z as isize) {
                        out.push(Aabb {
                            min: [self.axes[0][x], self.axes[1][y], self.axes[2][z]],
                            max: [
                                self.axes[0][x + 1],
                                self.axes[1][y + 1],
                                self.axes[2][z + 1],
                            ],
                        });
                    }
                }
            }
        }
        out
    }

    /// The box covering the filled cells, block-local (vanilla's `bounds`).
    pub fn bounds(&self) -> Option<Aabb> {
        if self.is_empty() {
            return None;
        }
        let [nx, ny, nz] = self.sizes;
        let mut lo = [usize::MAX; 3];
        let mut hi = [0usize; 3];
        for x in 0..nx {
            for y in 0..ny {
                for z in 0..nz {
                    if self.full(x as isize, y as isize, z as isize) {
                        for (a, v) in [x, y, z].into_iter().enumerate() {
                            lo[a] = lo[a].min(v);
                            hi[a] = hi[a].max(v + 1);
                        }
                    }
                }
            }
        }
        Some(Aabb {
            min: std::array::from_fn(|a| self.axes[a][lo[a]]),
            max: std::array::from_fn(|a| self.axes[a][hi[a]]),
        })
    }
}

/// Vanilla's `IndirectMerger` for an `AND` join: the merged coordinates of two
/// lists (values within the epsilon collapse, the first kept), each with the
/// cell index it stands for in either list (`-1` before a list starts). Points
/// of one list outside the other's span are skipped.
fn merge_intersection(
    a: &[f64],
    a_place: &Place,
    b: &[f64],
    b_place: &Place,
    axis: usize,
) -> Vec<(isize, isize)> {
    let va = |i: usize| a_place.coord(axis, a[i]);
    let vb = |i: usize| b_place.coord(axis, b[i]);
    let mut out: Vec<(f64, isize, isize)> = Vec::with_capacity(a.len() + b.len());
    let (mut ia, mut ib) = (0usize, 0usize);
    loop {
        let out_a = ia >= a.len();
        let out_b = ib >= b.len();
        if out_a && out_b {
            break;
        }
        let choose_a = !out_a && (out_b || va(ia) < vb(ib) + EPSILON);
        let value = if choose_a {
            ia += 1;
            if ib == 0 || out_b {
                continue;
            }
            va(ia - 1)
        } else {
            ib += 1;
            if ia == 0 || out_a {
                continue;
            }
            vb(ib - 1)
        };
        let (ca, cb) = (ia as isize - 1, ib as isize - 1);
        match out.last_mut() {
            Some(last) if last.0 >= value - EPSILON => {
                last.1 = ca;
                last.2 = cb;
            }
            _ => out.push((value, ca, cb)),
        }
    }
    out.into_iter().map(|(_, ca, cb)| (ca, cb)).collect()
}

/// Vanilla's `Shapes.create` of a world box: an empty shape when an axis is
/// thinner than the epsilon, a discrete grid when every axis lies on a
/// 1/2^k grid within the unit cube, otherwise one exact cell.
pub fn box_shape(b: &Aabb) -> VoxelShape {
    if (0..3).any(|a| b.max[a] - b.min[a] < EPSILON) {
        return VoxelShape::empty();
    }
    let bits: [Option<u32>; 3] = std::array::from_fn(|a| find_bits(b.min[a], b.max[a]));
    if bits.iter().any(Option::is_none) {
        return VoxelShape::from_box(b.min, b.max);
    }
    let bits = bits.map(Option::unwrap);
    if bits == [0, 0, 0] {
        return VoxelShape::block();
    }
    let sizes = bits.map(|k| 1usize << k);
    let axes: [Vec<f64>; 3] =
        std::array::from_fn(|a| (0..=sizes[a]).map(|i| i as f64 / sizes[a] as f64).collect());
    let spans: [(i64, i64); 3] = std::array::from_fn(|a| {
        let n = sizes[a] as f64;
        (
            (b.min[a] * n + 0.5).floor() as i64,
            (b.max[a] * n + 0.5).floor() as i64,
        )
    });
    let mut filled = vec![false; sizes[0] * sizes[1] * sizes[2]];
    for x in 0..sizes[0] {
        for y in 0..sizes[1] {
            for z in 0..sizes[2] {
                let inside =
                    |a: usize, v: usize| (v as i64) >= spans[a].0 && (v as i64) < spans[a].1;
                if inside(0, x) && inside(1, y) && inside(2, z) {
                    filled[(x * sizes[1] + y) * sizes[2] + z] = true;
                }
            }
        }
    }
    VoxelShape::new(axes, sizes, &filled).unwrap_or_else(VoxelShape::empty)
}

/// `Shapes.findBits`: the smallest k <= 3 with both ends on a 1/2^k grid.
fn find_bits(min: f64, max: f64) -> Option<u32> {
    if min < -EPSILON || max > 1.0 + EPSILON {
        return None;
    }
    (0..=3).find(|&k| {
        let n = (1u32 << k) as f64;
        let on = |v: f64| (v * n - (v * n + 0.5).floor()).abs() < EPSILON * n;
        on(min) && on(max)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slab() -> VoxelShape {
        VoxelShape::from_box([0.0, 0.0, 0.0], [1.0, 0.5, 1.0])
    }

    #[test]
    fn collide_stops_at_faces() {
        let body = Aabb::new([0.2, 1.0, 0.2], [0.8, 2.8, 0.8]);
        let s = slab();
        assert_eq!(s.collide(&Place::ORIGIN, 1, &body, -2.0), -0.5);
        assert_eq!(s.collide(&Place::ORIGIN, 1, &body, 2.0), 2.0);
        let beside = Aabb::new([1.0, 0.0, 0.2], [1.6, 1.8, 0.8]);
        assert_eq!(s.collide(&Place::ORIGIN, 0, &beside, -1.0), 0.0);
        assert_eq!(
            s.collide(&Place::at([5.0, 0.0, 0.0]), 0, &beside, 9.0),
            5.0 - 1.6
        );
    }

    #[test]
    fn touching_shapes_do_not_intersect() {
        let s = VoxelShape::block();
        let above = box_shape(&Aabb::new([0.2, 1.0, 0.2], [0.8, 2.8, 0.8]));
        assert!(!s.intersects(&Place::ORIGIN, &above, &Place::ORIGIN));
        let inside = box_shape(&Aabb::new([0.2, 0.9, 0.2], [0.8, 2.8, 0.8]));
        assert!(s.intersects(&Place::ORIGIN, &inside, &Place::ORIGIN));
        let near = box_shape(&Aabb::new([0.2, 1.0 - 5.0e-8, 0.2], [0.8, 2.8, 0.8]));
        assert!(!s.intersects(&Place::ORIGIN, &near, &Place::ORIGIN));
    }

    #[test]
    fn unit_boxes_snap_to_grids() {
        assert_eq!(
            box_shape(&Aabb::new([0.0; 3], [1.0; 3])),
            VoxelShape::block()
        );
        let half = box_shape(&Aabb::new([0.0; 3], [1.0, 0.5, 1.0]));
        assert_eq!(half.sizes, [1, 2, 1]);
        assert!(box_shape(&Aabb::new([0.0; 3], [1.0, 1.0e-8, 1.0])).is_empty());
        assert_eq!(box_shape(&Aabb::new([0.1; 3], [1.0; 3])).sizes, [1, 1, 1]);
    }
}
