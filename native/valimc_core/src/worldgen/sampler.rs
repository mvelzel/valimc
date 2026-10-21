//! Compiled density samplers (VMC-023c), vanilla's `DensitySampler`s: every
//! sampler has a point path (`value`) and a volume path (`fill`), which round
//! differently and are kept apart exactly as vanilla keeps them. A `Context`
//! carries the cache cells shared by all samplers sampled through it.

use std::sync::Arc;

use super::beard::Beardifier;
use super::density::{leaky_relu, squeeze, Axis, Metric, Unary};
use super::java::{clamp, floor_div, floor_f32, floor_mod, fmax, fmin};
use super::noise::{end_island_height, lerp, lerp3, Simplex, Stack};
use super::volume::{Volume, X, Y, Z};

/// Context fields a sampler reads (blending and structure terrain); without
/// them in the context, the fallback value applies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    BlendAlpha,
    BlendOffset,
    Beardifier,
}

#[derive(Clone, Copy, Debug)]
pub enum GradientKind {
    Clamped { min: i32, max: i32 },
    Repeat { range: i32 },
    Mirrored { range: i32 },
}

#[derive(Clone, Debug)]
pub enum SplineNode {
    Constant(f32),
    Multipoint {
        coordinate: usize,
        locations: Vec<f32>,
        values: Vec<SplineNode>,
        derivatives: Vec<f32>,
    },
}

type B = Box<Sampler>;

#[derive(Clone, Debug)]
pub enum Sampler {
    Constant(f32),
    Field(Field, f32),
    Noise {
        noise: Arc<Stack>,
        xz: f64,
        y: f64,
    },
    ShiftedXz {
        shift_x: B,
        shift_z: B,
        noise: Arc<Stack>,
        xz: f64,
        y: f64,
    },
    ShiftedXyz {
        shift: Box<[Sampler; 3]>,
        noise: Arc<Stack>,
        xz: f64,
        y: f64,
    },
    ShiftB(Arc<Stack>),
    EndIslands(Arc<Simplex>),
    Distance([i32; 3], Metric),
    Gradient {
        axis: Axis,
        kind: GradientKind,
        from: i32,
        from_value: f32,
        factor: f32,
    },
    Unary(Unary, B),
    Add(B, B),
    ConstAdd(B, f32),
    Sub(B, B),
    ConstSub(f32, B),
    Mul(B, B),
    ConstMul(B, f32),
    Div(B, B),
    ConstDiv(f32, B),
    /// Left, right and the right side's lower bound.
    Min(B, B, f32),
    ConstMin(B, f32),
    /// Left, right and the right side's upper bound.
    Max(B, B, f32),
    ConstMax(B, f32),
    Spline {
        spline: Box<SplineNode>,
        coordinates: Vec<Sampler>,
    },
    /// Alpha, first, second.
    Lerp(Box<[Sampler; 3]>),
    LerpConstFirst(B, f32, B),
    LerpConstSecond(B, B, f32),
    Clamp(B, f32, f32),
    RangeChoiceConst {
        input: B,
        min: f32,
        max: f32,
        in_range: f32,
        out_of_range: f32,
    },
    RangeChoice {
        input: B,
        min: f32,
        max: f32,
        in_range: B,
        out_of_range: B,
    },
    IntervalSelect {
        input: B,
        thresholds: Vec<f32>,
        samplers: Vec<Sampler>,
    },
    IntervalSelectSingle {
        input: B,
        threshold: f32,
        below: B,
        above: B,
    },
    Cache {
        id: usize,
        input: Arc<Sampler>,
    },
    BlendDensity(B),
    Interpolated {
        input: B,
        xz: i32,
        y: i32,
        xz_inv: f32,
        y_inv: f32,
    },
    SliceX(B, i32),
    SliceY(B, i32),
    SliceZ(B, i32),
    SliceXz(B, i32, i32),
    FindTopSurface {
        density: B,
        upper: B,
        lower: i32,
        cell: i32,
    },
}

#[derive(Clone, Debug)]
struct Cell {
    volume: Option<Volume>,
    buffer: Vec<f32>,
    key: i64,
    value: f32,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            volume: None,
            buffer: Vec::new(),
            key: 0,
            value: f32::NAN,
        }
    }
}

/// Vanilla's `SamplerContext`: with caches enabled, each cache keeps the last
/// volume it sampled and the last point value. A point inside that volume's
/// grid reads the volume's value, so the order of samples through one context
/// matters, as in vanilla.
#[derive(Clone, Debug, Default)]
pub struct Context {
    cells: Option<Vec<Cell>>,
    /// The chunk's beardifier (VMC-025f3); without one it samples 0.
    pub beardifier: Option<Arc<Beardifier>>,
}

/// `BlockPos.asLong`: the cache key of a position.
fn block_key(x: i32, y: i32, z: i32) -> i64 {
    ((x as i64 & 0x3FF_FFFF) << 38) | (y as i64 & 0xFFF) | ((z as i64 & 0x3FF_FFFF) << 12)
}

