//! Axis-aligned boxes in world coordinates (vanilla's `AABB`), doubles.

/// A box: `min` and `max` corners, `min <= max` on every axis.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Aabb {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl Aabb {
    /// The box spanning two corners in any order.
    pub fn new(a: [f64; 3], b: [f64; 3]) -> Aabb {
        Aabb {
            min: [a[0].min(b[0]), a[1].min(b[1]), a[2].min(b[2])],
            max: [a[0].max(b[0]), a[1].max(b[1]), a[2].max(b[2])],
        }
    }

    pub fn from_array(v: [f64; 6]) -> Aabb {
        Aabb::new([v[0], v[1], v[2]], [v[3], v[4], v[5]])
    }

    pub fn to_array(self) -> [f64; 6] {
        [
            self.min[0],
            self.min[1],
            self.min[2],
            self.max[0],
            self.max[1],
            self.max[2],
        ]
    }

    /// The unit cube of a block position.
    pub fn block(x: i32, y: i32, z: i32) -> Aabb {
        let (x, y, z) = (x as f64, y as f64, z as f64);
        Aabb {
            min: [x, y, z],
            max: [x + 1.0, y + 1.0, z + 1.0],
        }
    }

    pub fn moved(&self, d: [f64; 3]) -> Aabb {
        Aabb::new(
            [self.min[0] + d[0], self.min[1] + d[1], self.min[2] + d[2]],
            [self.max[0] + d[0], self.max[1] + d[1], self.max[2] + d[2]],
        )
    }

    /// `expandTowards`: grow toward a movement on each axis.
    pub fn expand_towards(&self, d: [f64; 3]) -> Aabb {
        let mut min = self.min;
        let mut max = self.max;
        for a in 0..3 {
            if d[a] < 0.0 {
                min[a] += d[a];
            } else if d[a] > 0.0 {
                max[a] += d[a];
            }
        }
        Aabb::new(min, max)
    }

    /// `deflate`: shrink by `e` on every side.
    pub fn deflate(&self, e: f64) -> Aabb {
        Aabb::new(
            [self.min[0] + e, self.min[1] + e, self.min[2] + e],
            [self.max[0] - e, self.max[1] - e, self.max[2] - e],
        )
    }

    /// `inflate`: grow by `e` on every side.
    pub fn inflate(&self, e: f64) -> Aabb {
        self.deflate(-e)
    }

    /// `intersects`: a strictly positive overlap on every axis.
    pub fn intersects(&self, o: &Aabb) -> bool {
        self.min[0] < o.max[0]
            && self.max[0] > o.min[0]
            && self.min[1] < o.max[1]
            && self.max[1] > o.min[1]
            && self.min[2] < o.max[2]
            && self.max[2] > o.min[2]
    }

    pub fn size(&self, axis: usize) -> f64 {
        self.max[axis] - self.min[axis]
    }

    /// `clip`: where the segment `from -> to` first enters the box (strictly
    /// after `from`), or `None`.
    pub fn clip(&self, from: [f64; 3], to: [f64; 3]) -> Option<[f64; 3]> {
        const EPSILON: f64 = 1.0e-7;
        let delta = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
        let mut best: Option<f64> = None;
        for axis in 0..3 {
            let d = delta[axis];
            if d.abs() <= EPSILON {
                continue;
            }
            let plane = if d < 0.0 {
                self.max[axis]
            } else {
                self.min[axis]
            };
            let t = (plane - from[axis]) / d;
            if t > 0.0 && t < best.unwrap_or(1.0) {
                let inside = (0..3).all(|i| {
                    let p = from[i] + t * delta[i];
                    i == axis || (p > self.min[i] - EPSILON && p < self.max[i] + EPSILON)
                });
                if inside {
                    best = Some(t);
                }
            }
        }
        best.map(|t| {
            [
                from[0] + t * delta[0],
                from[1] + t * delta[1],
                from[2] + t * delta[2],
            ]
        })
    }
}
