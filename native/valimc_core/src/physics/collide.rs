//! Block colliders and movement against them: vanilla's `BlockCollisions`
//! scan, `Shapes.collide` per axis in `Direction.axisStepOrder`, and
//! `Entity.collide` with step-up.

use super::aabb::Aabb;
use super::border::Border;
use super::shape::{box_shape, Place, VoxelShape, EPSILON};
use super::source::{BlockSource, Unreadable};
use super::table::{Context, ShapeTable, LARGE, MOVING_PISTON};
use std::borrow::Cow;

/// A collider: a block-local shape and where it is placed.
#[derive(Clone, Debug)]
pub struct Collider<'a> {
    pub shape: Cow<'a, VoxelShape>,
    pub place: Place,
}

impl Collider<'_> {
    pub fn collide(&self, axis: usize, body: &Aabb, delta: f64) -> f64 {
        self.shape.collide(&self.place, axis, body, delta)
    }

    /// The world Y coordinates of the shape's grid.
    pub fn ys(&self) -> impl Iterator<Item = f64> + '_ {
        self.shape.axes[1].iter().map(|&y| self.place.coord(1, y))
    }
}

/// Vanilla's scan box: every cell of `body` plus a one-block halo, in
/// `Cursor3D` order (x fastest, then y, then z), with each cell's halo type
/// (how many of its coordinates lie on the halo).
/// The cells a block scan of `body` reads, its halo included.
pub fn scan_cells(body: &Aabb) -> u64 {
    let (lo, hi) = scan_range(body);
    (0..3)
        .map(|a| (hi[a] as i64 - lo[a] as i64 + 1) as u64)
        .product()
}

fn scan_range(body: &Aabb) -> ([i32; 3], [i32; 3]) {
    let lo = std::array::from_fn(|a| (body.min[a] - EPSILON).floor() as i32 - 1);
    let hi = std::array::from_fn(|a| (body.max[a] + EPSILON).floor() as i32 + 1);
    (lo, hi)
}

/// The block colliders `body` meets, in scan order: cells inside the box,
/// halo cells with a large collision shape (one halo coordinate) or a moving
/// piston (two). A cell the source cannot read fails the scan.
pub fn block_colliders<'t>(
    source: &dyn BlockSource,
    table: &'t ShapeTable,
    body: &Aabb,
    ctx: &Context,
) -> Result<Vec<Collider<'t>>, Unreadable> {
    let (lo, hi) = scan_range(body);
    let query = box_shape(body);
    let mut out = Vec::new();
    for z in lo[2]..=hi[2] {
        for y in lo[1]..=hi[1] {
            for x in lo[0]..=hi[0] {
                let halo = (x == lo[0] || x == hi[0]) as u8
                    + (y == lo[1] || y == hi[1]) as u8
                    + (z == lo[2] || z == hi[2]) as u8;
                if halo == 3 {
                    continue;
                }
                if halo > 0 && !source.special_near(x, y, z) {
                    // No large shape or moving piston in this section (Moonrise).
                    continue;
                }
                let state = source.state(x, y, z).ok_or(Unreadable([x, y, z]))?;
                let special = table.special(state);
                if (halo == 1 && special & LARGE == 0)
                    || (halo == 2 && special & MOVING_PISTON == 0)
                {
                    continue;
                }
                let picked = table.shape(state, [x, y, z], ctx);
                let place = Place {
                    offset: (picked.offset != [0.0; 3]).then_some(picked.offset),
                    position: Some([x as f64, y as f64, z as f64]),
                };
                let hit = if picked.shape.full_block && picked.offset == [0.0; 3] {
                    body.intersects(&Aabb::block(x, y, z))
                } else {
                    picked.shape.intersects(&place, &query, &Place::ORIGIN)
                };
                if hit {
                    out.push(Collider {
                        shape: Cow::Borrowed(picked.shape),
                        place,
                    });
                }
            }
        }
    }
    Ok(out)
}

/// `Shapes.collide`: the colliders clip a movement along one axis in order.
pub fn clip(axis: usize, body: &Aabb, colliders: &[Collider], mut delta: f64) -> f64 {
    for c in colliders {
        if delta.abs() < EPSILON {
            return 0.0;
        }
        delta = c.collide(axis, body, delta);
    }
    delta
}