impl Context {
    pub fn uncached() -> Self {
        Context {
            cells: None,
            beardifier: None,
        }
    }

    pub fn cached() -> Self {
        Context {
            cells: Some(Vec::new()),
            beardifier: None,
        }
    }

    fn cell(&mut self, id: usize) -> Option<&mut Cell> {
        let cells = self.cells.as_mut()?;
        if id >= cells.len() {
            cells.resize_with((id + 1).div_ceil(16) * 16, Cell::default);
        }
        Some(&mut cells[id])
    }

    fn value_cached(&mut self, id: usize, input: &Sampler, x: i32, y: i32, z: i32) -> f32 {
        let key = block_key(x, y, z);
        match self.cell(id) {
            None => return input.value(self, x, y, z),
            Some(cell) => {
                if cell.key == key && !cell.value.is_nan() {
                    return cell.value;
                }
                if let Some(index) = cell.volume.and_then(|v| v.index_of_block(x, y, z)) {
                    return cell.buffer[index];
                }
            }
        }
        let value = input.value(self, x, y, z);
        if let Some(cell) = self.cell(id) {
            cell.key = key;
            cell.value = value;
        }
        value
    }

    fn fill_cached(&mut self, id: usize, input: &Sampler, out: &mut [f32], volume: &Volume) {
        let stale = match self.cell(id) {
            None => return input.fill(self, out, volume),
            Some(cell) => cell.volume != Some(*volume),
        };
        if stale {
            let mut buffer = vec![0.0f32; volume.len()];
            input.fill(self, &mut buffer, volume);
            if let Some(cell) = self.cell(id) {
                cell.volume = Some(*volume);
                cell.buffer = buffer;
            }
        }
        if let Some(cell) = self.cell(id) {
            out.copy_from_slice(&cell.buffer);
        }
    }
}

fn unary(op: Unary, x: f32) -> f32 {
    match op {
        Unary::Abs => x.abs(),
        Unary::Square => x * x,
        Unary::Cube => x * x * x,
        Unary::Sqrt => (x as f64).sqrt() as f32,
        Unary::HalfNegative => leaky_relu(0.5, x),
        Unary::QuarterNegative => leaky_relu(0.25, x),
        Unary::Reciprocal => 1.0 / x,
        Unary::Negate => -x,
        Unary::Squeeze => squeeze(x),
        Unary::Log => (x as f64).ln() as f32,
        Unary::Sign => {
            if x == 0.0 || x.is_nan() {
                x
            } else {
                x.signum()
            }
        }
    }
}

fn distance(metric: Metric, dx: f32, dy: f32, dz: f32) -> f32 {
    match metric {
        Metric::Euclidean => ((dx * dx + dy * dy + dz * dz) as f64).sqrt() as f32,
        Metric::EuclideanSquared => dx * dx + dy * dy + dz * dz,
        Metric::Manhattan => dx.abs() + dy.abs() + dz.abs(),
        Metric::Chebyshev => fmax(fmax(dx.abs(), dy.abs()), dz.abs()),
    }
}

fn gradient(kind: GradientKind, from: i32, from_value: f32, factor: f32, c: i32) -> f32 {
    match kind {
        GradientKind::Clamped { min, max } => {
            let clamped = if c < min { min } else { c.min(max) };
            from_value + clamped.wrapping_sub(from) as f32 * factor
        }
        GradientKind::Repeat { range } => {
            from_value + floor_mod(c.wrapping_sub(from), range) as f32 * factor
        }
        GradientKind::Mirrored { range } => {
            let rel = c.wrapping_sub(from);
            let tile = floor_div(rel, range);
            let local = rel.wrapping_sub(tile.wrapping_mul(range));
            if tile & 1 == 0 {
                from_value + local as f32 * factor
            } else {
                from_value + range.wrapping_sub(local) as f32 * factor
            }
        }
    }
}

/// `CubicSpline.Multipoint.sample`, reading coordinates through `input`.
fn spline(node: &SplineNode, input: &mut dyn FnMut(usize) -> f32) -> f32 {
    let (coordinate, locations, values, derivatives) = match node {
        SplineNode::Constant(v) => return *v,
        SplineNode::Multipoint {
            coordinate,
            locations,
            values,
            derivatives,
        } => (*coordinate, locations, values, derivatives),
    };
    let x = input(coordinate);
    let extend = |value: f32, i: usize| {
        let d = derivatives[i];
        if d == 0.0 {
            value
        } else {
            value + d * (x - locations[i])
        }
    };
    // `Mth.binarySearch` for the first location above x (none for NaN).
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    let start = locations.partition_point(|&l| !(x < l)) as isize - 1;
    let last = locations.len() - 1;
    if start < 0 {
        return extend(spline(&values[0], input), 0);
    }
    let start = start as usize;
    if start == last {
        return extend(spline(&values[last], input), last);
    }
    let (x1, x2) = (locations[start], locations[start + 1]);
    let t = (x - x1) / (x2 - x1);
    let (d1, d2) = (derivatives[start], derivatives[start + 1]);
    let y1 = spline(&values[start], input);
    let y2 = spline(&values[start + 1], input);
    let a = d1 * (x2 - x1) - (y2 - y1);
    let b = -d2 * (x2 - x1) + (y2 - y1);
    lerp(t, y1, y2) + t * (1.0 - t) * lerp(t, a, b)
}

