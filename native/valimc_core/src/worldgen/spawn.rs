//! The shared spawn's origin (VMC-027d), vanilla's `NoiseSpawnFinder`: the
//! block column whose quart sample best fits the noise settings' spawn target,
//! biased towards the world origin, found by two radial searches.

use super::compiler::Worldgen;
use super::sampler::Context;

const MAX_RADIUS: i64 = 2048;

impl Worldgen {
    /// The spawn origin `(x, z)` in blocks, or `None` without a spawn target
    /// (vanilla's chunk generator then uses chunk 0, 0).
    pub fn spawn_origin(&mut self) -> Result<Option<(i32, i32)>, String> {
        let target = self.settings().spawn_target.clone();
        if target.is_empty() {
            return Ok(None);
        }
        let mut points = Vec::with_capacity(target.len());
        for point in &target {
            let mut parameters = Vec::with_capacity(point.len());
            for (function, min, max) in point {
                parameters.push((self.sampler(function)?, *min, *max));
            }
            points.push(parameters);
        }
        let mut ctx = Context::cached();
        let mut fitness = |x: i32, z: i32| -> i64 {
            // The quart's corner, as `QuartPos.toBlock(QuartPos.fromBlock(x))`.
            let (qx, qz) = ((x >> 2) << 2, (z >> 2) << 2);
            let best = points
                .iter()
                .map(|parameters| {
                    parameters
                        .iter()
                        .map(|(sampler, min, max)| {
                            let value = (sampler.value(&mut ctx, qx, 0, qz) * 10000.0f32) as i64;
                            let above = value - max;
                            let distance = if above > 0 {
                                above
                            } else {
                                (min - value).max(0)
                            };
                            distance.wrapping_mul(distance)
                        })
                        .fold(0i64, i64::wrapping_add)
                })
                .min()
                .unwrap_or(i64::MAX);
            let bias = (x as i64) * (x as i64) + (z as i64) * (z as i64);
            best.wrapping_mul(MAX_RADIUS * MAX_RADIUS)
                .wrapping_add(bias)
        };
        let mut best = ((0, 0), fitness(0, 0));
        for (max_radius, increment) in [(2048.0f32, 512.0f32), (512.0, 32.0)] {
            let origin = best.0;
            let mut angle = 0.0f32;
            let mut radius = increment;
            while radius <= max_radius {
                let x = origin.0 + (super::java::sin(angle as f64) * radius as f64) as i32;
                let z = origin.1 + (super::java::cos(angle as f64) * radius as f64) as i32;
                let candidate = fitness(x, z);
                if candidate < best.1 {
                    best = ((x, z), candidate);
                }
                angle += increment / radius;
                if angle as f64 > std::f64::consts::PI * 2.0 {
                    angle = 0.0;
                    radius += increment;
                }
            }
        }
        Ok(Some(best.0))
    }
}
