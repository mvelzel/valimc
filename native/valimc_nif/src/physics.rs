//! The entity physics kernel (VMC-077l, `valimc_core::physics`) for Elixir:
//! players call it per move packet over published chunk rows, region owners
//! once per tick for all their items.
//!
//! A view is `{:rows, rows, base, outside}` (`rows` a list of `{cx, cz,
//! sections}`, `sections` nil for the base profile or a tuple of 24 section
//! terms as `World.View` holds them; `base` 384 big-endian states; `outside`
//! the state outside the stored height) or `{:states, packed}` (supplied
//! `<<x::32, y::32, z::32, state::16>>` records, for oracles). A query only
//! decodes the sections near its boxes; a cell it cannot read answers
//! `{:error, {:unreadable, {x, y, z}}}`.
//!
//! Boxes are `{x0, y0, z0, x1, y1, z1}`, vectors `{x, y, z}`. A context is
//! `{{entity, bottom, descending, placement}, {present, fall_distance,
//! falling_block, powder_snow_walkable}}`. Extra colliders are `{entity_boxes,
//! border}` with `border` nil or the stationary border's
//! `{min_x, min_z, max_x, max_z}`.

use crate::facts::PHYSICS;
use rustler::{Atom, Binary, Encoder, Env, NifResult, Term};
use std::collections::HashMap;
use valimc_core::physics::border::Border;
use valimc_core::physics::collide::{self, Extra};
use valimc_core::physics::facts::Facts;
use valimc_core::physics::fluid::{self, Pushed};
use valimc_core::physics::item::{self, ItemBody, ItemFault};
use valimc_core::physics::response;
use valimc_core::physics::source::{BlockSource, Rows, Section, States};
use valimc_core::physics::support;
use valimc_core::physics::sweep;
use valimc_core::physics::{Aabb, Context, Unreadable};

mod atoms {
    rustler::atoms! {
        ok, error, rows, states, unreadable, inside, limit, facts_missing, invalid_view,
        dense, water, lava,
    }
}

pub(crate) type BoxT = (f64, f64, f64, f64, f64, f64);
pub(crate) type Vec3 = (f64, f64, f64);
pub(crate) type ContextT = ((bool, f64, bool, bool), (bool, f64, bool, bool));
type ExtraT = (Vec<BoxT>, Option<(f64, f64, f64, f64)>);

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

fn extra(e: ExtraT, subject: [f64; 2]) -> Extra {
    Extra {
        entities: e.0.into_iter().map(aabb).collect(),
        border: e.1.map(|(min_x, min_z, max_x, max_z)| Border {
            min_x,
            min_z,
            max_x,
            max_z,
        }),
        subject,
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

fn section<'a>(term: Term<'a>) -> NifResult<Section<'a>> {
    if let Ok(state) = term.decode::<u16>() {
        return Ok(Section::Uniform(state));
    }
    let (first, cells): (Term<'a>, Binary<'a>) = term.decode()?;
    if let Ok(tag) = first.decode::<Atom>() {
        if tag == atoms::dense() && cells.len() == 8192 {
            return Ok(Section::Dense(cells.as_slice()));
        }
        return Err(invalid());
    }
    let palette = rustler::types::tuple::get_tuple(first)?
        .into_iter()
        .map(|t| t.decode::<u16>())
        .collect::<NifResult<Vec<u16>>>()?;
    if cells.len() != 4096 {
        return Err(invalid());
    }
    Ok(Section::Paletted(palette, cells.as_slice()))
}

/// Decode a view for the heights `region` covers (two blocks of margin).
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
    if tag != atoms::rows() || tuple.len() != 4 {
        return Err(invalid());
    }
    let rows: Vec<(i32, i32, Term<'a>)> = tuple[1].decode()?;
    let base: Binary = tuple[2].decode()?;
    let outside: u16 = tuple[3].decode()?;
    let base: Vec<u16> = base
        .as_slice()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| u16::from_be_bytes(*b))
        .collect();
    let lowest = ((region.min[1] - 2.0).floor() as i32 + 64).max(0) >> 4;
    let highest = ((region.max[1] + 2.0).floor() as i32 + 64).clamp(0, 383) >> 4;
    let mut decoded = Rows::new(base, outside);
    for (cx, cz, sections) in rows {
        let row = if sections.is_atom() {
            None
        } else {
            let terms = rustler::types::tuple::get_tuple(sections)?;
            if terms.len() != 24 {
                return Err(invalid());
            }
            let mut out = Vec::with_capacity(24);
            for (s, t) in terms.into_iter().enumerate() {
                out.push(if (lowest..=highest).contains(&(s as i32)) {
                    section(t)?
                } else {
                    Section::Unloaded
                });
            }
            Some(out)
        };
        decoded.insert((cx, cz), row, &facts.shapes);
    }
    Ok(View::Rows(decoded))
}

