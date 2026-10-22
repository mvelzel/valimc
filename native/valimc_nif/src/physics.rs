//! The entity physics kernel (VMC-077l, `valimc_core::physics`) for Elixir:
//! views over published chunk rows, region owners' item ticks, placement and
//! spawn obstruction and the border; the player's calls are in `player`, the
//! oracle checks' one-by-one entry points in `physics_checks`.
//!
//! A view is `{:rows, snapshots, outside}` (`snapshots` the published chunk
//! handles `World.View` holds, VMC-077p, read in place; `outside` the state
//! outside the stored height) or `{:states, packed}` (supplied
//! `<<x::32, y::32, z::32, state::16>>` records, for oracles). A cell it
//! cannot read answers `{:error, {:unreadable, {x, y, z}}}`.
//!
//! Boxes are `{x0, y0, z0, x1, y1, z1}`, vectors `{x, y, z}`. A context is
//! `{{entity, bottom, descending, placement}, {present, fall_distance,
//! falling_block, powder_snow_walkable}}`. Extra colliders are `{entity_boxes,
//! border}` with `border` nil or the stationary border's
//! `{min_x, min_z, max_x, max_z}`.

use crate::facts::PHYSICS;
use crate::snapshot::Snapshot;
use rustler::{Atom, Binary, Encoder, Env, NifResult, Term};
use std::collections::HashMap;
use valimc_core::physics::border::Border;
use valimc_core::physics::collide;
use valimc_core::physics::facts::Facts;
use valimc_core::physics::item::{self, ItemBody, ItemFault};
use valimc_core::physics::orb::{self, OrbBody};
use valimc_core::physics::source::{BlockSource, Rows, States};
use valimc_core::physics::{Aabb, Context};

pub(crate) mod atoms {
    rustler::atoms! {
        ok, error, rows, states, unreadable, inside, limit, facts_missing, invalid_view,
        water, lava,
    }
}

pub(crate) type BoxT = (f64, f64, f64, f64, f64, f64);
pub(crate) type Vec3 = (f64, f64, f64);
pub(crate) type ContextT = ((bool, f64, bool, bool), (bool, f64, bool, bool));

pub(crate) fn aabb(b: BoxT) -> Aabb {
    Aabb::new([b.0, b.1, b.2], [b.3, b.4, b.5])
}

pub(crate) fn v3(v: Vec3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

pub(crate) fn t3(v: [f64; 3]) -> Vec3 {
    (v[0], v[1], v[2])
}

pub(crate) fn context(c: ContextT) -> Context {
    let ((entity, bottom, descending, placement), (present, fall, falling, walkable)) = c;
    Context {
        entity,
        bottom,
        descending,
        placement,
        entity_present: present,
        fall_distance: fall,
        falling_block: falling,
        powder_snow_walkable: walkable,
    }
}

pub(crate) fn facts() -> NifResult<&'static Facts> {
    PHYSICS
        .get()
        .ok_or(rustler::Error::Term(Box::new(atoms::facts_missing())))
}

fn invalid() -> rustler::Error {
    rustler::Error::Term(Box::new(atoms::invalid_view()))
}

/// A view decoded for the cells of `region` (inflated a little by callers).
pub(crate) enum View<'a> {
    Rows(Rows<'a>),
    States(States),
}

impl BlockSource for View<'_> {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        match self {
            View::Rows(r) => r.state(x, y, z),
            View::States(s) => s.state(x, y, z),
        }
    }

    fn special_near(&self, x: i32, y: i32, z: i32) -> bool {
        match self {
            View::Rows(r) => r.special_near(x, y, z),
            View::States(s) => s.special_near(x, y, z),
        }
    }
}

