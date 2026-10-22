//! One item tick (vanilla's `ItemEntity.tick` with `Entity.move`, without
//! block effects): fluid currents, gravity or buoyancy, collision with the
//! blocks and border, bounce, block speed and friction, then currents again.
//! Ageing and pickup delays stay with the owner.

use super::aabb::Aabb;
use super::border::Border;
use super::collide::{collide_with, colliders, scan_cells, Extra};
use super::facts::Facts;
use super::fluid::{current, Pushed};
use super::response::{respond, Response};
use super::source::{BlockSource, Unreadable};
use super::support::{motion_at, on_pos, supporting};
use super::table::Context;

#[inline]
pub(super) fn f32r(v: f64) -> f64 {
    v as f32 as f64
}

/// An item's physical state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ItemBody {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub on_ground: bool,
    pub no_gravity: bool,
}

/// Why an item could not take its step (it stays as it was).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ItemFault {
    /// Embedded in a block: vanilla pushes it out, which ValiMC leaves alone.
    Inside,
    Unreadable([i32; 3]),
    /// Velocity or position outside the item bounds.
    Limit,
}

impl From<Unreadable> for ItemFault {
    fn from(u: Unreadable) -> ItemFault {
        ItemFault::Unreadable(u.0)
    }
}

fn body(p: [f64; 3]) -> Aabb {
    Aabb {
        min: [p[0] - 0.125, p[1], p[2] - 0.125],
        max: [p[0] + 0.125, p[1] + 0.25, p[2] + 0.125],
    }
}

pub(super) fn context(bottom: f64) -> Context {
    Context {
        entity: true,
        bottom,
        entity_present: true,
        ..Context::default()
    }
}

pub(super) fn bounded(v: [f64; 3]) -> bool {
    v.iter().all(|c| c.abs() <= 64.0)
}

/// The most cells one item's movement scan reads.
pub(super) const MAX_SCAN: u64 = 1024;
const MAX_HORIZONTAL: f64 = 30_000_000.0;

pub(super) fn position_ok(p: [f64; 3]) -> bool {
    p[0].abs() <= MAX_HORIZONTAL && p[2].abs() <= MAX_HORIZONTAL && p[1].abs() <= 1_000_128.0
}

/// One tick of an item; `refresh` moves a resting grounded item anyway.
pub fn step(
    source: &dyn BlockSource,
    facts: &Facts,
    item: &ItemBody,
    refresh: bool,
    border: Option<&Border>,
) -> Result<ItemBody, ItemFault> {
    if !bounded(item.velocity) || !position_ok(item.position) {
        return Err(ItemFault::Limit);
    }
    let shapes_for = |query: &Aabb, at: [f64; 3]| {
        let extra = Extra {
            entities: Vec::new(),
            border: border.copied(),
            subject: [at[0], at[2]],
        };
        colliders(source, &facts.shapes, query, &context(at[1]), &extra)
    };
    let b = body(item.position);
    let clear = b.deflate(1.0e-7);
    if !shapes_for(&clear, item.position)?.is_empty() {
        return Err(ItemFault::Inside);
    }
    let (depths, velocity) = current(source, facts, &b, item.velocity, true, false, Pushed::Item)?
        .ok_or(ItemFault::Limit)?;
    // ItemEntity: buoyancy above 0.1F of water or lava, else gravity.
    let threshold = 0.10000000149011612;
    let fluid = if depths.water > threshold {
        Some(f32r(0.99))
    } else if depths.lava > threshold {
        Some(f32r(0.95))
    } else {
        None
    };
    let [x, y, z] = velocity;
    let next = match fluid {
        Some(drag) => {
            let rise = if y < f32r(0.06) { f32r(0.0005) } else { 0.0 };
            [x * drag, y + rise, z * drag]
        }
        None if item.no_gravity => [x, y, z],
        None => [x + 0.0, y - 0.04, z + 0.0],
    };
    if !bounded(next) {
        return Err(ItemFault::Limit);
    }
    let moves = !item.on_ground || next[0] * next[0] + next[2] * next[2] > f32r(0.00001) || refresh;
    let (position, velocity, on_ground) = if !moves {
        (item.position, next, item.on_ground)
    } else {
        let requested = next;
        let swept = b.expand_towards(requested);
        // The server's bound on one item's scan (not vanilla's).
        if scan_cells(&swept) > MAX_SCAN {
            return Err(ItemFault::Limit);
        }
        let shapes = shapes_for(&swept, item.position)?;
        let actual = collide_with(&b, &shapes, requested);
        let destination = translated(item.position, requested, actual);
        let grounded = requested[1] < 0.0 && requested[1] != actual[1];
        let dest_body = body(destination);
        let support = if grounded {
            let ctx = context(dest_body.min[1]);
            supporting(source, facts, &dest_body, destination, actual, &ctx)?
        } else {
            None
        };
        let legacy = *motion_at(
            source,
            facts,
            on_pos(source, facts, support, destination, 0.2f32)?,
        )?;
        let below = *motion_at(
            source,
            facts,
            on_pos(source, facts, support, destination, 0.999999f32)?,
        )?;
        let feet = *motion_at(source, facts, destination.map(|v| v.floor() as i32))?;
        let speed = if feet.speed_override || feet.speed_factor != 1.0 {
            feet.speed_factor
        } else {
            below.speed_factor
        } as f64;
        let response = respond(
            next,
            actual[1],
            &Response {
                x_collision: (requested[0] - actual[0]).abs() >= 9.999999747378752e-6,
                z_collision: (requested[2] - actual[2]).abs() >= 9.999999747378752e-6,
                vertical_collision: requested[1] != actual[1],
                below: grounded,
                block_bounciness: f32r(legacy.bounciness as f64 * f32r(0.8)),
                block_suppresses_bounce: legacy.suppresses_bounce,
                gravity: if item.no_gravity { 0.0 } else { 0.04 },
                ..Response::default()
            },
        );
        let [vx, vy, vz] = response.velocity;
        let air = f32r(0.98);
        let horizontal = if grounded {
            f32r(air * below.friction as f64)
        } else {
            air
        };
        let mut y = vy * air;
        if grounded && y < 0.0 {
            y *= -0.5;
        }
        let v = [vx * speed * horizontal, y, vz * speed * horizontal];
        if !position_ok(destination) {
            return Err(ItemFault::Limit);
        }
        (destination, v, grounded)
    };
    let (_, after) = current(
        source,
        facts,
        &body(position),
        velocity,
        true,
        false,
        Pushed::Item,
    )?
    .ok_or(ItemFault::Limit)?;
    if !bounded(after) {
        return Err(ItemFault::Limit);
    }
    Ok(ItemBody {
        position,
        velocity: after,
        on_ground,
        no_gravity: item.no_gravity,
    })
}

/// `Entity.move`'s position update: a movement too small to register keeps
/// the position.
pub(super) fn translated(position: [f64; 3], requested: [f64; 3], actual: [f64; 3]) -> [f64; 3] {
    let length = |v: [f64; 3]| v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if length(actual) > 1.0e-7 || length(requested) - length(actual) < 1.0e-7 {
        [
            position[0] + actual[0],
            position[1] + actual[1],
            position[2] + actual[2],
        ]
    } else {
        position
    }
}
