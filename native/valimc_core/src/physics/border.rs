//! The world border as a collider (vanilla's `WorldBorder.getCollisionShape`
//! and `isInsideCloseToBorder`), for a stationary border.

use super::aabb::Aabb;
use super::shape::{box_shape, Place, VoxelShape};

const EXTENT: f64 = 60_000_000.0;

/// A stationary border: its clamped bounds `[min_x, min_z, max_x, max_z]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Border {
    pub min_x: f64,
    pub min_z: f64,
    pub max_x: f64,
    pub max_z: f64,
}

impl Border {
    fn within(&self, x: f64, z: f64, margin: f64) -> bool {
        x >= self.min_x - margin
            && x < self.max_x + margin
            && z >= self.min_z - margin
            && z < self.max_z + margin
    }

    fn distance(&self, x: f64, z: f64) -> f64 {
        (x - self.min_x)
            .min(self.max_x - x)
            .min(z - self.min_z)
            .min(self.max_z - z)
    }

    /// `isInsideCloseToBorder` for a mover at `(x, z)` querying `query`.
    pub fn close(&self, x: f64, z: f64, query: &Aabb) -> bool {
        let margin = query.size(0).abs().max(query.size(2).abs()).max(1.0);
        self.distance(x, z) < margin * 2.0 && self.within(x, z, margin)
    }

    /// The space outside the border: everything but the block-aligned box
    /// around it, with the union's internal planes kept.
    pub fn outside(&self) -> VoxelShape {
        let x0 = self.min_x.floor();
        let x1 = self.max_x.ceil();
        let z0 = self.min_z.floor();
        let z1 = self.max_z.ceil();
        if x0 == x1 || z0 == z1 {
            return box_shape(&Aabb::new([-EXTENT; 3], [EXTENT; 3]));
        }
        let xs = vec![-EXTENT, x0, x1, EXTENT];
        let zs = vec![-EXTENT, z0, z1, EXTENT];
        let mut filled = vec![true; 9];
        // Cell (x = 1, z = 1) is the inside.
        filled[3 + 1] = false;
        VoxelShape::new([xs, vec![-EXTENT, EXTENT], zs], [3, 1, 3], &filled)
            .expect("the border shape is a valid grid")
    }

    /// The border collider a mover at `(x, z)` meets in `query`, if any.
    pub fn collider(&self, x: f64, z: f64, query: &Aabb) -> Option<VoxelShape> {
        if !self.close(x, z, query) {
            return None;
        }
        let shape = self.outside();
        shape
            .intersects(&Place::ORIGIN, &box_shape(query), &Place::ORIGIN)
            .then_some(shape)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_border_blocks_only_outside() {
        let border = Border {
            min_x: -10.0,
            min_z: -10.0,
            max_x: 10.0,
            max_z: 10.0,
        };
        let inside = Aabb::new([0.0, 0.0, 0.0], [0.6, 1.8, 0.6]);
        assert!(border.collider(0.3, 0.3, &inside).is_none());
        let edge = Aabb::new([9.5, 0.0, 0.0], [10.5, 1.8, 0.6]);
        assert!(border.collider(9.8, 0.3, &edge).is_some());
    }
}