/// A view for the cells of `region` (two blocks of margin).
pub(crate) fn view<'a>(term: Term<'a>, facts: &Facts, region: &Aabb) -> NifResult<View<'a>> {
    let tuple = rustler::types::tuple::get_tuple(term)?;
    let tag: Atom = tuple.first().ok_or(invalid())?.decode()?;
    if tag == atoms::states() && tuple.len() == 2 {
        let packed: Binary = tuple[1].decode()?;
        let (records, rest) = packed.as_slice().as_chunks::<14>();
        if !rest.is_empty() {
            return Err(invalid());
        }
        let map = records
            .iter()
            .map(|r| {
                let at = |i: usize| i32::from_be_bytes([r[i], r[i + 1], r[i + 2], r[i + 3]]);
                ([at(0), at(4), at(8)], u16::from_be_bytes([r[12], r[13]]))
            })
            .collect::<HashMap<_, _>>();
        return Ok(View::States(States(map)));
    }
    if tag != atoms::rows() || tuple.len() != 3 {
        return Err(invalid());
    }
    let snapshots: Vec<&'a Snapshot> = tuple[1].decode()?;
    let outside: u16 = tuple[2].decode()?;
    // Special colliders are looked up in the sections near the region only.
    let lowest = ((region.min[1] - 2.0).floor() as i32 + 64).max(0) >> 4;
    let highest = ((region.max[1] + 2.0).floor() as i32 + 64).clamp(0, 383) >> 4;
    let mut rows = Rows::new(outside);
    for snapshot in snapshots {
        rows.insert(
            &snapshot.0,
            lowest as usize..=highest as usize,
            &facts.shapes,
        );
    }
    Ok(View::Rows(rows))
}

#[cfg(feature = "parity")]
pub(crate) fn unreadable<'a>(env: Env<'a>, u: valimc_core::physics::Unreadable) -> Term<'a> {
    (
        atoms::error(),
        (atoms::unreadable(), (u.0[0], u.0[1], u.0[2])),
    )
        .encode(env)
}

pub(crate) fn ok<'a, T: Encoder>(env: Env<'a>, value: T) -> Term<'a> {
    (atoms::ok(), value).encode(env)
}

pub(crate) fn union(boxes: &[Aabb]) -> Option<Aabb> {
    let first = *boxes.first()?;
    Some(boxes.iter().skip(1).fold(first, |a, b| {
        Aabb::new(
            std::array::from_fn(|i| a.min[i].min(b.min[i])),
            std::array::from_fn(|i| a.max[i].max(b.max[i])),
        )
    }))
}

/// Whether the collision shape of `state` at `position` (for `ctx`) meets
/// any of `bodies`: a placement's obstruction by entities, a spawn's.
#[rustler::nif]
fn physics_obstructs(
    state: u16,
    position: (i32, i32, i32),
    ctx: ContextT,
    bodies: Vec<BoxT>,
) -> NifResult<bool> {
    let facts = facts()?;
    let bodies: Vec<Aabb> = bodies.into_iter().map(aabb).collect();
    let pos = [position.0, position.1, position.2];
    Ok(collide::obstructs(
        &facts.shapes,
        state,
        pos,
        &context(ctx),
        &bodies,
    ))
}

/// Whether the stationary border `{min_x, min_z, max_x, max_z}` leaves `body`
/// clear for a mover at `subject` (`{x, z}`; nil: an anonymous query, which
/// the border never blocks).
#[rustler::nif]
fn physics_border_clear(
    border: (f64, f64, f64, f64),
    subject: Option<(f64, f64)>,
    body: BoxT,
) -> bool {
    let (min_x, min_z, max_x, max_z) = border;
    let border = Border {
        min_x,
        min_z,
        max_x,
        max_z,
    };
    subject.is_none_or(|(x, z)| border.collider(x, z, &aabb(body)).is_none())
}

type OrbT = (Vec3, Vec3, bool, Option<Vec3>);

/// One tick for each orb `{position, velocity, on_ground, target}`
/// (`ExperienceOrb.tick` with `Entity.move`, pulled toward `target` when it
/// follows a player): results as `physics_items`'.
#[rustler::nif]
fn physics_orbs<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    orbs: Vec<OrbT>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    orbs_step(env, view_term, orbs, border)
}

/// `physics_orbs` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_orbs_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    orbs: Vec<OrbT>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    orbs_step(env, view_term, orbs, border)
}

