//! Vanilla's shape union (`Shapes.or`: `joinUnoptimized` with its index
//! mergers, then `optimize`), for the one dynamic shape built from others
//! at run time: a moving piston's (VMC-048b). Its coordinates are what
//! vanilla's are, bit for bit: a box made again by `Shapes.create` snaps to
//! a 1/2^k grid within the epsilon, and merging two coordinate lists keeps
//! the first of two values within it.

use super::aabb::Aabb;
use super::shape::{VoxelShape, EPSILON};

/// One axis's coordinates: a cube grid (`CubePointRange`, `i / parts`) or a
/// list.
#[derive(Clone, Debug)]
enum Coords {
    Cube(usize),
    List(Vec<f64>),
}

impl Coords {
    fn len(&self) -> usize {
        match self {
            Coords::Cube(parts) => parts + 1,
            Coords::List(values) => values.len(),
        }
    }

    fn get(&self, i: usize) -> f64 {
        match self {
            Coords::Cube(parts) => i as f64 / *parts as f64,
            Coords::List(values) => values[i],
        }
    }

    fn values(&self) -> Vec<f64> {
        (0..self.len()).map(|i| self.get(i)).collect()
    }
}

/// A shape on its grid: per axis its coordinates, its cells filled or not.
#[derive(Clone, Debug)]
pub struct Grid {
    coords: [Coords; 3],
    full: Vec<bool>,
    /// It is `Shapes.block()` itself.
    block: bool,
}

impl Grid {
    pub fn empty() -> Grid {
        Grid {
            coords: [
                Coords::List(vec![0.0]),
                Coords::List(vec![0.0]),
                Coords::List(vec![0.0]),
            ],
            full: Vec::new(),
            block: false,
        }
    }

    fn sizes(&self) -> [usize; 3] {
        std::array::from_fn(|a| self.coords[a].len() - 1)
    }

    pub fn is_empty(&self) -> bool {
        !self.full.iter().any(|&f| f)
    }

    fn full_wide(&self, x: isize, y: isize, z: isize) -> bool {
        let [nx, ny, nz] = self.sizes();
        if x < 0 || y < 0 || z < 0 || x as usize >= nx || y as usize >= ny || z as usize >= nz {
            return false;
        }
        self.full[(x as usize * ny + y as usize) * nz + z as usize]
    }

    /// A table shape moved by `offset` (`VoxelShape.move`: every coordinate
    /// list offset), or as it is.
    pub fn of(shape: &VoxelShape, offset: Option<[f64; 3]>) -> Grid {
        if shape.is_empty() {
            return Grid::empty();
        }
        let [nx, ny, nz] = shape.sizes;
        let mut full = vec![false; nx * ny * nz];
        for x in 0..nx {
            for y in 0..ny {
                for z in 0..nz {
                    full[(x * ny + y) * nz + z] = shape.full(x as isize, y as isize, z as isize);
                }
            }
        }
        Grid {
            coords: std::array::from_fn(|a| {
                Coords::List(match offset {
                    Some(o) => shape.axes[a].iter().map(|v| v + o[a]).collect(),
                    None => shape.axes[a].clone(),
                })
            }),
            full,
            block: false,
        }
    }

    /// `Shapes.create` of a block-local box.
    fn create(b: &Aabb) -> Grid {
        if (0..3).any(|a| b.max[a] - b.min[a] < EPSILON) {
            return Grid::empty();
        }
        let bits: [Option<u32>; 3] = std::array::from_fn(|a| find_bits(b.min[a], b.max[a]));
        if bits.iter().any(Option::is_none) {
            return Grid {
                coords: std::array::from_fn(|a| Coords::List(vec![b.min[a], b.max[a]])),
                full: vec![true],
                block: false,
            };
        }
        let bits = bits.map(Option::unwrap);
        let sizes = bits.map(|k| 1usize << k);
        let span: [(usize, usize); 3] = std::array::from_fn(|a| {
            let n = sizes[a] as f64;
            (java_round(b.min[a] * n), java_round(b.max[a] * n))
        });
        let mut full = vec![false; sizes[0] * sizes[1] * sizes[2]];
        for x in span[0].0..span[0].1 {
            for y in span[1].0..span[1].1 {
                for z in span[2].0..span[2].1 {
                    full[(x * sizes[1] + y) * sizes[2] + z] = true;
                }
            }
        }
        Grid {
            coords: sizes.map(Coords::Cube),
            full,
            block: bits == [0, 0, 0],
        }
    }