/// `Entity.collideWithShapes`: Y first, then X and Z, the larger one last.
pub fn collide_with(body: &Aabb, colliders: &[Collider], movement: [f64; 3]) -> [f64; 3] {
    if colliders.is_empty() {
        return movement;
    }
    let order = if movement[0].abs() < movement[2].abs() {
        [1, 2, 0]
    } else {
        [1, 0, 2]
    };
    let mut actual = [0.0; 3];
    for axis in order {
        if movement[axis] != 0.0 {
            actual[axis] = clip(axis, &body.moved(actual), colliders, movement[axis]);
        }
    }
    actual
}

/// What else collides besides blocks: entity boxes and the world border.
#[derive(Clone, Debug, Default)]
pub struct Extra {
    pub entities: Vec<Aabb>,
    pub border: Option<Border>,
    /// The mover's horizontal position (the border's closeness test).
    pub subject: [f64; 2],
}

impl Extra {
    fn colliders(&self, query: &Aabb) -> Vec<Collider<'static>> {
        let mut out: Vec<Collider<'static>> = self
            .entities
            .iter()
            .filter(|b| b.intersects(&query.inflate(EPSILON)))
            .map(|b| Collider {
                shape: Cow::Owned(box_shape(b)),
                place: Place::ORIGIN,
            })
            .collect();
        if let Some(shape) = self
            .border
            .as_ref()
            .and_then(|b| b.collider(self.subject[0], self.subject[1], query))
        {
            out.push(Collider {
                shape: Cow::Owned(shape),
                place: Place::ORIGIN,
            });
        }
        out
    }
}

/// `collectColliders`: entities, the border, then blocks.
pub fn colliders<'t>(
    source: &dyn BlockSource,
    table: &'t ShapeTable,
    query: &Aabb,
    ctx: &Context,
    extra: &Extra,
) -> Result<Vec<Collider<'t>>, Unreadable> {
    let mut out = extra.colliders(query);
    out.extend(block_colliders(source, table, query, ctx)?);
    Ok(out)
}

/// What a move asked for and what it got.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Moved {
    pub actual: [f64; 3],
    pub horizontal: bool,
    pub vertical: bool,
    /// Vertical collision while moving down (`verticalCollisionBelow`).
    pub below: bool,
    pub stepped: bool,
    /// The step-up query, when the move tried to step.
    pub step_query: Option<Aabb>,
}

/// `Entity.collide`: the movement `body` may make, with step-up up to
/// `max_step` when grounded (or landing) and blocked horizontally.
#[allow(clippy::too_many_arguments)]
pub fn collide(
    source: &dyn BlockSource,
    table: &ShapeTable,
    body: &Aabb,
    movement: [f64; 3],
    ctx: &Context,
    extra: &Extra,
    max_step: f32,
    on_ground: bool,
) -> Result<Moved, Unreadable> {
    collide_by(
        &mut |query| colliders(source, table, query, ctx, extra),
        body,
        movement,
        max_step,
        on_ground,
    )
}

/// `Entity.collide` over any collider source (`colliders_for` answers a
/// query box: the movement's, then the step-up's).
pub fn collide_by<'t>(
    colliders_for: &mut dyn FnMut(&Aabb) -> Result<Vec<Collider<'t>>, Unreadable>,
    body: &Aabb,
    movement: [f64; 3],
    max_step: f32,
    on_ground: bool,
) -> Result<Moved, Unreadable> {
    let base = if movement[0] * movement[0] + movement[1] * movement[1] + movement[2] * movement[2]
        == 0.0
    {
        movement
    } else {
        let shapes = colliders_for(&body.expand_towards(movement))?;
        collide_with(body, &shapes, movement)
    };
    let x = movement[0] != base[0];
    let y = movement[1] != base[1];
    let z = movement[2] != base[2];
    let landing = y && movement[1] < 0.0;
    let mut result = base;
    let mut stepped = false;
    let mut step_query = None;
    if max_step > 0.0 && (landing || on_ground) && (x || z) {
        let grounded = if landing {
            body.moved([0.0, base[1], 0.0])
        } else {
            *body
        };
        let mut query = grounded.expand_towards([movement[0], max_step as f64, movement[2]]);
        if !landing {
            query = query.expand_towards([0.0, -1.0e-5f32 as f64, 0.0]);
        }
        step_query = Some(query);
        let shapes = colliders_for(&query)?;
        let skip = base[1] as f32;
        for height in step_heights(&grounded, &shapes, max_step, skip) {
            let step = collide_with(
                &grounded,
                &shapes,
                [movement[0], height as f64, movement[2]],
            );
            if step[0] * step[0] + step[2] * step[2] > base[0] * base[0] + base[2] * base[2] {
                let down = body.min[1] - grounded.min[1];
                result = [step[0], step[1] - down, step[2]];
                stepped = true;
                break;
            }
        }
    }
    Ok(Moved {
        actual: result,
        horizontal: movement[0] != result[0] || movement[2] != result[2],
        vertical: movement[1] != result[1],
        below: movement[1] != result[1] && movement[1] < 0.0,
        stepped,
        step_query,
    })
}