fn orbs_step<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    orbs: Vec<OrbT>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let bodies: Vec<(OrbBody, Option<[f64; 3]>)> = orbs
        .into_iter()
        .map(|(p, v, on_ground, target)| {
            (
                OrbBody {
                    position: v3(p),
                    velocity: v3(v),
                    on_ground,
                },
                target.map(v3),
            )
        })
        .collect();
    let Some(region) = union(
        &bodies
            .iter()
            .map(|(b, _)| {
                let p = b.position;
                Aabb::new(
                    [p[0] - 1.0, p[1] - 2.0, p[2] - 1.0],
                    [p[0] + 1.0, p[1] + 2.0, p[2] + 1.0],
                )
                .expand_towards(b.velocity)
            })
            .collect::<Vec<_>>(),
    ) else {
        return Ok(ok(env, Vec::<Term>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let border = border.map(|(min_x, min_z, max_x, max_z)| Border {
        min_x,
        min_z,
        max_x,
        max_z,
    });
    let results: Vec<Term> = bodies
        .iter()
        .map(
            |(b, target)| match orb::step(&view, facts, b, *target, border.as_ref()) {
                Ok(n) => (atoms::ok(), t3(n.position), t3(n.velocity), n.on_ground).encode(env),
                Err(ItemFault::Inside) => atoms::inside().encode(env),
                Err(ItemFault::Limit) => atoms::limit().encode(env),
                Err(ItemFault::Unreadable(p)) => {
                    (atoms::unreadable(), (p[0], p[1], p[2])).encode(env)
                }
            },
        )
        .collect();
    Ok(ok(env, results))
}

type ItemT = (Vec3, Vec3, bool, bool);

/// One tick for each item (`ItemEntity.tick` with `Entity.move`, refreshing
/// resting items when `refresh`): `{:ok, results}` in input order, each
/// `{:ok, position, velocity, on_ground}`, `:inside`, `{:unreadable, pos}` or
/// `:limit` (the item keeps its state).
#[rustler::nif]
fn physics_items<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    items: Vec<ItemT>,
    border: Option<(f64, f64, f64, f64)>,
    refresh: bool,
) -> NifResult<Term<'a>> {
    items_step(env, view_term, items, border, refresh)
}

/// `physics_items` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_items_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    items: Vec<ItemT>,
    border: Option<(f64, f64, f64, f64)>,
    refresh: bool,
) -> NifResult<Term<'a>> {
    items_step(env, view_term, items, border, refresh)
}

fn items_step<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    items: Vec<ItemT>,
    border: Option<(f64, f64, f64, f64)>,
    refresh: bool,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let bodies: Vec<ItemBody> = items
        .into_iter()
        .map(|(p, v, on_ground, no_gravity)| ItemBody {
            position: v3(p),
            velocity: v3(v),
            on_ground,
            no_gravity,
        })
        .collect();
    let Some(region) = union(
        &bodies
            .iter()
            .map(|b| {
                let p = b.position;
                Aabb::new(
                    [p[0] - 1.0, p[1] - 2.0, p[2] - 1.0],
                    [p[0] + 1.0, p[1] + 2.0, p[2] + 1.0],
                )
                .expand_towards(b.velocity)
            })
            .collect::<Vec<_>>(),
    ) else {
        return Ok(ok(env, Vec::<Term>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let border = border.map(|(min_x, min_z, max_x, max_z)| Border {
        min_x,
        min_z,
        max_x,
        max_z,
    });
    let results: Vec<Term> = bodies
        .iter()
        .map(
            |b| match item::step(&view, facts, b, refresh, border.as_ref()) {
                Ok(n) => (atoms::ok(), t3(n.position), t3(n.velocity), n.on_ground).encode(env),
                Err(ItemFault::Inside) => atoms::inside().encode(env),
                Err(ItemFault::Limit) => atoms::limit().encode(env),
                Err(ItemFault::Unreadable(p)) => {
                    (atoms::unreadable(), (p[0], p[1], p[2])).encode(env)
                }
            },
        )
        .collect();
    Ok(ok(env, results))
}