fn unreadable<'a>(env: Env<'a>, u: Unreadable) -> Term<'a> {
    (
        atoms::error(),
        (atoms::unreadable(), (u.0[0], u.0[1], u.0[2])),
    )
        .encode(env)
}

fn ok<'a, T: Encoder>(env: Env<'a>, value: T) -> Term<'a> {
    (atoms::ok(), value).encode(env)
}

/// How a mover finds the ground for step-up.
#[derive(Clone, Copy)]
enum Ground {
    Known(bool),
    /// Physically: a downward probe of this distance meets something.
    Probe(f64),
}

fn ground(term: Term) -> NifResult<Ground> {
    if let Ok(known) = term.decode::<bool>() {
        Ok(Ground::Known(known))
    } else {
        Ok(Ground::Probe(term.decode::<f64>()?))
    }
}

/// `Entity.collide` of `body` moving `movement`, with step-up up to
/// `max_step` (0 for none): `{:ok, {actual, horizontal, vertical, below,
/// stepped}}`.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn physics_move<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    body: BoxT,
    movement: Vec3,
    ctx: ContextT,
    extra_t: ExtraT,
    max_step: f64,
    ground_t: Term<'a>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let movement = v3(movement);
    let probe = match ground(ground_t)? {
        Ground::Probe(d) => d,
        Ground::Known(_) => 0.0,
    };
    let region = body
        .expand_towards(movement)
        .expand_towards([0.0, max_step + 1.0, 0.0])
        .expand_towards([0.0, -probe - 1.0, 0.0]);
    let view = view(view_term, facts, &region)?;
    let ctx = context(ctx);
    let extra = extra(extra_t, centre(&body));
    let grounded = match ground(ground_t)? {
        Ground::Known(g) => Ok(g),
        Ground::Probe(d) => {
            let down = [0.0, -d, 0.0];
            collide::colliders(
                &view,
                &facts.shapes,
                &body.expand_towards(down),
                &ctx,
                &extra,
            )
            .map(|shapes| collide::collide_with(&body, &shapes, down)[1] != -d)
        }
    };
    let moved = grounded.and_then(|g| {
        collide::collide(
            &view,
            &facts.shapes,
            &body,
            movement,
            &ctx,
            &extra,
            max_step as f32,
            g,
        )
    });
    Ok(match moved {
        Ok(m) => ok(
            env,
            (t3(m.actual), m.horizontal, m.vertical, m.below, m.stepped),
        ),
        Err(u) => unreadable(env, u),
    })
}

fn centre(b: &Aabb) -> [f64; 2] {
    [(b.min[0] + b.max[0]) / 2.0, (b.min[2] + b.max[2]) / 2.0]
}