/// `collectCandidateStepUpHeights`: the colliders' Y coordinates above the
/// box's bottom up to `max_step`, as floats, without `skip`, sorted.
pub fn step_heights(body: &Aabb, colliders: &[Collider], max_step: f32, skip: f32) -> Vec<f32> {
    let mut found: Vec<f32> = Vec::with_capacity(4);
    for c in colliders {
        for y in c.ys() {
            let relative = (y - body.min[1]) as f32;
            if relative < 0.0 || relative == skip {
                continue;
            }
            if relative > max_step {
                break;
            }
            if !found.iter().any(|f| f.to_bits() == relative.to_bits()) {
                found.push(relative);
            }
        }
    }
    found.sort_by(|a, b| a.total_cmp(b));
    found
}

/// Whether `body` meets nothing: no block collider, entity box or border
/// (vanilla's `CollisionGetter.noCollision`).
pub fn no_collision(
    source: &dyn BlockSource,
    table: &ShapeTable,
    body: &Aabb,
    ctx: &Context,
    extra: &Extra,
) -> Result<bool, Unreadable> {
    if !extra.colliders(body).is_empty() {
        return Ok(false);
    }
    Ok(block_colliders(source, table, body, ctx)?.is_empty())
}

/// `isEntityCollidingWithAnythingNew`: whether a collider of the new body
/// (deflated by 1e-5F) lies outside the old body (deflated the same way).
pub fn new_collision(
    source: &dyn BlockSource,
    table: &ShapeTable,
    old: &Aabb,
    new: &Aabb,
    ctx: &Context,
    extra: &Extra,
) -> Result<bool, Unreadable> {
    let e = 9.999999747378752e-6;
    let previous = box_shape(&old.deflate(e));
    let found = colliders(source, table, &new.deflate(e), ctx, extra)?;
    Ok(found
        .iter()
        .any(|c| !c.shape.intersects(&c.place, &previous, &Place::ORIGIN)))
}

/// Whether `state` placed at `pos` meets any of `bodies` (vanilla's
/// `isUnobstructed` per entity: `joinIsNotEmpty(shape.move(pos), box, AND)`).
pub fn obstructs(
    table: &ShapeTable,
    state: u16,
    pos: [i32; 3],
    ctx: &Context,
    bodies: &[Aabb],
) -> bool {
    let picked = table.shape(state, pos, ctx);
    if picked.shape.is_empty() {
        return false;
    }
    let place = Place {
        offset: (picked.offset != [0.0; 3]).then_some(picked.offset),
        position: Some(pos.map(|v| v as f64)),
    };
    bodies.iter().any(|b| {
        picked
            .shape
            .intersects(&place, &box_shape(b), &Place::ORIGIN)
    })
}

/// Whether a body moving by `movement` is inside a visited `state` at `pos`
/// whose inside shape is its collision shape for `ctx` (powder snow): an
/// empty or full shape always is; otherwise its cells are tested along the
/// movement.
pub fn inside_shape(
    table: &ShapeTable,
    state: u16,
    pos: [i32; 3],
    ctx: &Context,
    body: &Aabb,
    movement: [f64; 3],
) -> bool {
    let picked = table.shape(state, pos, ctx);
    if picked.shape.is_empty() || picked.shape.full_block {
        return true;
    }
    let place = Place {
        offset: (picked.offset != [0.0; 3]).then_some(picked.offset),
        position: Some(pos.map(|v| v as f64)),
    };
    let boxes: Vec<Aabb> = picked
        .shape
        .cells()
        .iter()
        .map(|c| Aabb {
            min: std::array::from_fn(|a| place.coord(a, c.min[a])),
            max: std::array::from_fn(|a| place.coord(a, c.max[a])),
        })
        .collect();
    super::sweep::collided_along(body, movement, &boxes)
}