impl Sampler {
    /// The value at one block (vanilla's `sampleValue`).
    pub fn value(&self, ctx: &mut Context, x: i32, y: i32, z: i32) -> f32 {
        match self {
            Sampler::Field(Field::Beardifier, v) => match &ctx.beardifier {
                Some(b) => b.value(x, y, z),
                None => *v,
            },
            Sampler::Constant(v) | Sampler::Field(_, v) => *v,
            Sampler::Noise { noise, xz, y: ys } => {
                noise.get(x as f64 * xz, y as f64 * ys, z as f64 * xz)
            }
            Sampler::ShiftedXz {
                shift_x,
                shift_z,
                noise,
                xz,
                y: ys,
            } => {
                let nx = x as f64 * xz + shift_x.value(ctx, x, y, z) as f64;
                let ny = y as f64 * ys;
                let nz = z as f64 * xz + shift_z.value(ctx, x, y, z) as f64;
                noise.get(nx, ny, nz)
            }
            Sampler::ShiftedXyz {
                shift,
                noise,
                xz,
                y: ys,
            } => {
                let nx = x as f64 * xz + shift[0].value(ctx, x, y, z) as f64;
                let ny = y as f64 * ys + shift[1].value(ctx, x, y, z) as f64;
                let nz = z as f64 * xz + shift[2].value(ctx, x, y, z) as f64;
                noise.get(nx, ny, nz)
            }
            Sampler::ShiftB(noise) => noise.get(z as f64 * 0.25, x as f64 * 0.25, 0.0) * 4.0,
            Sampler::EndIslands(noise) => (end_island_height(noise, x / 8, z / 8) - 8.0) / 128.0,
            Sampler::Distance(p, metric) => distance(
                *metric,
                p[X].wrapping_sub(x) as f32,
                p[Y].wrapping_sub(y) as f32,
                p[Z].wrapping_sub(z) as f32,
            ),
            Sampler::Gradient {
                axis,
                kind,
                from,
                from_value,
                factor,
            } => gradient(*kind, *from, *from_value, *factor, axis.choose(x, y, z)),
            Sampler::Unary(op, input) => unary(*op, input.value(ctx, x, y, z)),
            Sampler::Add(l, r) => l.value(ctx, x, y, z) + r.value(ctx, x, y, z),
            Sampler::ConstAdd(l, c) => l.value(ctx, x, y, z) + c,
            Sampler::Sub(l, r) => l.value(ctx, x, y, z) - r.value(ctx, x, y, z),
            Sampler::ConstSub(c, r) => c - r.value(ctx, x, y, z),
            Sampler::Mul(l, r) => {
                let left = l.value(ctx, x, y, z);
                if left == 0.0 {
                    0.0
                } else {
                    left * r.value(ctx, x, y, z)
                }
            }
            Sampler::ConstMul(l, c) => l.value(ctx, x, y, z) * c,
            Sampler::Div(l, r) => {
                let left = l.value(ctx, x, y, z);
                if left == 0.0 {
                    0.0
                } else {
                    left / r.value(ctx, x, y, z)
                }
            }
            Sampler::ConstDiv(c, r) => c / r.value(ctx, x, y, z),
            Sampler::Min(l, r, right_min) => {
                let left = l.value(ctx, x, y, z);
                if left <= *right_min {
                    left
                } else {
                    fmin(left, r.value(ctx, x, y, z))
                }
            }
            Sampler::ConstMin(l, c) => fmin(l.value(ctx, x, y, z), *c),
            Sampler::Max(l, r, right_max) => {
                let left = l.value(ctx, x, y, z);
                if left >= *right_max {
                    left
                } else {
                    fmax(left, r.value(ctx, x, y, z))
                }
            }
            Sampler::ConstMax(l, c) => fmax(l.value(ctx, x, y, z), *c),
            Sampler::Spline {
                spline: node,
                coordinates,
            } => {
                let mut cached = vec![f32::NAN; coordinates.len()];
                spline(node, &mut |i| {
                    if cached[i].is_nan() {
                        cached[i] = coordinates[i].value(ctx, x, y, z);
                    }
                    cached[i]
                })
            }
            Sampler::Lerp(args) => {
                let alpha = args[0].value(ctx, x, y, z);
                if alpha == 0.0 {
                    args[1].value(ctx, x, y, z)
                } else if alpha == 1.0 {
                    args[2].value(ctx, x, y, z)
                } else {
                    let first = args[1].value(ctx, x, y, z);
                    lerp(alpha, first, args[2].value(ctx, x, y, z))
                }
            }
            Sampler::LerpConstFirst(alpha, first, second) => {
                let a = alpha.value(ctx, x, y, z);
                if a == 0.0 {
                    *first
                } else if a == 1.0 {
                    second.value(ctx, x, y, z)
                } else {
                    lerp(a, *first, second.value(ctx, x, y, z))
                }
            }
            Sampler::LerpConstSecond(alpha, first, second) => {
                let a = alpha.value(ctx, x, y, z);
                if a == 0.0 {
                    first.value(ctx, x, y, z)
                } else if a == 1.0 {
                    *second
                } else {
                    lerp(a, first.value(ctx, x, y, z), *second)
                }
            }
            Sampler::Clamp(input, min, max) => clamp(input.value(ctx, x, y, z), *min, *max),
            Sampler::RangeChoiceConst {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                let v = input.value(ctx, x, y, z);
                if v >= *min && v < *max {
                    *in_range
                } else {
                    *out_of_range
                }
            }
            Sampler::RangeChoice {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                let v = input.value(ctx, x, y, z);
                if v >= *min && v < *max {
                    in_range.value(ctx, x, y, z)
                } else {
                    out_of_range.value(ctx, x, y, z)
                }
            }
            Sampler::IntervalSelect {
                input,
                thresholds,
                samplers,
            } => {
                let v = input.value(ctx, x, y, z);
                samplers[select(thresholds, v, samplers.len())].value(ctx, x, y, z)
            }
            Sampler::IntervalSelectSingle {
                input,
                threshold,
                below,
                above,
            } => {
                if input.value(ctx, x, y, z) < *threshold {
                    below.value(ctx, x, y, z)
                } else {
                    above.value(ctx, x, y, z)
                }
            }
            Sampler::Cache { id, input } => ctx.value_cached(*id, input, x, y, z),
            Sampler::BlendDensity(input) => input.value(ctx, x, y, z),
            Sampler::Interpolated {
                input,
                xz,
                y: cell_y,
                ..
            } => {
                let (xi, yi, zi) = (floor_mod(x, *xz), floor_mod(y, *cell_y), floor_mod(z, *xz));
                if xi == 0 && yi == 0 && zi == 0 {
                    return input.value(ctx, x, y, z);
                }
                let volume = Volume {
                    size: [2, 2, 2],
                    min: [x - xi, y - yi, z - zi],
                    step: [*xz, *cell_y, *xz],
                };
                let mut buffer = vec![0.0f32; 8];
                input.fill(ctx, &mut buffer, &volume);
                let at = |a, b, c| buffer[volume.index(a, b, c)];
                lerp3(
                    xi as f32 / *xz as f32,
                    yi as f32 / *cell_y as f32,
                    zi as f32 / *xz as f32,
                    [
                        at(0, 0, 0),
                        at(1, 0, 0),
                        at(0, 1, 0),
                        at(1, 1, 0),
                        at(0, 0, 1),
                        at(1, 0, 1),
                        at(0, 1, 1),
                        at(1, 1, 1),
                    ],
                )
            }
            Sampler::SliceX(input, sx) => input.value(ctx, *sx, y, z),
            Sampler::SliceY(input, sy) => input.value(ctx, x, *sy, z),
            Sampler::SliceZ(input, sz) => input.value(ctx, x, y, *sz),
            Sampler::SliceXz(input, sx, sz) => input.value(ctx, *sx, y, *sz),
            Sampler::FindTopSurface {
                density,
                upper,
                lower,
                cell,
            } => {
                let bound = upper.value(ctx, x, y, z);
                find_surface(density, *lower, *cell, ctx, x, z, bound) as f32
            }
        }
    }