/// Whether each box meets a collider (blocks, entity boxes, the border):
/// `{:ok, [colliding?]}`.
#[rustler::nif]
fn physics_colliding<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    boxes: Vec<BoxT>,
    ctx: ContextT,
    extra_t: ExtraT,
    subject: (f64, f64),
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let boxes: Vec<Aabb> = boxes.into_iter().map(aabb).collect();
    let Some(region) = union(&boxes) else {
        return Ok(ok(env, Vec::<bool>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let ctx = context(ctx);
    let extra = extra(extra_t, [subject.0, subject.1]);
    let result: Result<Vec<bool>, Unreadable> = boxes
        .iter()
        .map(|b| collide::no_collision(&view, &facts.shapes, b, &ctx, &extra).map(|free| !free))
        .collect();
    Ok(match result {
        Ok(v) => ok(env, v),
        Err(u) => unreadable(env, u),
    })
}

fn union(boxes: &[Aabb]) -> Option<Aabb> {
    let first = *boxes.first()?;
    Some(boxes.iter().skip(1).fold(first, |a, b| {
        Aabb::new(
            std::array::from_fn(|i| a.min[i].min(b.min[i])),
            std::array::from_fn(|i| a.max[i].max(b.max[i])),
        )
    }))
}

/// `isEntityCollidingWithAnythingNew` between two bodies: `{:ok, new?}`.
#[rustler::nif]
fn physics_new_collision<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    old: BoxT,
    new: BoxT,
    ctx: ContextT,
    extra_t: ExtraT,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let (old, new) = (aabb(old), aabb(new));
    let view = view(view_term, facts, &union(&[old, new]).expect("two boxes"))?;
    let extra = extra(extra_t, centre(&old));
    Ok(
        match collide::new_collision(&view, &facts.shapes, &old, &new, &context(ctx), &extra) {
            Ok(v) => ok(env, v),
            Err(u) => unreadable(env, u),
        },
    )
}

/// The fluid a body touches: `{:ok, nil}` for a degenerate body, else
/// `{:ok, {water_depth, lava_depth, contacts}}` with contacts
/// `{{x, y, z}, kind, amount, height, source, falling, depth}`.
#[rustler::nif]
fn physics_fluids<'a>(env: Env<'a>, view_term: Term<'a>, body: BoxT) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let view = view(view_term, facts, &body)?;
    Ok(match fluid::contacts(&view, facts, &body) {
        Ok(None) => ok(env, rustler::types::atom::nil()),
        Ok(Some(found)) => {
            let d = fluid::depths(&found);
            let contacts: Vec<Term> = found
                .iter()
                .map(|c| {
                    (
                        (c.position[0], c.position[1], c.position[2]),
                        kind(c.fluid.kind),
                        c.fluid.amount,
                        c.fluid.height as f64,
                        (c.fluid.source, c.fluid.falling),
                        c.depth,
                    )
                        .encode(env)
                })
                .collect();
            ok(env, (d.water, d.lava, contacts))
        }
        Err(u) => unreadable(env, u),
    })
}

fn kind(k: u8) -> Atom {
    match k {
        fluid_kind::WATER => atoms::water(),
        fluid_kind::LAVA => atoms::lava(),
        _ => rustler::types::atom::nil(),
    }
}

mod fluid_kind {
    pub use valimc_core::physics::facts::{LAVA, WATER};
}

/// The eye test: `{:ok, nil | {in_water, in_lava}}`.
#[rustler::nif]
fn physics_fluid_eyes<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    body: BoxT,
    eye: Vec3,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let view = view(view_term, facts, &body)?;
    Ok(match fluid::eyes(&view, facts, &body, v3(eye)) {
        Ok(v) => ok(env, v),
        Err(u) => unreadable(env, u),
    })
}

/// Whether any cell of the body holds fluid: `{:ok, nil | boolean}`.
#[rustler::nif]
fn physics_any_liquid<'a>(env: Env<'a>, view_term: Term<'a>, body: BoxT) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let view = view(view_term, facts, &body)?;
    Ok(match fluid::any_liquid(&view, facts, &body) {
        Ok(v) => ok(env, v),
        Err(u) => unreadable(env, u),
    })
}

/// The flow of one fluid cell: `{:ok, {x, y, z}}`.
#[rustler::nif]
fn physics_flow<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    pos: (i32, i32, i32),
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let p = [pos.0, pos.1, pos.2];
    let around = Aabb::new(
        [p[0] as f64 - 1.0, p[1] as f64 - 1.0, p[2] as f64 - 1.0],
        [p[0] as f64 + 2.0, p[1] as f64 + 2.0, p[2] as f64 + 2.0],
    );
    let view = view(view_term, facts, &around)?;
    Ok(match fluid::flow(&view, facts, p) {
        Ok(v) => ok(env, t3(v)),
        Err(u) => unreadable(env, u),
    })
}

/// A body's fluid current (`pushed`: flows move it; `item`: items normalize
/// the sum): `{:ok, nil | {water_depth, lava_depth, velocity}}`.
#[rustler::nif]
fn physics_current<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    body: BoxT,
    velocity: Vec3,
    flags: (bool, bool, bool),
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let (pushed, fast_lava, item) = flags;
    let view = view(view_term, facts, &body.inflate(1.0))?;
    let kind = if item { Pushed::Item } else { Pushed::Player };
    Ok(
        match fluid::current(&view, facts, &body, v3(velocity), pushed, fast_lava, kind) {
            Ok(None) => ok(env, rustler::types::atom::nil()),
            Ok(Some((d, v))) => ok(env, (d.water, d.lava, t3(v))),
            Err(u) => unreadable(env, u),
        },
    )
}