    /// `VoxelShape.optimize`: each merged box made again and joined.
    pub fn optimize(&self) -> Grid {
        let mut result = Grid::empty();
        for b in self.boxes() {
            result = join_or(&result, &Grid::create(&b));
        }
        result
    }

    /// `forAllBoxes` with neighbours merged: strips along z, grown along x,
    /// then y.
    fn boxes(&self) -> Vec<Aabb> {
        let [nx, ny, nz] = self.sizes();
        let mut full = self.full.clone();
        let at = |x: usize, y: usize, z: usize| (x * ny + y) * nz + z;
        let strip = |full: &[bool], z0: usize, z1: usize, x: usize, y: usize| {
            x < nx && y < ny && (z0..z1).all(|z| full[at(x, y, z)])
        };
        let mut out = Vec::new();
        for y in 0..ny {
            for x in 0..nx {
                let mut start: Option<usize> = None;
                for z in 0..=nz {
                    if z < nz && full[at(x, y, z)] {
                        start.get_or_insert(z);
                    } else if let Some(z0) = start.take() {
                        let (mut end_x, mut end_y) = (x, y);
                        for zz in z0..z {
                            full[at(x, y, zz)] = false;
                        }
                        while strip(&full, z0, z, end_x + 1, y) {
                            for zz in z0..z {
                                full[at(end_x + 1, y, zz)] = false;
                            }
                            end_x += 1;
                        }
                        while (x..=end_x).all(|cx| strip(&full, z0, z, cx, end_y + 1)) {
                            for cx in x..=end_x {
                                for zz in z0..z {
                                    full[at(cx, end_y + 1, zz)] = false;
                                }
                            }
                            end_y += 1;
                        }
                        let c = &self.coords;
                        out.push(Aabb {
                            min: [c[0].get(x), c[1].get(y), c[2].get(z0)],
                            max: [c[0].get(end_x + 1), c[1].get(end_y + 1), c[2].get(z)],
                        });
                    }
                }
            }
        }
        out
    }

    /// As the kernel's shape: `Shapes.block()` itself keeps its identity
    /// (block collisions test it as a box).
    pub fn shape(&self) -> VoxelShape {
        if self.is_empty() {
            return VoxelShape::empty();
        }
        if self.block {
            return VoxelShape::block();
        }
        VoxelShape::new(
            std::array::from_fn(|a| self.coords[a].values()),
            self.sizes(),
            &self.full,
        )
        .unwrap_or_else(VoxelShape::empty)
    }
}

/// `VoxelShape.toAabbs`: a shape's filled cells as merged boxes, in
/// vanilla's order.
pub fn boxes(shape: &VoxelShape) -> Vec<Aabb> {
    Grid::of(shape, None).boxes()
}

/// `Math.round` of a non-negative double, as an index.
fn java_round(v: f64) -> usize {
    (v + 0.5).floor().max(0.0) as usize
}

/// `Shapes.findBits`.
fn find_bits(min: f64, max: f64) -> Option<u32> {
    if min < -EPSILON || max > 1.0000001 {
        return None;
    }
    (0..=3).find(|&k| {
        let n = (1u32 << k) as f64;
        let on = |v: f64| (v * n - (v * n + 0.5).floor()).abs() < EPSILON * n;
        on(min) && on(max)
    })
}

/// An index merger's result: the merged coordinates and, per merged cell,
/// the cells of either list it stands for.
struct Merged {
    coords: Coords,
    cells: Vec<(isize, isize)>,
    cube: bool,
}

