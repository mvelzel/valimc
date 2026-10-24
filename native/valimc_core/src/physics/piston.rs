//! Entities moved by moving pistons (VMC-048b), as a tick of vanilla's
//! `PistonMovingBlockEntity` moves them: the entities the block's shape
//! sweeps through are pushed out ahead of it (`moveCollidedEntities`, a
//! slime block also flinging them), entities standing on a honey block
//! moving sideways ride it (`moveStuckEntities`), and each push is an
//! `Entity.move` with the piston mover: at most 0.51 per axis per tick
//! (`limitPistonMovement`), blocks moving that way passed through
//! (`NOCLIP`), then the move's collisions, ground and restitution.

use super::aabb::Aabb;
use super::border::Border;
use super::collide::{collide, Extra};
use super::facts::Facts;
use super::join::boxes;
use super::response::{respond, Response};
use super::source::{BlockSource, Unreadable};
use super::support::{motion_at, on_pos, supporting};
use super::table::Context;
use crate::piston::Moving;
use crate::rules::STEP;

/// A body a moving block may push.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PushBody {
    /// Feet position.
    pub position: [f64; 3],
    pub half_width: f64,
    pub height: f64,
    pub velocity: [f64; 3],
    pub on_ground: bool,
    /// `maxUpStep`.
    pub step: f32,
    /// `canSimulateMovement` (including players in the pinned server).
    pub simulates: bool,
    /// `isLocalInstanceAuthoritative`: updates ground state even on a horizontal move.
    pub authoritative: bool,
    /// `getPistonPushReaction`: `IGNORE_ENTITY`, or `PUSH_PULL` (which
    /// honey carries).
    pub ignored: bool,
    /// `getEntityBounciness` and `isSuppressingBounce`.
    pub bounciness: f64,
    pub suppress_bounce: bool,
    /// A living body takes a block's bounciness whole, others 0.8 of it
    /// (`getBlockBounciness`).
    pub living: bool,
    /// `getEffectiveGravity` and `getAirDrag`, which a bounce reads.
    pub gravity: f64,
    pub air_drag: f64,
    /// Whether a push moved it.
    pub pushed: bool,
}

impl PushBody {
    pub fn aabb(&self) -> Aabb {
        let [x, y, z] = self.position;
        Aabb {
            min: [x - self.half_width, y, z - self.half_width],
            max: [x + self.half_width, y + self.height, z + self.half_width],
        }
    }
}

pub use crate::rules::piston::Push;

/// The states pushes tell apart: slime (bounce) and honey (sticky).
#[derive(Clone, Copy, Debug)]
pub struct PushStates {
    pub slime: u16,
    pub honey: u16,
}

fn axis_step(d: usize) -> [f64; 3] {
    STEP[d].map(|v| v as f64)
}

/// `PistonMath.getMovementArea`.
fn movement_area(b: &Aabb, d: usize, amount: f64) -> Aabb {
    let positive = STEP[d].iter().sum::<i32>() > 0;
    let delta = if positive { amount } else { -amount };
    let (lo, hi) = (delta.min(0.0), delta.max(0.0));
    let axis = d / 2;
    let axis = [1, 2, 0][axis];
    let mut out = *b;
    let edge = if positive { b.max[axis] } else { b.min[axis] };
    out.min[axis] = edge + lo;
    out.max[axis] = edge + hi;
    out
}

/// `getMovement`: how far `b` must move along `d` to clear `outside`.
fn movement(outside: &Aabb, d: usize, b: &Aabb) -> f64 {
    match d {
        5 => outside.max[0] - b.min[0],
        4 => b.max[0] - outside.min[0],
        0 => b.max[1] - outside.min[1],
        3 => outside.max[2] - b.min[2],
        2 => b.max[2] - outside.min[2],
        _ => outside.max[1] - b.min[1],
    }
}

/// `AABB.intersect`.
fn intersect(a: &Aabb, b: &Aabb) -> Aabb {
    Aabb {
        min: std::array::from_fn(|i| a.min[i].max(b.min[i])),
        max: std::array::from_fn(|i| a.max[i].min(b.max[i])),
    }
}

/// `AABB.minmax`.
fn minmax(a: &Aabb, b: &Aabb) -> Aabb {
    Aabb {
        min: std::array::from_fn(|i| a.min[i].min(b.min[i])),
        max: std::array::from_fn(|i| a.max[i].max(b.max[i])),
    }
}

/// What a tick's pushes read: the blocks, the facts, the border and the
/// states pushes tell apart.
pub struct World<'a> {
    pub source: &'a dyn BlockSource,
    pub facts: &'a Facts,
    pub border: Option<&'a Border>,
    pub states: PushStates,
}

