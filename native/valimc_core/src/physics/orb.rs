//! One experience orb tick (vanilla's `ExperienceOrb.tick` with
//! `Entity.move`, without block effects or merging): fluid currents, water
//! drag or gravity, the pull toward the player it follows, collision with the
//! blocks and border, block speed and friction, and the bounce off the ground.
//! Choosing the player, ageing and pickup stay with the owner.

use super::aabb::Aabb;
use super::border::Border;
use super::collide::{collide_with, colliders, scan_cells, Extra};
use super::facts::Facts;
use super::fluid::{current, normalize, Pushed};
use super::item::{bounded, context, f32r, position_ok, translated, ItemFault, MAX_SCAN};
use super::response::{respond, Response};
use super::source::BlockSource;
use super::support::{motion_at, on_pos, supporting};

/// An orb's physical state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OrbBody {
    pub position: [f64; 3],
    pub velocity: [f64; 3],
    pub on_ground: bool,
}

const GRAVITY: f64 = 0.03;
/// `EntityType.EXPERIENCE_ORB`'s eye: 0.85 of its 0.5 height.
const EYE: f64 = 0.425;
/// The distance at which an orb stops following a player (`followNearbyPlayer`).
pub const FOLLOW_RANGE: f64 = 8.0;

fn body(p: [f64; 3]) -> Aabb {
    Aabb {
        min: [p[0] - 0.25, p[1], p[2] - 0.25],
        max: [p[0] + 0.25, p[1] + 0.5, p[2] + 0.25],
    }
}

/// One tick of an orb pulled toward `target` (the followed player's position
/// at half its eye height), if it follows one.
pub fn step(
    source: &dyn BlockSource,
    facts: &Facts,
    orb: &OrbBody,
    target: Option<[f64; 3]>,
    border: Option<&Border>,
) -> Result<OrbBody, ItemFault> {
    if !bounded(orb.velocity) || !position_ok(orb.position) {
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
    let b = body(orb.position);
    let inside = !shapes_for(&b.deflate(1.0e-7), orb.position)?.is_empty();
    // `Entity.baseTick`: the currents push every entity, normalized for all but players.
    let (depths, velocity) = current(source, facts, &b, orb.velocity, true, false, Pushed::Item)?
        .ok_or(ItemFault::Limit)?;
    let [x, y, z] = velocity;
    let mut v = if depths.water > EYE {
        // `setUnderwaterMovement`.
        let rise = if y < f32r(0.06) { f32r(5.0e-4) } else { 0.0 };
        [x * f32r(0.99), y + rise, z * f32r(0.99)]
    } else if !inside {
        [x, y - GRAVITY, z]
    } else {
        [x, y, z]
    };
    match target {
        Some(t) => {
            let to = [
                t[0] - orb.position[0],
                t[1] - orb.position[1],
                t[2] - orb.position[2],
            ];
            let length = (to[0] * to[0] + to[1] * to[1] + to[2] * to[2]).sqrt();
            let e = 1.0 - length / FOLLOW_RANGE;
            let pull = normalize(to).map(|c| c * (e * e * 0.1));
            v = [v[0] + pull[0], v[1] + pull[1], v[2] + pull[2]];
        }
        // Vanilla moves an embedded orb toward the closest space; ValiMC leaves it.
        None if inside => return Err(ItemFault::Inside),
        None => {}
    }
    if !bounded(v) {
        return Err(ItemFault::Limit);
    }
    let fall = v[1];
    let swept = b.expand_towards(v);
    if scan_cells(&swept) > MAX_SCAN {
        return Err(ItemFault::Limit);
    }
    let shapes = shapes_for(&swept, orb.position)?;
    let actual = collide_with(&b, &shapes, v);
    let destination = translated(orb.position, v, actual);
    let grounded = v[1] < 0.0 && v[1] != actual[1];
    let dest_body = body(destination);
    let support = if grounded {
        supporting(
            source,
            facts,
            &dest_body,
            destination,
            actual,
            &context(dest_body.min[1]),
        )?
    } else {
        None
    };
    let legacy = *motion_at(
        source,
        facts,
        on_pos(source, facts, support, destination, 0.2f32)?,
    )?;
    // `getBlockPosBelowThatAffectsMyMovement`, overridden at 0.999999F.
    let below = *motion_at(
        source,
        facts,
        on_pos(source, facts, support, destination, 0.999999f32)?,
    )?;
    let feet = *motion_at(source, facts, destination.map(|c| c.floor() as i32))?;
    let speed = if feet.speed_override || feet.speed_factor != 1.0 {
        feet.speed_factor
    } else {
        below.speed_factor
    } as f64;
    let response = respond(
        v,
        actual[1],
        &Response {
            x_collision: (v[0] - actual[0]).abs() >= 9.999999747378752e-6,
            z_collision: (v[2] - actual[2]).abs() >= 9.999999747378752e-6,
            vertical_collision: v[1] != actual[1],
            below: grounded,
            block_bounciness: f32r(legacy.bounciness as f64 * f32r(0.8)),
            block_suppresses_bounce: legacy.suppresses_bounce,
            gravity: GRAVITY,
            ..Response::default()
        },
    );
    let [rx, ry, rz] = response.velocity;
    // `getAirDrag` 0.98F, times the friction of the block below on the ground.
    let drag = if grounded {
        (0.98f32 * below.friction) as f64
    } else {
        0.98f32 as f64
    };
    let mut next = [rx * speed * drag, ry * drag, rz * speed * drag];
    if grounded && fall < -GRAVITY {
        next[1] = -fall * 0.4;
    }
    if !position_ok(destination) || !bounded(next) {
        return Err(ItemFault::Limit);
    }
    Ok(OrbBody {
        position: destination,
        velocity: next,
        on_ground: grounded,
    })
}
