//! `LivingEntity.hasLineOfSight` (`World.line_of_sight?/2`): a ray from eye
//! to eye through collision shapes (`ClipContext.Block.COLLIDER`, no fluid),
//! at most 128 blocks, cast by `physics::ray::clip` as `Valimc.Physics.Clip`
//! casts it: an unreadable cell is air, and the shapes that depend on the
//! colliding entity or a block entity read as vanilla gives a mob beside
//! them (`Clip.collider/2`): scaffolding, powder snow and moving pistons
//! empty, shulker boxes closed.

use crate::mobs::level::Level;
use crate::physics::ray;
use crate::physics::source::{BlockSource, AIR};
use crate::physics::table::{Context, Entry};

/// The cells a mob's ray reads.
struct Sight<'a, 'b>(&'a Level<'b>);

impl BlockSource for Sight<'_, '_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        let state = self.0.block([x, y, z]).unwrap_or(AIR);
        let table = &self.0.physics.shapes;
        let entry = table
            .states
            .get(state as usize)
            .and_then(|&e| table.entries.get(e as usize));
        Some(match entry {
            Some(Entry::Scaffolding | Entry::PowderSnow | Entry::MovingPiston) => AIR,
            _ => state,
        })
    }
}

/// Whether nothing blocks a ray from `from` to `to` (both eyes).
pub fn line_of_sight(level: &Level, from: [f64; 3], to: [f64; 3]) -> bool {
    let d = [to[0] - from[0], to[1] - from[1], to[2] - from[2]];
    if (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt() > 128.0 {
        return false;
    }
    clear(level, from, to)
}

/// Whether nothing blocks a ray from `from` to `to`, however far
/// (`Clip.clip(from, to, :none, read, :collider).miss`: the dragon's sight).
pub fn clear(level: &Level, from: [f64; 3], to: [f64; 3]) -> bool {
    match ray::clip(&Sight(level), level.physics, from, to, &Context::default()) {
        Ok(hit) => hit.miss,
        // The source reads every cell.
        Err(_) => false,
    }
}
