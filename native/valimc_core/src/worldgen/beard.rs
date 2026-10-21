//! The beardifier (VMC-025f3): structures that adapt the terrain raise
//! ground under their pieces and carve room around them, as vanilla's
//! `Beardifier` adds to the final density of the noise fill. A chunk's
//! beardifier holds the pieces within 12 blocks of it, of every start that
//! references the chunk and adapts terrain, and the jigsaw junctions near
//! it; sampling sums each one's contribution in that order, in `f32`.

use std::sync::OnceLock;

use super::java::floor_div;
use super::structure::jigsaw::{Element, Projection};
use super::structure::piece::{BoundingBox, PieceKind};
use super::structure::{Start, StructureRegistry, TerrainAdjustment};
use super::volume::{Volume, X, Y, Z};

const KERNEL_RADIUS: i32 = 12;
const KERNEL_SIZE: i32 = 24;

/// A piece's box with the structure's adjustment and, for jigsaw pieces,
/// its ground level delta.
#[derive(Clone, Debug, PartialEq)]
struct Rigid {
    bbox: BoundingBox,
    adjustment: TerrainAdjustment,
    ground_level_delta: i32,
}

/// A jigsaw junction: where a piece joined another, at its ground.
#[derive(Clone, Debug, PartialEq)]
struct Junction {
    x: i32,
    ground_y: i32,
    z: i32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Beardifier {
    pieces: Vec<Rigid>,
    junctions: Vec<Junction>,
    /// The pieces' and junctions' box grown by 24; nothing outside it.
    affected: Option<BoundingBox>,
}

/// `BEARD_KERNEL`: e^(-d²/16) at the cell centre's height, over 24³ cells
/// (z, then x, then y), each rounded to `f32`.
fn kernel() -> &'static [f32] {
    static KERNEL: OnceLock<Vec<f32>> = OnceLock::new();
    KERNEL.get_or_init(|| {
        let mut kernel = vec![0.0f32; (KERNEL_SIZE * KERNEL_SIZE * KERNEL_SIZE) as usize];
        for z in 0..KERNEL_SIZE {
            for x in 0..KERNEL_SIZE {
                for y in 0..KERNEL_SIZE {
                    let (dx, dy, dz) = (
                        (x - KERNEL_RADIUS) as f64,
                        (y - KERNEL_RADIUS) as f64 + 0.5,
                        (z - KERNEL_RADIUS) as f64,
                    );
                    let distance = dx * dx + dy * dy + dz * dz;
                    let i = (z * KERNEL_SIZE * KERNEL_SIZE + x * KERNEL_SIZE + y) as usize;
                    kernel[i] = std::f64::consts::E.powf(-distance / 16.0) as f32;
                }
            }
        }
        kernel
    })
}

/// `Mth.fastInvSqrt(double)`: one Newton step from the magic constant.
fn fast_inv_sqrt(x: f64) -> f64 {
    let half = 0.5 * x;
    let bits = 6_910_469_410_427_058_090i64.wrapping_sub((x.to_bits() as i64) >> 1);
    let y = f64::from_bits(bits as u64);
    y * (1.5 - half * y * y)
}

/// `getBuryContribution`: falls off linearly to 0 at 6 blocks.
fn bury(dx: f32, dy: f32, dz: f32) -> f32 {
    let distance = dx * dx + dy * dy + dz * dz;
    if distance >= 36.0 {
        0.0
    } else {
        1.0 - ((distance as f64).sqrt() as f32) / 6.0
    }
}

/// `getBeardContribution`: positive below the ground, negative above it,
/// weighted by the kernel within 12 blocks.
fn beard(dx: i32, dy: i32, dz: i32, dy_to_ground: i32) -> f32 {
    let (x, y, z) = (dx + KERNEL_RADIUS, dy + KERNEL_RADIUS, dz + KERNEL_RADIUS);
    let in_range = |v: i32| (0..KERNEL_SIZE).contains(&v);
    if !(in_range(x) && in_range(y) && in_range(z)) {
        return 0.0;
    }
    let height = dy_to_ground as f32 + 0.5;
    let distance = (dx as f32) * (dx as f32) + height * height + (dz as f32) * (dz as f32);
    let value = -height * (fast_inv_sqrt((distance / 2.0) as f64) as f32) / 2.0;
    value * kernel()[(z * KERNEL_SIZE * KERNEL_SIZE + x * KERNEL_SIZE + y) as usize]
}

fn include(a: Option<BoundingBox>, b: BoundingBox) -> Option<BoundingBox> {
    Some(match a {
        None => b,
        Some(mut a) => {
            a.encapsulate(&b);
            a
        }
    })
}

