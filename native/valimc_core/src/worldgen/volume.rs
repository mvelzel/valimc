//! A box of block positions sampled together, as vanilla's `DensityVolume`:
//! a size, minimum block and block step per axis (X, Y, Z). Buffers over a
//! volume hold one `f32` per position, Y fastest, then X, then Z.

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
}
