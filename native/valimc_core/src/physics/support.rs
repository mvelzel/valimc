//! The block an entity stands on (vanilla's `findSupportingBlock` and
//! `getOnPos`): the collider under its feet nearest its position, and the
//! block below that decides friction, bounce and speed.

use super::aabb::Aabb;
use super::collide::for_block_colliders;
use super::facts::{Facts, Motion};
use super::source::{BlockSource, Unreadable};
use super::table::Context;

/// `fences` (flag bit 47).
pub const FENCE: u64 = 1 << 47;

/// The block collider position under `test` nearest `position`'s centre
/// distance, ties to the greater position (Y, then Z, then X).
pub fn nearest(
    source: &dyn BlockSource,
    facts: &Facts,
    test: &Aabb,
    position: [f64; 3],
    ctx: &Context,
) -> Result<Option<[i32; 3]>, Unreadable> {
    let mut best: Option<([i32; 3], f64)> = None;
    for_block_colliders(source, &facts.shapes, test, ctx, &mut |c| {
        let p = c.place.position.unwrap_or([0.0; 3]).map(|v| v as i32);
        let d: f64 = (0..3)
            .map(|i| {
                let v = p[i] as f64 + 0.5 - position[i];
                v * v
            })
            .sum();
        let better = match best {
            None => true,
            Some((q, bd)) => d < bd || (d == bd && (p[1], p[2], p[0]) > (q[1], q[2], q[0])),
        };
        if better {
            best = Some((p, d));
        }
    })?;
    Ok(best.map(|(p, _)| p))
}

/// `checkSupportingBlock` for a grounded body: the thin slab under its feet,
/// or that slab moved back by the horizontal movement when it finds nothing
/// (a zero movement finds nothing again).
pub fn supporting(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &Aabb,
    position: [f64; 3],
    movement: [f64; 3],
    ctx: &Context,
) -> Result<Option<[i32; 3]>, Unreadable> {
    let thin = Aabb {
        min: [body.min[0], body.min[1] - 1.0e-6, body.min[2]],
        max: [body.max[0], body.min[1], body.max[2]],
    };
    let found = nearest(source, facts, &thin, position, ctx)?;
    if found.is_some() || movement[0] == 0.0 && movement[2] == 0.0 {
        return Ok(found);
    }
    nearest(
        source,
        facts,
        &thin.moved([-movement[0], 0.0, -movement[2]]),
        position,
        ctx,
    )
}

/// `getOnPos(offset)`: the support itself when it holds its Y (walls, fence
/// gates, and fences for small offsets), else the block `offset` below the
/// position in the support's column (or the position's own column without
/// a support).
pub fn on_pos(
    source: &dyn BlockSource,
    facts: &Facts,
    support: Option<[i32; 3]>,
    position: [f64; 3],
    offset: f32,
) -> Result<[i32; 3], Unreadable> {
    let y = (position[1] - offset as f64).floor() as i32;
    match support {
        None => Ok([position[0].floor() as i32, y, position[2].floor() as i32]),
        Some(p) => {
            let state = source.state(p[0], p[1], p[2]).ok_or(Unreadable(p))?;
            let holds = facts.motion(state).support_holds_y
                || (offset as f64 <= 0.5 && facts.flags(state) & FENCE != 0);
            Ok(if holds { p } else { [p[0], y, p[2]] })
        }
    }
}

/// The movement facts of the block at a position.
pub fn motion_at<'f>(
    source: &dyn BlockSource,
    facts: &'f Facts,
    p: [i32; 3],
) -> Result<&'f Motion, Unreadable> {
    let state = source.state(p[0], p[1], p[2]).ok_or(Unreadable(p))?;
    Ok(facts.motion(state))
}