fn gcd(a: usize, b: usize) -> usize {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

/// `Shapes.createIndexMerger` for an `OR` join (both sides matter).
fn merger(cost: usize, first: &Coords, second: &Coords) -> Merged {
    let (fs, ss) = (first.len() - 1, second.len() - 1);
    if let (Coords::Cube(_), Coords::Cube(_)) = (first, second) {
        let g = gcd(fs, ss);
        let size = fs * (ss / g);
        if (cost * size) as u64 <= 256 {
            let (first_div, second_div) = (fs / g, ss / g);
            return Merged {
                coords: Coords::Cube(size),
                cells: (0..size)
                    .map(|i| ((i / second_div) as isize, (i / first_div) as isize))
                    .collect(),
                cube: true,
            };
        }
    }
    if first.get(fs) < second.get(0) - EPSILON {
        return non_overlapping(first, second, false);
    }
    if second.get(ss) < first.get(0) - EPSILON {
        return non_overlapping(second, first, true);
    }
    indirect(first, second)
}

/// `NonOverlappingMerger`: the lower list, then the upper one.
fn non_overlapping(lower: &Coords, upper: &Coords, swap: bool) -> Merged {
    let (ls, us) = (lower.len(), upper.len());
    let mut values = lower.values();
    values.extend(upper.values());
    let mut cells: Vec<(isize, isize)> = (0..ls).map(|i| (i as isize, -1)).collect();
    cells.extend((0..us - 1).map(|i| (ls as isize - 1, i as isize)));
    if swap {
        cells = cells.into_iter().map(|(a, b)| (b, a)).collect();
    }
    Merged {
        coords: Coords::List(values),
        cells,
        cube: false,
    }
}

/// `IndirectMerger` with both lists mattering (`IdenticalMerger` merges
/// equal lists alike).
fn indirect(first: &Coords, second: &Coords) -> Merged {
    let (fs, ss) = (first.len(), second.len());
    let mut values: Vec<f64> = Vec::with_capacity(fs + ss);
    let mut cells: Vec<(isize, isize)> = Vec::with_capacity(fs + ss);
    let (mut fi, mut si) = (0usize, 0usize);
    let mut last = f64::NAN;
    loop {
        let (out_first, out_second) = (fi >= fs, si >= ss);
        if out_first && out_second {
            break;
        }
        let choose_first = !out_first && (out_second || first.get(fi) < second.get(si) + EPSILON);
        if choose_first {
            fi += 1;
        } else {
            si += 1;
        }
        let (cf, cs) = (fi as isize - 1, si as isize - 1);
        let next = if choose_first {
            first.get(fi - 1)
        } else {
            second.get(si - 1)
        };
        if last >= next - EPSILON {
            *cells.last_mut().expect("a value before") = (cf, cs);
        } else {
            values.push(next);
            cells.push((cf, cs));
            last = next;
        }
    }
    if values.len() <= 1 {
        values = vec![0.0];
    }
    let n = values.len() - 1;
    cells.truncate(n);
    Merged {
        coords: Coords::List(values),
        cells,
        cube: false,
    }
}

/// `Shapes.joinUnoptimized(first, second, OR)`.
pub fn join_or(first: &Grid, second: &Grid) -> Grid {
    if first.is_empty() {
        return second.clone();
    }
    if second.is_empty() {
        return first.clone();
    }
    let mx = merger(1, &first.coords[0], &second.coords[0]);
    let my = merger(mx.coords.len() - 1, &first.coords[1], &second.coords[1]);
    let mz = merger(
        (mx.coords.len() - 1) * (my.coords.len() - 1),
        &first.coords[2],
        &second.coords[2],
    );
    let sizes = [mx.cells.len(), my.cells.len(), mz.cells.len()];
    let mut full = vec![false; sizes[0] * sizes[1] * sizes[2]];
    for (xr, &(x1, x2)) in mx.cells.iter().enumerate() {
        for (yr, &(y1, y2)) in my.cells.iter().enumerate() {
            for (zr, &(z1, z2)) in mz.cells.iter().enumerate() {
                full[(xr * sizes[1] + yr) * sizes[2] + zr] =
                    first.full_wide(x1, y1, z1) || second.full_wide(x2, y2, z2);
            }
        }
    }
    let cube = mx.cube && my.cube && mz.cube;
    let coords = [mx.coords, my.coords, mz.coords];
    Grid {
        coords: if cube {
            coords.map(|c| Coords::Cube(c.len() - 1))
        } else {
            coords
        },
        full,
        block: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_box_within_the_epsilon_of_the_block_is_the_block() {
        let shape = Grid::of(
            &VoxelShape::block(),
            Some([0.0, -5.960464477539063e-8, 0.0]),
        )
        .optimize()
        .shape();
        assert!(shape.full_block);
    }

    #[test]
    fn merging_keeps_the_first_of_two_close_values() {
        // A piston head facing up at progress 0.74999994: the platform snaps
        // to the quarter grid, the arm keeps its own top, which wins.
        let arm = Grid::create(&Aabb {
            min: [0.375, -0.2500000596046448, 0.375],
            max: [0.625, 0.7499999403953552, 0.625],
        });
        let platform = Grid::create(&Aabb {
            min: [0.0, 0.4999999403953552, 0.0],
            max: [1.0, 0.7499999403953552, 1.0],
        });
        let joined = join_or(&arm, &platform).shape();
        assert_eq!(
            joined.axes[1],
            vec![-0.2500000596046448, 0.0, 0.25, 0.5, 0.7499999403953552, 1.0]
        );
    }
}