    /// Fills `out` with the values over `volume` (vanilla's `sampleVolume`).
    pub fn fill(&self, ctx: &mut Context, out: &mut [f32], volume: &Volume) {
        let v = volume;
        let temp = || vec![0.0f32; v.len()];
        match self {
            Sampler::Field(Field::Beardifier, c) => match &ctx.beardifier {
                Some(b) => b.fill(out, v),
                None => out.fill(*c),
            },
            Sampler::Constant(c) | Sampler::Field(_, c) => out.fill(*c),
            Sampler::Noise { noise, xz, y } => {
                out.fill(0.0);
                noise.add_to_volume(out, v, *xz, *y, 1.0);
            }
            Sampler::ShiftedXz {
                shift_x,
                shift_z,
                noise,
                xz,
                y: ys,
            } => {
                shift_x.fill(ctx, out, v);
                let mut sz = temp();
                shift_z.fill(ctx, &mut sz, v);
                let mut i = 0;
                for iz in 0..v.size[Z] {
                    let base_z = v.block(Z, iz) as f64 * xz;
                    for ix in 0..v.size[X] {
                        let base_x = v.block(X, ix) as f64 * xz;
                        for iy in 0..v.size[Y] {
                            let ny = v.block(Y, iy) as f64 * ys;
                            out[i] = noise.get(base_x + out[i] as f64, ny, base_z + sz[i] as f64);
                            i += 1;
                        }
                    }
                }
            }
            Sampler::ShiftedXyz {
                shift,
                noise,
                xz,
                y: ys,
            } => {
                shift[0].fill(ctx, out, v);
                let mut sy = temp();
                shift[1].fill(ctx, &mut sy, v);
                let mut sz = temp();
                shift[2].fill(ctx, &mut sz, v);
                let mut i = 0;
                for iz in 0..v.size[Z] {
                    let base_z = v.block(Z, iz) as f64 * xz;
                    for ix in 0..v.size[X] {
                        let base_x = v.block(X, ix) as f64 * xz;
                        for iy in 0..v.size[Y] {
                            let ny = v.block(Y, iy) as f64 * ys + sy[i] as f64;
                            out[i] = noise.get(base_x + out[i] as f64, ny, base_z + sz[i] as f64);
                            i += 1;
                        }
                    }
                }
            }
            Sampler::ShiftB(noise) => {
                let transposed = Volume {
                    size: [v.size[Z], v.size[X], 1],
                    min: [v.min[Z], v.min[X], 0],
                    step: [v.step[Z], v.step[X], 1],
                };
                let mut buffer = vec![0.0f32; transposed.len()];
                noise.add_to_volume(&mut buffer, &transposed, 0.25, 0.25, 4.0);
                for iz in 0..v.size[Z] {
                    for ix in 0..v.size[X] {
                        let value = buffer[transposed.index(iz, ix, 0)];
                        let start = v.index(ix, 0, iz);
                        out[start..start + v.size[Y] as usize].fill(value);
                    }
                }
            }
            Sampler::EndIslands(_) => {
                for iz in 0..v.size[Z] {
                    let bz = v.block(Z, iz);
                    for ix in 0..v.size[X] {
                        let value = self.value(ctx, v.block(X, ix), 0, bz);
                        let start = v.index(ix, 0, iz);
                        out[start..start + v.size[Y] as usize].fill(value);
                    }
                }
            }
            Sampler::Distance(..) => self.fill_naive(ctx, out, v),
            Sampler::Gradient {
                axis,
                kind,
                from,
                from_value,
                factor,
            } => {
                let at = |c| gradient(*kind, *from, *from_value, *factor, c);
                let sy = v.size[Y] as usize;
                match axis {
                    Axis::X => {
                        for ix in 0..v.size[X] {
                            let value = at(v.block(X, ix));
                            for iz in 0..v.size[Z] {
                                let start = v.index(ix, 0, iz);
                                out[start..start + sy].fill(value);
                            }
                        }
                    }
                    Axis::Y => {
                        for iy in 0..v.size[Y] {
                            let value = at(v.block(Y, iy));
                            for iz in 0..v.size[Z] {
                                for ix in 0..v.size[X] {
                                    out[v.index(ix, iy, iz)] = value;
                                }
                            }
                        }
                    }
                    Axis::Z => {
                        let plane = (v.size[X] * v.size[Y]) as usize;
                        for iz in 0..v.size[Z] {
                            let value = at(v.block(Z, iz));
                            let start = v.index(0, 0, iz);
                            out[start..start + plane].fill(value);
                        }
                    }
                }
            }
            Sampler::Unary(op, input) => {
                input.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o = unary(*op, *o);
                }
            }
            Sampler::Add(l, r) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, r) in out.iter_mut().zip(&right) {
                    *o += r;
                }
            }
            Sampler::ConstAdd(l, c) => {
                l.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o += c;
                }
            }
            Sampler::Sub(l, r) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, r) in out.iter_mut().zip(&right) {
                    *o += -r;
                }
            }
            Sampler::ConstSub(c, r) => {
                r.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o = c - *o;
                }
            }
            Sampler::Mul(l, r) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, r) in out.iter_mut().zip(&right) {
                    *o *= r;
                }
            }
            Sampler::ConstMul(l, c) => {
                l.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o *= c;
                }
            }
            Sampler::Div(l, r) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, r) in out.iter_mut().zip(&right) {
                    *o /= r;
                }
            }
            Sampler::ConstDiv(c, r) => {
                r.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o = c / *o;
                }
            }
            Sampler::Min(l, r, _) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, &r) in out.iter_mut().zip(&right) {
                    if r < *o {
                        *o = r;
                    }
                }
            }
            Sampler::ConstMin(l, c) => {
                l.fill(ctx, out, v);
                for o in out.iter_mut() {
                    if *c < *o {
                        *o = *c;
                    }
                }
            }
            Sampler::Max(l, r, _) => {
                l.fill(ctx, out, v);
                let mut right = temp();
                r.fill(ctx, &mut right, v);
                for (o, &r) in out.iter_mut().zip(&right) {
                    if r > *o {
                        *o = r;
                    }
                }
            }
            Sampler::ConstMax(l, c) => {
                l.fill(ctx, out, v);
                for o in out.iter_mut() {
                    if *c > *o {
                        *o = *c;
                    }
                }
            }
            Sampler::Spline {
                spline: node,
                coordinates,
            } => {
                let mut buffers: Vec<Option<Vec<f32>>> = vec![None; coordinates.len()];
                for (i, o) in out.iter_mut().enumerate() {
                    *o = spline(node, &mut |c| {
                        let buffer = buffers[c].get_or_insert_with(|| {
                            let mut b = temp();
                            coordinates[c].fill(ctx, &mut b, v);
                            b
                        });
                        buffer[i]
                    });
                }
            }
            Sampler::Lerp(args) => {
                args[0].fill(ctx, out, v);
                let mut first = temp();
                args[1].fill(ctx, &mut first, v);
                let mut second = temp();
                args[2].fill(ctx, &mut second, v);
                for i in 0..out.len() {
                    out[i] = mix(out[i], first[i], second[i]);
                }
            }
            Sampler::LerpConstFirst(alpha, first, second) => {
                alpha.fill(ctx, out, v);
                let mut s = temp();
                second.fill(ctx, &mut s, v);
                for i in 0..out.len() {
                    out[i] = mix(out[i], *first, s[i]);
                }
            }
            Sampler::LerpConstSecond(alpha, first, second) => {
                alpha.fill(ctx, out, v);
                let mut f = temp();
                first.fill(ctx, &mut f, v);
                for i in 0..out.len() {
                    out[i] = mix(out[i], f[i], *second);
                }
            }
            Sampler::Clamp(input, min, max) => {
                input.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o = clamp(*o, *min, *max);
                }
            }
            Sampler::RangeChoiceConst {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                input.fill(ctx, out, v);
                for o in out.iter_mut() {
                    *o = if *o >= *min && *o < *max {
                        *in_range
                    } else {
                        *out_of_range
                    };
                }
            }
            Sampler::RangeChoice {
                input,
                min,
                max,
                in_range,
                out_of_range,
            } => {
                in_range.fill(ctx, out, v);
                let mut inputs = temp();
                input.fill(ctx, &mut inputs, v);
                let mut outside = temp();
                out_of_range.fill(ctx, &mut outside, v);
                for i in 0..out.len() {
                    let x = inputs[i];
                    if !(x >= *min && x < *max) {
                        out[i] = outside[i];
                    }
                }
            }
            Sampler::IntervalSelect {
                input,
                thresholds,
                samplers,
            } => {
                input.fill(ctx, out, v);
                let buffers: Vec<Vec<f32>> = samplers
                    .iter()
                    .map(|s| {
                        let mut b = temp();
                        s.fill(ctx, &mut b, v);
                        b
                    })
                    .collect();
                for (i, o) in out.iter_mut().enumerate() {
                    *o = buffers[select(thresholds, *o, samplers.len())][i];
                }
            }
            Sampler::IntervalSelectSingle {
                input,
                threshold,
                below,
                above,
            } => {
                input.fill(ctx, out, v);
                let mut b = temp();
                below.fill(ctx, &mut b, v);
                let mut a = temp();
                above.fill(ctx, &mut a, v);
                for i in 0..out.len() {
                    out[i] = if out[i] < *threshold { b[i] } else { a[i] };
                }
            }
            Sampler::Cache { id, input } => ctx.fill_cached(*id, input, out, v),
            Sampler::BlendDensity(input) => input.fill(ctx, out, v),
            Sampler::Interpolated { .. } => self.fill_interpolated(ctx, out, v),
            Sampler::SliceX(input, sx) => {
                if v.size[X] == 1 && v.min[X] == *sx {
                    return input.fill(ctx, out, v);
                }
                let iv = Volume {
                    size: [1, v.size[Y], v.size[Z]],
                    min: [*sx, v.min[Y], v.min[Z]],
                    step: v.step,
                };
                let mut buffer = vec![0.0f32; iv.len()];
                input.fill(ctx, &mut buffer, &iv);
                let mut i = 0;
                for iz in 0..v.size[Z] {
                    for _ in 0..v.size[X] {
                        for iy in 0..v.size[Y] {
                            out[i] = buffer[iv.index(0, iy, iz)];
                            i += 1;
                        }
                    }
                }
            }
            Sampler::SliceY(input, sy) => {
                if v.size[Y] == 1 && v.min[Y] == *sy {
                    return input.fill(ctx, out, v);
                }
                let iv = Volume {
                    size: [v.size[X], 1, v.size[Z]],
                    min: [v.min[X], *sy, v.min[Z]],
                    step: v.step,
                };
                let mut buffer = vec![0.0f32; iv.len()];
                input.fill(ctx, &mut buffer, &iv);
                for iz in 0..v.size[Z] {
                    for ix in 0..v.size[X] {
                        let value = buffer[iv.index(ix, 0, iz)];
                        let start = v.index(ix, 0, iz);
                        out[start..start + v.size[Y] as usize].fill(value);
                    }
                }
            }
            Sampler::SliceZ(input, sz) => {
                if v.size[Z] == 1 && v.min[Z] == *sz {
                    return input.fill(ctx, out, v);
                }
                let iv = Volume {
                    size: [v.size[X], v.size[Y], 1],
                    min: [v.min[X], v.min[Y], *sz],
                    step: v.step,
                };
                let mut buffer = vec![0.0f32; iv.len()];
                input.fill(ctx, &mut buffer, &iv);
                let mut i = 0;
                for _ in 0..v.size[Z] {
                    for ix in 0..v.size[X] {
                        for iy in 0..v.size[Y] {
                            out[i] = buffer[iv.index(ix, iy, 0)];
                            i += 1;
                        }
                    }
                }
            }
            Sampler::SliceXz(input, sx, sz) => {
                if v.size[X] == 1 && v.size[Z] == 1 && v.min[X] == *sx && v.min[Z] == *sz {
                    return input.fill(ctx, out, v);
                }
                let iv = Volume {
                    size: [1, v.size[Y], 1],
                    min: [*sx, v.min[Y], *sz],
                    step: v.step,
                };
                let mut buffer = vec![0.0f32; iv.len()];
                input.fill(ctx, &mut buffer, &iv);
                for iy in 0..v.size[Y] {
                    let value = buffer[iv.index(0, iy, 0)];
                    let mut i = v.index(0, iy, 0);
                    for _ in 0..v.size[Z] * v.size[X] {
                        out[i] = value;
                        i += v.size[Y] as usize;
                    }
                }
            }
            Sampler::FindTopSurface {
                density,
                upper,
                lower,
                cell,
            } => {
                upper.fill(ctx, out, v);
                let mut i = 0;
                for iz in 0..v.size[Z] {
                    let bz = v.block(Z, iz);
                    for ix in 0..v.size[X] {
                        let bx = v.block(X, ix);
                        out[i] = find_surface(density, *lower, *cell, ctx, bx, bz, out[i]) as f32;
                        i += 1;
                    }
                }
            }
        }
    }

    fn fill_naive(&self, ctx: &mut Context, out: &mut [f32], v: &Volume) {
        let mut i = 0;
        for iz in 0..v.size[Z] {
            let bz = v.block(Z, iz);
            for ix in 0..v.size[X] {
                let bx = v.block(X, ix);
                for iy in 0..v.size[Y] {
                    out[i] = self.value(ctx, bx, v.block(Y, iy), bz);
                    i += 1;
                }
            }
        }
    }

    fn fill_interpolated(&self, ctx: &mut Context, out: &mut [f32], v: &Volume) {
        let Sampler::Interpolated {
            input,
            xz,
            y: cell_y,
            ..
        } = self
        else {
            unreachable!()
        };
        let (xz, cell_y) = (*xz, *cell_y);
        if (v.step[X] == xz || v.size[X] == 1)
            && (v.step[Y] == cell_y || v.size[Y] == 1)
            && (v.step[Z] == xz || v.size[Z] == 1)
            && floor_mod(v.min[X], xz) == 0
            && floor_mod(v.min[Y], cell_y) == 0
            && floor_mod(v.min[Z], xz) == 0
        {
            input.fill(ctx, out, v);
        } else if v.step == [1, 1, 1] {
            self.fill_block_step(ctx, out, v);
        } else {
            let block = Volume {
                size: [
                    v.size[X] * v.step[X],
                    v.size[Y] * v.step[Y],
                    v.size[Z] * v.step[Z],
                ],
                min: v.min,
                step: [1, 1, 1],
            };
            let mut buffer = vec![0.0f32; block.len()];
            self.fill_block_step(ctx, &mut buffer, &block);
            for iz in 0..v.size[Z] {
                for ix in 0..v.size[X] {
                    for iy in 0..v.size[Y] {
                        out[v.index(ix, iy, iz)] =
                            buffer[block.index(ix * v.step[X], iy * v.step[Y], iz * v.step[Z])];
                    }
                }
            }
        }
    }

    fn fill_block_step(&self, ctx: &mut Context, out: &mut [f32], v: &Volume) {
        let Sampler::Interpolated {
            input,
            xz,
            y: cell_y,
            xz_inv,
            y_inv,
        } = self
        else {
            unreachable!()
        };
        let cells = [*xz, *cell_y, *xz];
        let min_cell: [i32; 3] = std::array::from_fn(|a| floor_div(v.min[a], cells[a]));
        let max_cell: [i32; 3] = std::array::from_fn(|a| floor_div(v.max_block(a), cells[a]));
        let count: [i32; 3] = std::array::from_fn(|a| max_cell[a] - min_cell[a] + 1);
        let cv = Volume {
            size: std::array::from_fn(|a| {
                if floor_mod(v.max_block(a), cells[a]) == 0 {
                    count[a]
                } else {
                    count[a] + 1
                }
            }),
            min: std::array::from_fn(|a| min_cell[a] * cells[a]),
            step: cells,
        };
        let mut cb = vec![0.0f32; cv.len()];
        input.fill(ctx, &mut cb, &cv);
        let at = |x, y, z| cb[cv.index(x, y, z)];
        for cz in 0..count[Z] {
            let nz = (cz + 1).min(cv.size[Z] - 1);
            for cx in 0..count[X] {
                let nx = (cx + 1).min(cv.size[X] - 1);
                let (mut v000, mut v100, mut v001, mut v101) =
                    (at(cx, 0, cz), at(nx, 0, cz), at(cx, 0, nz), at(nx, 0, nz));
                for cy in 0..count[Y] {
                    let ny = (cy + 1).min(cv.size[Y] - 1);
                    let (v010, v110, v011, v111) = (
                        at(cx, ny, cz),
                        at(nx, ny, cz),
                        at(cx, ny, nz),
                        at(nx, ny, nz),
                    );
                    // Fill one cell of output positions (vanilla's `fillCell`).
                    let co = [
                        cv.block(X, cx) - v.min[X],
                        cv.block(Y, cy) - v.min[Y],
                        cv.block(Z, cz) - v.min[Z],
                    ];
                    let lo: [i32; 3] = std::array::from_fn(|a| 0.max(-co[a]));
                    let hi: [i32; 3] = std::array::from_fn(|a| cells[a].min(v.size[a] - co[a]) - 1);
                    for z in lo[Z]..=hi[Z] {
                        let az = z as f32 * xz_inv;
                        let v00 = lerp(az, v000, v001);
                        let v01 = lerp(az, v010, v011);
                        let v10 = lerp(az, v100, v101);
                        let v11 = lerp(az, v110, v111);
                        for x in lo[X]..=hi[X] {
                            let ax = x as f32 * xz_inv;
                            let v0 = lerp(ax, v00, v10);
                            let v1 = lerp(ax, v01, v11);
                            let step = (v1 - v0) * y_inv;
                            let mut value = v0 + step * lo[Y] as f32;
                            let start = v.index(co[X] + x, co[Y] + lo[Y], co[Z] + z);
                            let count = (hi[Y] - lo[Y] + 1).max(0) as usize;
                            for o in &mut out[start..start + count] {
                                *o = value;
                                value += step;
                            }
                        }
                    }
                    v000 = v010;
                    v100 = v110;
                    v001 = v011;
                    v101 = v111;
                }
            }
        }
    }
}

