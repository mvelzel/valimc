//! A box of block positions sampled together, as vanilla's `DensityVolume`:
//! a size, minimum block and block step per axis (X, Y, Z). Buffers over a
//! volume hold one `f32` per position, Y fastest, then X, then Z.

use super::java::{floor_div, floor_mod};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Volume {
    pub size: [i32; 3],
    pub min: [i32; 3],
    pub step: [i32; 3],
}

pub const X: usize = 0;
pub const Y: usize = 1;
pub const Z: usize = 2;

impl Volume {
    pub fn new(size: [i32; 3], min: [i32; 3], step: [i32; 3]) -> Result<Self, String> {
        if size.iter().any(|&s| s <= 0) {
            return Err(format!("volume size must be positive, was {size:?}"));
        }
        if step.iter().any(|&s| s <= 0) {
            return Err(format!("volume step must be positive, was {step:?}"));
        }
        Ok(Volume { size, min, step })
    }

    pub fn len(&self) -> usize {
        self.size.iter().map(|&s| s as usize).product()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The block coordinate of index `i` on `axis` (Java int arithmetic).
    pub fn block(&self, axis: usize, i: i32) -> i32 {
        self.min[axis].wrapping_add(i.wrapping_mul(self.step[axis]))
    }

    pub fn index(&self, x: i32, y: i32, z: i32) -> usize {
        (y + (x + z * self.size[X]) * self.size[Y]) as usize
    }

    /// The last block coordinate on `axis`.
    pub fn max_block(&self, axis: usize) -> i32 {
        self.min[axis]
            .wrapping_add(self.size[axis].wrapping_mul(self.step[axis]))
            .wrapping_sub(1)
    }

    /// The index of a block position that lies on the volume's grid.
    pub fn index_of_block(&self, x: i32, y: i32, z: i32) -> Option<usize> {
        let rel = [
            x.wrapping_sub(self.min[X]),
            y.wrapping_sub(self.min[Y]),
            z.wrapping_sub(self.min[Z]),
        ];
        if self.step == [1, 1, 1] {
            if (0..3).all(|a| rel[a] >= 0 && rel[a] < self.size[a]) {
                return Some(self.index(rel[X], rel[Y], rel[Z]));
            }
        } else if (0..3).all(|a| {
            rel[a] >= 0
                && rel[a] < self.size[a].wrapping_mul(self.step[a])
                && floor_mod(rel[a], self.step[a]) == 0
        }) {
            return Some(self.index(
                floor_div(rel[X], self.step[X]),
                floor_div(rel[Y], self.step[Y]),
                floor_div(rel[Z], self.step[Z]),
            ));
        }
        None
    }
}