/// Apply a tick's moving-block ticks `pushes`, in order, to `bodies` (in
/// the order the level lists them), over the world `world.source` holds
/// after them all: while one pushes, it and the blocks after it in the
/// order stand as they were. A body a push cannot read past keeps where
/// that push left it.
pub fn push_all(world: &World, pushes: &[Push], bodies: &mut [PushBody]) {
    let mut before = Before {
        after: world.source,
        cells: pushes
            .iter()
            .map(|p| (p.pos, (p.state, p.moving)))
            .collect(),
    };
    // `pistonDeltas`: what pistons moved each body along each axis this tick.
    let mut deltas = vec![[0.0f64; 3]; bodies.len()];
    for push in pushes {
        if !push.landed {
            let at = World {
                source: &before,
                facts: world.facts,
                border: world.border,
                states: world.states,
            };
            let _ = collided(&at, push, bodies, &mut deltas);
            let _ = stuck(&at, push, bodies, &mut deltas);
        }
        before.cells.remove(&push.pos);
    }
}

/// The world while a moving block pushes: the cells of the blocks yet to
/// tick as they were, the rest after the tick.
struct Before<'a> {
    after: &'a dyn BlockSource,
    cells: std::collections::HashMap<[i32; 3], (u16, Moving)>,
}

impl BlockSource for Before<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        match self.cells.get(&[x, y, z]) {
            Some(&(state, _)) => Some(state),
            None => self.after.state(x, y, z),
        }
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        !self.cells.is_empty() || self.after.special_near(x, y, z)
    }

    fn moving(&self, x: i32, y: i32, z: i32) -> Option<Moving> {
        match self.cells.get(&[x, y, z]) {
            Some(&(_, moving)) => Some(moving),
            None => self.after.moving(x, y, z),
        }
    }
}

/// `getCollisionRelatedBlockState`: a retracting base's head (short past a
/// quarter), else the carried block.
fn related_state(world: &World, m: &Moving) -> u16 {
    let table = &world.facts.shapes;
    if !m.extending && m.source {
        if let Some(&(_, sticky, facing)) = table.piston_bases.get(&m.moved) {
            return table
                .piston_head(sticky, m.progress > 0.25, facing)
                .unwrap_or(m.moved);
        }
    }
    m.moved
}

/// `moveByPositionAndProgress`.
fn placed(b: &Aabb, pos: [i32; 3], m: &Moving) -> Aabb {
    let current = m.extended_progress(m.progress) as f64;
    let step = axis_step(m.direction as usize);
    b.moved(std::array::from_fn(|i| pos[i] as f64 + current * step[i]))
}

/// `moveCollidedEntities`.
fn collided(
    world: &World,
    push: &Push,
    bodies: &mut [PushBody],
    deltas: &mut [[f64; 3]],
) -> Result<(), Unreadable> {
    let m = &push.moving;
    let direction = m.movement();
    let delta_progress = (push.progress - m.progress) as f64;
    let table = &world.facts.shapes;
    let picked = table.shape(related_state(world, m), push.pos, &Context::default());
    let Some(bounds) = picked.shape.bounds() else {
        return Ok(());
    };
    let offset = picked.offset;
    let local: Vec<Aabb> = boxes(picked.shape)
        .into_iter()
        .map(|b| b.moved(offset))
        .collect();
    let aabb = placed(&bounds.moved(offset), push.pos, m);
    let area = minmax(&movement_area(&aabb, direction, delta_progress), &aabb);
    let bounce = m.moved == world.states.slime;
    let hit: Vec<usize> = (0..bodies.len())
        .filter(|&i| bodies[i].aabb().intersects(&area))
        .collect();
    for i in hit {
        if bodies[i].ignored {
            continue;
        }
        if bounce && bodies[i].simulates {
            let axis = [1, 1, 2, 2, 0, 0][direction];
            bodies[i].velocity[axis] = axis_step(direction)[axis];
        }
        let mut delta = 0.0f64;
        for b in &local {
            let moving = movement_area(&placed(b, push.pos, m), direction, delta_progress);
            let entity = bodies[i].aabb();
            if moving.intersects(&entity) {
                delta = delta.max(movement(&moving, direction, &entity));
                if delta >= delta_progress {
                    break;
                }
            }
        }
        if delta > 0.0 {
            let delta = delta.min(delta_progress) + 0.01;
            by_piston(
                world,
                &mut bodies[i],
                &mut deltas[i],
                direction,
                delta,
                direction,
            )?;
            if !m.extending && m.source {
                within_base(
                    world,
                    push.pos,
                    &mut bodies[i],
                    &mut deltas[i],
                    direction,
                    delta_progress,
                )?;
            }
        }
    }
    Ok(())
}

