//! The kernel's entry points one by one for the oracle checks
//! (`scripts/check_*.exs` through `Valimc.Physics.Kernel`), built only with
//! the `parity` feature: movement, new collisions, fluids, eyes,
//! flow and currents, body sweeps, footing, inside shapes and restitution.
//! Live play uses the batched item, player and mob calls; collision queries
//! and the initial mob fluid and eye samples are live (`physics.rs`).

use crate::physics::{
    aabb, atoms, context, extra, facts, ok, t3, union, unreadable, v3, view, BoxT, ContextT,
    ExtraT, Vec3,
};
use rustler::{Encoder, Env, NifResult, Term};
use valimc_core::physics::collide;
use valimc_core::physics::fluid::{self, Pushed};
use valimc_core::physics::response;
use valimc_core::physics::source::BlockSource;
use valimc_core::physics::support;
use valimc_core::physics::sweep;
use valimc_core::physics::{Aabb, Unreadable};

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