/// Lerp's volume path: exact endpoints at alpha 0 and 1.
fn mix(alpha: f32, first: f32, second: f32) -> f32 {
    if alpha == 0.0 {
        first
    } else if alpha == 1.0 {
        second
    } else {
        lerp(alpha, first, second)
    }
}

fn select(thresholds: &[f32], input: f32, count: usize) -> usize {
    thresholds
        .iter()
        .position(|&t| input < t)
        .unwrap_or(count - 1)
}

fn find_surface(
    density: &Sampler,
    lower: i32,
    cell: i32,
    ctx: &mut Context,
    x: i32,
    z: i32,
    upper: f32,
) -> i32 {
    let top = floor_f32(upper / cell as f32).wrapping_mul(cell);
    if top <= lower {
        return lower;
    }
    let mut probe = top;
    while probe >= lower {
        if density.value(ctx, x, probe, z) > 0.0 {
            return probe;
        }
        probe = probe.wrapping_sub(cell);
    }
    lower
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_keys_pack_like_block_pos() {
        assert_eq!(block_key(0, 0, 0), 0);
        assert_eq!(block_key(1, 2, 3), (1 << 38) | 2 | (3 << 12));
        assert_eq!(block_key(-1, -1, -1), -1);
    }

    #[test]
    fn spline_interval_search() {
        let node = SplineNode::Multipoint {
            coordinate: 0,
            locations: vec![-1.0, 0.0, 1.0],
            values: vec![
                SplineNode::Constant(0.0),
                SplineNode::Constant(1.0),
                SplineNode::Constant(0.0),
            ],
            derivatives: vec![0.0, 0.0, 0.0],
        };
        assert_eq!(spline(&node, &mut |_| -2.0), 0.0);
        assert_eq!(spline(&node, &mut |_| 0.0), 1.0);
        assert_eq!(spline(&node, &mut |_| 5.0), 0.0);
        let mid = spline(&node, &mut |_| 0.5);
        assert!(mid > 0.0 && mid < 1.0);
    }

    #[test]
    fn cached_points_read_the_cached_volume() {
        let input = Sampler::Gradient {
            axis: Axis::Y,
            kind: GradientKind::Clamped {
                min: -100,
                max: 100,
            },
            from: -100,
            from_value: 0.0,
            factor: 0.5,
        };
        let cache = Sampler::Cache {
            id: 3,
            input: Arc::new(input),
        };
        let volume = Volume::new([1, 4, 1], [0, 0, 0], [1, 4, 1]).unwrap();
        let mut ctx = Context::cached();
        let mut out = vec![0.0; 4];
        cache.fill(&mut ctx, &mut out, &volume);
        assert_eq!(out, vec![50.0, 52.0, 54.0, 56.0]);
        assert_eq!(cache.value(&mut ctx, 0, 8, 0), 54.0);
        assert_eq!(cache.value(&mut ctx, 0, 9, 0), 54.5);
    }
}