/// `fixEntityWithinPistonBase`.
fn within_base(
    world: &World,
    pos: [i32; 3],
    body: &mut PushBody,
    deltas: &mut [f64; 3],
    direction: usize,
    delta_progress: f64,
) -> Result<(), Unreadable> {
    let entity = body.aabb();
    let block = Aabb::block(pos[0], pos[1], pos[2]);
    if !entity.intersects(&block) {
        return Ok(());
    }
    let opposite = direction ^ 1;
    let delta = movement(&block, opposite, &entity) + 0.01;
    let intersected = movement(&block, opposite, &intersect(&entity, &block)) + 0.01;
    if (delta - intersected).abs() < 0.01 {
        let delta = delta.min(delta_progress) + 0.01;
        by_piston(world, body, deltas, direction, delta, opposite)?;
    }
    Ok(())
}

/// `moveStuckEntities`: a honey block moving sideways carries what stands
/// on it.
fn stuck(
    world: &World,
    push: &Push,
    bodies: &mut [PushBody],
    deltas: &mut [[f64; 3]],
) -> Result<(), Unreadable> {
    let m = &push.moving;
    if m.moved != world.states.honey {
        return Ok(());
    }
    let direction = m.movement();
    if direction < 2 {
        return Ok(());
    }
    let table = &world.facts.shapes;
    let picked = table.shape(m.moved, push.pos, &Context::default());
    let top = picked
        .shape
        .bounds()
        .map_or(f64::NEG_INFINITY, |b| b.max[1] + picked.offset[1]);
    let aabb = placed(
        &Aabb {
            min: [0.0, top, 0.0],
            max: [1.0, 1.5000010000000001, 1.0],
        },
        push.pos,
        m,
    );
    let delta_progress = (push.progress - m.progress) as f64;
    let mut riders = Vec::new();
    for (i, body) in bodies.iter().enumerate() {
        let b = body.aabb();
        if !b.intersects(&aabb) || body.ignored || !body.on_ground {
            continue;
        }
        let [x, _, z] = body.position;
        let over = x >= aabb.min[0] && x <= aabb.max[0] && z >= aabb.min[2] && z <= aabb.max[2];
        if over || supported_by(world, body, push.pos)? {
            riders.push(i);
        }
    }
    for i in riders {
        by_piston(
            world,
            &mut bodies[i],
            &mut deltas[i],
            direction,
            delta_progress,
            direction,
        )?;
    }
    Ok(())
}

/// `isSupportedBy`: its supporting block is `pos`.
fn supported_by(world: &World, body: &PushBody, pos: [i32; 3]) -> Result<bool, Unreadable> {
    let b = body.aabb();
    let ctx = context(b.min[1]);
    Ok(supporting(world.source, world.facts, &b, body.position, [0.0; 3], &ctx)? == Some(pos))
}

fn context(bottom: f64) -> Context {
    Context {
        entity: true,
        bottom,
        entity_present: true,
        ..Context::default()
    }
}

/// `moveEntityByPiston`: an `Entity.move` with the piston mover along
/// `movement` by `delta`, blocks moving toward `noclip` passed through.
fn by_piston(
    world: &World,
    body: &mut PushBody,
    deltas: &mut [f64; 3],
    noclip: usize,
    delta: f64,
    movement: usize,
) -> Result<(), Unreadable> {
    let step = axis_step(movement);
    let requested = limit(deltas, [delta * step[0], delta * step[1], delta * step[2]]);
    if requested == [0.0; 3] {
        return Ok(());
    }
    let mut ctx = context(body.aabb().min[1]);
    ctx.noclip = Some(noclip as u8);
    let view = super::player::World {
        source: world.source,
        facts: world.facts,
        border: world.border.copied(),
        entities: &[],
    };
    displace(&view, body, requested, ctx)
}