/// The blocks a body passes moving from `from` to `to` (`body` the deflated
/// destination box), at most `stop` of them: `{:ok, {visits, complete}}` with
/// visits `{x, y, z, step}`, or `{:error, :limit}`.
#[rustler::nif]
fn physics_sweep<'a>(
    env: Env<'a>,
    from: Vec3,
    to: Vec3,
    body: BoxT,
    stop: usize,
) -> NifResult<Term<'a>> {
    Ok(match sweep::sweep(v3(from), v3(to), &aabb(body), stop) {
        Some(s) => {
            let visits: Vec<(i32, i32, i32, u32)> = s
                .visits
                .iter()
                .map(|(p, step)| (p[0], p[1], p[2], *step))
                .collect();
            ok(env, (visits, s.complete))
        }
        None => (atoms::error(), atoms::limit()).encode(env),
    })
}

/// Where a grounded body stands: the supporting block (`findSupportingBlock`
/// under its feet, or behind a horizontal `movement`), the block below that
/// decides friction and bounce (`getOnPos(0.500001F)`), the legacy landing
/// block (`getOnPos(0.2F)`) and the block at the feet: `{:ok, {support,
/// below, legacy, feet}}`, each `{{x, y, z}, state}` (support nil when none).
#[rustler::nif]
fn physics_footing<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    body: BoxT,
    position: Vec3,
    movement: Vec3,
    ctx: ContextT,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let body = aabb(body);
    let movement = v3(movement);
    let position = v3(position);
    let region = body
        .inflate(1.0)
        .expand_towards([-movement[0], 0.0, -movement[2]]);
    let view = view(view_term, facts, &region)?;
    let cell = |p: [i32; 3]| -> Result<((i32, i32, i32), u16), Unreadable> {
        let state = view.state(p[0], p[1], p[2]).ok_or(Unreadable(p))?;
        Ok(((p[0], p[1], p[2]), state))
    };
    let found = (|| {
        let support = support::supporting(&view, facts, &body, position, movement, &context(ctx))?;
        let below = support::on_pos(&view, facts, support, position, 0.500001)?;
        let legacy = support::on_pos(&view, facts, support, position, 0.2)?;
        let feet = position.map(|v| v.floor() as i32);
        Ok((
            support.map(cell).transpose()?,
            cell(below)?,
            cell(legacy)?,
            cell(feet)?,
        ))
    })();
    Ok(match found {
        Ok(f) => ok(env, f),
        Err(u) => unreadable(env, u),
    })
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

/// Whether a body moving by `movement` is inside a visited `state` at
/// `position` whose inside shape is its collision shape for `ctx` (powder
/// snow).
#[rustler::nif]
fn physics_inside_shape(
    state: u16,
    position: (i32, i32, i32),
    ctx: ContextT,
    body: BoxT,
    movement: Vec3,
) -> NifResult<bool> {
    let facts = facts()?;
    let pos = [position.0, position.1, position.2];
    Ok(collide::inside_shape(
        &facts.shapes,
        state,
        pos,
        &context(ctx),
        &aabb(body),
        v3(movement),
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

/// The velocity after a collision (`Entity.move` restitution and the
/// landing block's bounce): `{velocity, bounced}`. `collisions` is `{x, z,
/// vertical, below}`, `bounce` `{suppress, block_suppresses,
/// entity_bounciness, block_bounciness}`, `drag` `{gravity, air_drag}`.
#[rustler::nif]
fn physics_respond(
    velocity: Vec3,
    moved_y: f64,
    collisions: (bool, bool, bool, bool),
    bounce: (bool, bool, f64, f64),
    drag: (f64, f64),
) -> (Vec3, bool) {
    let (x_collision, z_collision, vertical_collision, below) = collisions;
    let (suppress_bounce, block_suppresses_bounce, entity_bounciness, block_bounciness) = bounce;
    let r = response::respond(
        v3(velocity),
        moved_y,
        &response::Response {
            x_collision,
            z_collision,
            vertical_collision,
            below,
            suppress_bounce,
            block_suppresses_bounce,
            entity_bounciness,
            block_bounciness,
            gravity: drag.0,
            air_drag: drag.1,
        },
    );
    (t3(r.velocity), r.bounced)
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