impl Beardifier {
    /// `Beardifier.forStructuresInChunk` over the starts that reference the
    /// chunk, in the order the chunk lists them.
    pub fn for_chunk<'s>(
        registry: &StructureRegistry,
        starts: impl IntoIterator<Item = &'s Start>,
        chunk: (i32, i32),
    ) -> Beardifier {
        let (min_x, min_z) = (chunk.0 * 16, chunk.1 * 16);
        let mut out = Beardifier::default();
        let mut bbox = None;
        for start in starts {
            let adjustment = registry.structures[start.structure].terrain_adaptation;
            if adjustment == TerrainAdjustment::None {
                continue;
            }
            for piece in &start.pieces {
                // `isCloseToChunk(chunk, 12)`.
                let b = piece.bbox;
                if !b.intersects_xz(min_x - 12, min_z - 12, min_x + 15 + 12, min_z + 15 + 12) {
                    continue;
                }
                if let PieceKind::Jigsaw(j) = &piece.kind {
                    if projection(&j.element) == Projection::Rigid {
                        out.pieces.push(Rigid {
                            bbox: b,
                            adjustment,
                            ground_level_delta: j.ground_level_delta,
                        });
                        bbox = include(bbox, b);
                    }
                    for junction in &j.junctions {
                        let (x, z) = (junction.source_x, junction.source_z);
                        if x > min_x - 12
                            && z > min_z - 12
                            && x < min_x + 15 + 12
                            && z < min_z + 15 + 12
                        {
                            out.junctions.push(Junction {
                                x,
                                ground_y: junction.source_ground_y,
                                z,
                            });
                            bbox = include(bbox, BoundingBox::at(x, junction.source_ground_y, z));
                        }
                    }
                } else {
                    out.pieces.push(Rigid {
                        bbox: b,
                        adjustment,
                        ground_level_delta: 0,
                    });
                    bbox = include(bbox, b);
                }
            }
        }
        out.affected = bbox.map(|b| b.inflated(24, 24, 24));
        out
    }

    pub fn is_empty(&self) -> bool {
        self.affected.is_none()
    }

    /// `sampleValue`.
    pub fn value(&self, x: i32, y: i32, z: i32) -> f32 {
        match self.affected {
            Some(b) if b.is_inside(x, y, z) => self.value_unchecked(x, y, z),
            _ => 0.0,
        }
    }

    /// `sampleVolume`: zero, then the affected box's part of the volume.
    pub fn fill(&self, out: &mut [f32], v: &Volume) {
        out.fill(0.0);
        let Some(b) = self.affected else {
            return;
        };
        let volume = BoundingBox::new(
            v.min[X],
            v.min[Y],
            v.min[Z],
            v.max_block(X),
            v.max_block(Y),
            v.max_block(Z),
        );
        if !b.intersects(&volume) {
            return;
        }
        let first = |axis: usize, min: i32| floor_div(0.max(min - v.min[axis]), v.step[axis]);
        let last = |axis: usize, max: i32| {
            (v.size[axis] - 1).min(floor_div(max - v.min[axis], v.step[axis]))
        };
        let (x0, y0, z0) = (first(X, b.min_x), first(Y, b.min_y), first(Z, b.min_z));
        let (x1, y1, z1) = (last(X, b.max_x), last(Y, b.max_y), last(Z, b.max_z));
        for iz in z0..=z1 {
            let z = v.block(Z, iz);
            for ix in x0..=x1 {
                let x = v.block(X, ix);
                for iy in y0..=y1 {
                    out[v.index(ix, iy, iz)] = self.value_unchecked(x, v.block(Y, iy), z);
                }
            }
        }
    }

    fn value_unchecked(&self, x: i32, y: i32, z: i32) -> f32 {
        let mut density = 0.0f32;
        for rigid in &self.pieces {
            let b = &rigid.bbox;
            let dx = 0.max((b.min_x - x).max(x - b.max_x));
            let dz = 0.max((b.min_z - z).max(z - b.max_z));
            let ground = b.min_y + rigid.ground_level_delta;
            let dy_to_ground = y - ground;
            let dy = match rigid.adjustment {
                TerrainAdjustment::None => 0,
                TerrainAdjustment::Bury | TerrainAdjustment::BeardThin => dy_to_ground,
                TerrainAdjustment::BeardBox => 0.max((ground - y).max(y - b.max_y)),
                TerrainAdjustment::Encapsulate => 0.max((b.min_y - y).max(y - b.max_y)),
            };
            density += match rigid.adjustment {
                TerrainAdjustment::None => 0.0,
                TerrainAdjustment::Bury => bury(dx as f32, dy as f32 / 2.0, dz as f32),
                TerrainAdjustment::BeardThin | TerrainAdjustment::BeardBox => {
                    beard(dx, dy, dz, dy_to_ground) * 0.8
                }
                TerrainAdjustment::Encapsulate => {
                    bury(dx as f32 / 2.0, dy as f32 / 2.0, dz as f32 / 2.0) * 0.8
                }
            };
        }
        for junction in &self.junctions {
            let (dx, dy, dz) = (x - junction.x, y - junction.ground_y, z - junction.z);
            density += beard(dx, dy, dz, dy) * 0.4;
        }
        density
    }
}

fn projection(element: &Element) -> Projection {
    match element {
        Element::Single { projection, .. }
        | Element::List { projection, .. }
        | Element::Feature { projection, .. } => *projection,
        Element::Empty => Projection::TerrainMatching,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_inv_sqrt_is_close_to_the_inverse_square_root() {
        for x in [0.5f64, 1.0, 2.0, 37.25, 1e4] {
            let want = 1.0 / x.sqrt();
            assert!((fast_inv_sqrt(x) - want).abs() / want < 2e-3, "{x}");
        }
    }

    #[test]
    fn the_kernel_peaks_at_its_centre() {
        let k = kernel();
        let centre = (12 * 576 + 12 * 24 + 12) as usize;
        assert!((k[centre] - (-0.25f64 / 16.0).exp() as f32).abs() < 1e-6);
        assert!(k.iter().all(|&v| v > 0.0 && v <= k[centre]));
    }

    #[test]
    fn beards_raise_ground_below_and_carve_above() {
        assert!(beard(0, -3, 0, -3) > 0.0);
        assert!(beard(0, 3, 0, 3) < 0.0);
        assert_eq!(beard(13, 0, 0, 0), 0.0);
        assert_eq!(bury(6.0, 0.0, 0.0), 0.0);
        assert_eq!(bury(0.0, 0.0, 0.0), 1.0);
    }
}