/// An external `Entity.move`: shared collision and response for pistons and lids.
/// The caller supplies mover-specific filtering, limits and shape context.
pub fn displace(
    world: &super::player::World,
    body: &mut PushBody,
    requested: [f64; 3],
    mut ctx: Context,
) -> Result<(), Unreadable> {
    let b = body.aabb();
    ctx.bottom = b.min[1];
    let extra = Extra {
        entities: world.entities.to_vec(),
        border: world.border,
        subject: [body.position[0], body.position[2]],
    };
    let moved = collide(
        world.source,
        &world.facts.shapes,
        &b,
        requested,
        &ctx,
        &extra,
        body.step,
        body.on_ground,
    )?;
    let actual = moved.actual;
    let destination = super::item::translated(body.position, requested, actual);
    let equal = |a: f64, b: f64| (b - a).abs() < 9.999999747378752e-6;
    let x_collision = !equal(requested[0], actual[0]);
    let z_collision = !equal(requested[2], actual[2]);
    let horizontal = x_collision || z_collision;
    let moved_vertically = requested[1].abs() > 0.0;
    let mut vertical = false;
    let mut below = false;
    if moved_vertically || body.authoritative {
        vertical = requested[1] != actual[1];
        below = vertical && requested[1] < 0.0;
        body.on_ground = below;
    }
    body.position = destination;
    body.pushed = true;
    let after = body.aabb();
    let support = if body.on_ground {
        supporting(
            world.source,
            world.facts,
            &after,
            destination,
            actual,
            &context(after.min[1]),
        )?
    } else {
        None
    };
    if body.simulates && (moved_vertically && vertical || horizontal) {
        let legacy = *motion_at(
            world.source,
            world.facts,
            on_pos(world.source, world.facts, support, destination, 0.2f32)?,
        )?;
        let block_bounciness = if body.living {
            legacy.bounciness as f64
        } else {
            (legacy.bounciness * 0.8f32) as f64
        };
        let response = respond(
            body.velocity,
            actual[1],
            &Response {
                x_collision,
                z_collision,
                vertical_collision: vertical,
                below,
                suppress_bounce: body.suppress_bounce,
                block_suppresses_bounce: legacy.suppresses_bounce,
                entity_bounciness: body.bounciness,
                block_bounciness,
                gravity: body.gravity,
                air_drag: body.air_drag,
            },
        );
        body.velocity = response.velocity;
    }
    // `getBlockSpeedFactor`: the block at the feet, else the one below.
    let feet = *motion_at(
        world.source,
        world.facts,
        destination.map(|v| v.floor() as i32),
    )?;
    let under = *motion_at(
        world.source,
        world.facts,
        on_pos(world.source, world.facts, support, destination, 0.500001f32)?,
    )?;
    let speed = if feet.speed_override || feet.speed_factor != 1.0 {
        feet.speed_factor
    } else {
        under.speed_factor
    } as f64;
    body.velocity = [
        body.velocity[0] * speed,
        body.velocity[1],
        body.velocity[2] * speed,
    ];
    Ok(())
}

/// `limitPistonMovement`: along its one axis a move adds to what pistons
/// moved the body this tick, which stays within 0.51 either way.
fn limit(deltas: &mut [f64; 3], v: [f64; 3]) -> [f64; 3] {
    if v[0] * v[0] + v[1] * v[1] + v[2] * v[2] <= 1.0e-7 {
        return v;
    }
    let axis = if v[0] != 0.0 {
        0
    } else if v[1] != 0.0 {
        1
    } else if v[2] != 0.0 {
        2
    } else {
        return [0.0; 3];
    };
    let result = (v[axis] + deltas[axis]).clamp(-0.51, 0.51);
    let amount = result - deltas[axis];
    deltas[axis] = result;
    if amount.abs() <= 9.999999747378752e-6 {
        return [0.0; 3];
    }
    let mut out = [0.0; 3];
    out[axis] = amount;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pistons_move_a_body_at_most_half_a_block_a_tick_per_axis() {
        let mut deltas = [0.0; 3];
        assert_eq!(limit(&mut deltas, [0.0, 0.3, 0.0]), [0.0, 0.3, 0.0]);
        let second = limit(&mut deltas, [0.0, 0.3, 0.0]);
        assert!((second[1] - 0.21).abs() < 1.0e-12);
        assert_eq!(limit(&mut deltas, [0.0, 0.3, 0.0]), [0.0; 3]);
        assert_eq!(limit(&mut deltas, [-0.2, 0.0, 0.0]), [-0.2, 0.0, 0.0]);
    }

    #[test]
    fn a_movement_area_is_the_swept_face() {
        let b = Aabb {
            min: [0.0, 0.0, 0.0],
            max: [1.0, 1.0, 1.0],
        };
        let up = movement_area(&b, 1, 0.5);
        assert_eq!((up.min[1], up.max[1]), (1.0, 1.5));
        let west = movement_area(&b, 4, 0.5);
        assert_eq!((west.min[0], west.max[0]), (-0.5, 0.0));
    }
}
