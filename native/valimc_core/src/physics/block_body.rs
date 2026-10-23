//! One tick of a block-like body (VMC-050a): a primed TNT (`PrimedTnt.tick`)
//! or a falling block (`FallingBlockEntity.tick`), 0.98 blocks wide and tall.
//! Both fall with gravity 0.04, move with `Entity.move` (collision with the
//! blocks and border, restitution, block speed) and lose 2% to air drag; a
//! TNT on the ground also slows to 0.7 and rebounds at half its speed. Fuses,
//! landing and drops stay with the owner. Block effects and fluid pushing
//! are not applied.

use super::aabb::Aabb;
use super::border::Border;
use super::collide::{collide_with, colliders, scan_cells, Extra};
use super::facts::Facts;
use super::item::{bounded, context, f32r, position_ok, translated, ItemFault, MAX_SCAN};
use super::response::{respond, Response};
use super::source::BlockSource;
use super::support::{motion_at, on_pos, supporting};

/// Which body's tick ends the step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Tnt,
    FallingBlock,
}

/// A block-like body's physical state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlockBody {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub on_ground: bool,
    pub no_gravity: bool,
}

/// A step's result: the body and how far it moved down (for fall distance).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stepped {
    pub body: BlockBody,
    pub moved_y: f64,
}

// `EntityDimensions.makeBoundingBox`: the float half width and height, widened.
const HALF: f64 = 0.49f32 as f64;
const HEIGHT: f64 = 0.98f32 as f64;

fn shape(p: [f64; 3]) -> Aabb {
    Aabb {
        min: [p[0] - HALF, p[1], p[2] - HALF],
        max: [p[0] + HALF, p[1] + HEIGHT, p[2] + HALF],
    }
}

/// One tick of `body` of `kind`.
pub fn step(
    source: &dyn BlockSource,
    facts: &Facts,
    body: &BlockBody,
    kind: Kind,
    border: Option<&Border>,
) -> Result<Stepped, ItemFault> {
    if !bounded(body.velocity) || !position_ok(body.position) {
        return Err(ItemFault::Limit);
    }
    let gravity = if body.no_gravity { 0.0 } else { 0.04 };
    let [x, y, z] = body.velocity;
    let requested = [x, y - gravity, z];
    let b = shape(body.position);
    let swept = b.expand_towards(requested);
    // The server's bound on one body's scan (not vanilla's).
    if scan_cells(&swept) > MAX_SCAN {
        return Err(ItemFault::Limit);
    }
    let extra = Extra {
        entities: Vec::new(),
        border: border.copied(),
        subject: [body.position[0], body.position[2]],
    };
    let shapes = colliders(
        source,
        &facts.shapes,
        &swept,
        &context(body.position[1]),
        &extra,
    )?;
    let actual = collide_with(&b, &shapes, requested);
    let position = translated(body.position, requested, actual);
    let vertical = requested[1] != actual[1];
    let grounded = vertical && requested[1] < 0.0;
    let moved = shape(position);
    let support = if grounded {
        let ctx = context(moved.min[1]);
        supporting(source, facts, &moved, position, actual, &ctx)?
    } else {
        None
    };
    let legacy = *motion_at(
        source,
        facts,
        on_pos(source, facts, support, position, 0.2f32)?,
    )?;
    // `getBlockPosBelowThatAffectsMyMovement` (items read 0.999999 below).
    let below = *motion_at(
        source,
        facts,
        on_pos(source, facts, support, position, 0.500001f32)?,
    )?;
    let feet = *motion_at(source, facts, position.map(|v| v.floor() as i32))?;
    let speed = if feet.speed_override || feet.speed_factor != 1.0 {
        feet.speed_factor
    } else {
        below.speed_factor
    } as f64;
    let response = respond(
        requested,
        actual[1],
        &Response {
            x_collision: (requested[0] - actual[0]).abs() >= 9.999999747378752e-6,
            z_collision: (requested[2] - actual[2]).abs() >= 9.999999747378752e-6,
            vertical_collision: vertical,
            below: grounded,
            block_bounciness: f32r(legacy.bounciness as f64 * f32r(0.8)),
            block_suppresses_bounce: legacy.suppresses_bounce,
            gravity,
            ..Response::default()
        },
    );
    let [vx, vy, vz] = response.velocity;
    let drag = f32r(0.98);
    let mut v = [vx * speed * drag, vy * drag, vz * speed * drag];
    if kind == Kind::Tnt && grounded {
        v = [v[0] * 0.7, v[1] * -0.5, v[2] * 0.7];
    }
    if !bounded(v) || !position_ok(position) {
        return Err(ItemFault::Limit);
    }
    Ok(Stepped {
        body: BlockBody {
            position,
            velocity: v,
            on_ground: grounded,
            no_gravity: body.no_gravity,
        },
        moved_y: actual[1],
    })
}
