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
use valimc_core::physics::block_body;
use valimc_core::physics::border::Border;
use valimc_core::physics::collide;
use valimc_core::physics::explosion;
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
/// `StrictMath.sin` and `cos` of `x` (vanilla's `Math` with the oracles'
/// flags), for the AI's random look directions (VMC-041a).
#[rustler::nif]
fn physics_sin_cos(x: f64) -> (f64, f64) {
    (
        valimc_core::worldgen::java::sin(x),
        valimc_core::worldgen::java::cos(x),
    )
}

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

type OrbT = (Vec3, Vec3, bool, Option<Vec3>, (u32, u32, u32, u32));

/// One tick for each orb `{position, velocity, on_ground, target, draws}`
/// (`ExperienceOrb.tick` with `Entity.move`, pulled toward `target` when it
/// follows a player; `draws` are the jump in lava's four 24-bit float draws):
/// results as `physics_items`'.
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
    let bodies: Vec<(OrbBody, Option<[f64; 3]>, [u32; 4])> = orbs
        .into_iter()
        .map(|(p, v, on_ground, target, (a, b, c, d))| {
            (
                OrbBody {
                    position: v3(p),
                    velocity: v3(v),
                    on_ground,
                },
                target.map(v3),
                [a, b, c, d],
            )
        })
        .collect();
    let Some(region) = union(
        &bodies
            .iter()
            .map(|(b, _, _)| {
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
        .map(|(b, target, draws)| {
            match orb::step(&view, facts, b, *target, *draws, border.as_ref()) {
                Ok(n) => (atoms::ok(), t3(n.position), t3(n.velocity), n.on_ground).encode(env),
                Err(ItemFault::Inside) => atoms::inside().encode(env),
                Err(ItemFault::Limit) => atoms::limit().encode(env),
                Err(ItemFault::Unreadable(p)) => {
                    (atoms::unreadable(), (p[0], p[1], p[2])).encode(env)
                }
            }
        })
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

// ---- mobs (VMC-015i) ----

mod mob_atoms {
    rustler::atoms! { wait, move_to, jumping }
}

/// A mob as its owner keeps it (`Valimc.Entity.MobMotion`): position, yaw
/// and head yaw, motion and its flags, the relative input and speed, the
/// move control `{operation, target, speed}`, its size `{width, height,
/// eye}`, the travel attributes `{movement_speed, jump_strength, gravity,
/// step_height, water_efficiency, friction_modifier, air_drag_modifier}` and
/// its travel effects.
#[derive(rustler::NifMap)]
struct MobT {
    position: Vec3,
    yaw: f64,
    head_yaw: f64,
    velocity: Vec3,
    on_ground: bool,
    horizontal_collision: bool,
    fall_distance: f64,
    no_jump_delay: i32,
    stuck_multiplier: Vec3,
    strafe: f64,
    forward: f64,
    speed: f64,
    control: (Atom, Option<Vec3>, f64),
    size: Vec3,
    attributes: (f64, f64, f64, f64, f64, f64, f64),
    no_gravity: bool,
    slow_falling: bool,
    levitation: Option<i32>,
    jump_boost: i32,
    alive: bool,
    jump: bool,
}

/// A mob's tick: the mob after it and what its living rules read.
#[derive(rustler::NifMap)]
struct TickedT {
    mob: MobT,
    water: bool,
    lava: bool,
    eye_water: bool,
    eye_state: u16,
    landing: Option<(u16, f64)>,
    fire_contacts: crate::player::FiresT,
    climbing: bool,
    /// The water and lava heights the move left.
    depths: (f64, f64),
}

fn mob(m: &MobT) -> NifResult<valimc_core::physics::mob::Mob> {
    use valimc_core::physics::mob::{Attributes, Control, Mob};
    let (op, target, speed) = m.control;
    let control = if op == mob_atoms::wait() {
        Control::Wait
    } else if op == mob_atoms::move_to() {
        Control::MoveTo {
            target: v3(target.ok_or(rustler::Error::BadArg)?),
            speed,
        }
    } else if op == mob_atoms::jumping() {
        Control::Jumping { speed }
    } else {
        return Err(rustler::Error::BadArg);
    };
    let a = m.attributes;
    Ok(Mob {
        position: v3(m.position),
        yaw: m.yaw as f32,
        head_yaw: m.head_yaw as f32,
        velocity: v3(m.velocity),
        on_ground: m.on_ground,
        horizontal_collision: m.horizontal_collision,
        fall_distance: m.fall_distance,
        no_jump_delay: m.no_jump_delay,
        stuck_multiplier: v3(m.stuck_multiplier),
        strafe: m.strafe as f32,
        forward: m.forward as f32,
        speed: m.speed as f32,
        control,
        size: valimc_core::physics::player::pose::Dimensions {
            width: m.size.0,
            height: m.size.1,
            eye: m.size.2,
        },
        attributes: Attributes {
            movement_speed: a.0,
            jump_strength: a.1,
            gravity: a.2,
            step_height: a.3,
            water_efficiency: a.4,
            friction_modifier: a.5,
            air_drag_modifier: a.6,
        },
        no_gravity: m.no_gravity,
        slow_falling: m.slow_falling,
        levitation: m.levitation,
        jump_boost: m.jump_boost,
        alive: m.alive,
        jump: m.jump,
    })
}

fn mob_t(m: &valimc_core::physics::mob::Mob) -> MobT {
    use valimc_core::physics::mob::Control;
    let a = &m.attributes;
    let control = match m.control {
        Control::Wait => (mob_atoms::wait(), None, 0.0),
        Control::MoveTo { target, speed } => (mob_atoms::move_to(), Some(t3(target)), speed),
        Control::Jumping { speed } => (mob_atoms::jumping(), None, speed),
    };
    MobT {
        position: t3(m.position),
        yaw: m.yaw as f64,
        head_yaw: m.head_yaw as f64,
        velocity: t3(m.velocity),
        on_ground: m.on_ground,
        horizontal_collision: m.horizontal_collision,
        fall_distance: m.fall_distance,
        no_jump_delay: m.no_jump_delay,
        stuck_multiplier: t3(m.stuck_multiplier),
        strafe: m.strafe as f64,
        forward: m.forward as f64,
        speed: m.speed as f64,
        control,
        size: (m.size.width, m.size.height, m.size.eye),
        attributes: (
            a.movement_speed,
            a.jump_strength,
            a.gravity,
            a.step_height,
            a.water_efficiency,
            a.friction_modifier,
            a.air_drag_modifier,
        ),
        no_gravity: m.no_gravity,
        slow_falling: m.slow_falling,
        levitation: m.levitation,
        jump_boost: m.jump_boost,
        alive: m.alive,
        jump: m.jump,
    }
}

/// One tick of every mob of an owner, in order (`LivingEntity.aiStep` and
/// `pushEntities`; `players` are `{feet, box}` that push the mobs they
/// touch): `{:ok, results}` in input order, each `{:ok, ticked}` or `{:error,
/// reason}` (that mob keeps its state).
#[rustler::nif]
fn physics_mobs<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    mobs_step(env, view_term, mobs, players, border)
}

/// `physics_mobs` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_mobs_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    mobs_step(env, view_term, mobs, players, border)
}

fn mobs_step<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let bodies = mobs.iter().map(mob).collect::<NifResult<Vec<_>>>()?;
    let Some(region) = union(
        &bodies
            .iter()
            .map(|m| {
                let p = m.position;
                let half = m.size.width / 2.0 + 2.0;
                Aabb::new(
                    [p[0] - half, p[1] - 2.0, p[2] - half],
                    [p[0] + half, p[1] + m.size.height + 2.0, p[2] + half],
                )
                .expand_towards(m.velocity)
            })
            .collect::<Vec<_>>(),
    ) else {
        return Ok(ok(env, Vec::<Term>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let world = valimc_core::physics::player::World {
        source: &view,
        facts,
        border: crate::player::border(border),
    };
    let players: Vec<([f64; 3], Aabb)> =
        players.into_iter().map(|(f, b)| (v3(f), aabb(b))).collect();
    let results: Vec<Term> = valimc_core::physics::mob::tick_all(&world, &bodies, &players)
        .iter()
        .map(|r| match r {
            Ok(t) => ok(
                env,
                TickedT {
                    mob: mob_t(&t.mob),
                    water: t.water,
                    lava: t.lava,
                    eye_water: t.eye_water,
                    eye_state: t.eye_state,
                    landing: t.landing,
                    fire_contacts: crate::player::fires(&t.touched),
                    climbing: t.climbing,
                    depths: (t.depths.water, t.depths.lava),
                },
            ),
            Err(f) => crate::player::fault(env, *f),
        })
        .collect();
    Ok(ok(env, results))
}

/// An explosion's reach (VMC-050a, `ServerExplosion.calculateExplodedPositions`):
/// `{:ok, {cells, unreadable}}` with the cells its rays reach (sorted, as
/// `{{x, y, z}, state}`, air included) and
/// whether a ray stopped at a cell the view cannot read. `seed` seeds the
/// `LegacyRandomSource` its rays draw from; the world spans `min_y` and
/// `height` cells. Always dirty: about 30,000 cell reads at radius 4.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_explosion<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    center: Vec3,
    radius: f64,
    seed: i64,
    min_y: i32,
    height: i32,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let c = v3(center);
    // A ray reaches at most radius × 1.3 / 0.225 steps of 0.3 blocks.
    let reach = radius * 1.3 / 0.225 * 0.3 + 2.0;
    let region = Aabb::new(
        [c[0] - reach, c[1] - reach, c[2] - reach],
        [c[0] + reach, c[1] + reach, c[2] + reach],
    );
    let view = view(view_term, facts, &region)?;
    let mut random = valimc_core::worldgen::random::Random::legacy(seed);
    let found = explosion::exploded(
        &view,
        facts,
        c,
        radius as f32,
        &mut random,
        explosion::Height { min_y, height },
    );
    let cells: Vec<((i32, i32, i32), u16)> = found
        .cells
        .iter()
        .map(|(p, s)| ((p[0], p[1], p[2]), *s))
        .collect();
    Ok(ok(env, (cells, found.unreadable)))
}

/// How much of each body sees an explosion's centre
/// (`ServerExplosion.getSeenPercent`): `{:ok, [exposure]}` in body order.
#[rustler::nif]
fn physics_exposure<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    center: Vec3,
    bodies: Vec<BoxT>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let c = v3(center);
    let boxes: Vec<Aabb> = bodies.into_iter().map(aabb).collect();
    let mut all = boxes.clone();
    all.push(Aabb::new(c, c));
    let Some(region) = union(&all) else {
        return Ok(ok(env, Vec::<f64>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let seen: Vec<f64> = boxes
        .iter()
        .map(|b| explosion::seen(&view, facts, c, b) as f64)
        .collect();
    Ok(ok(env, seen))
}

/// `{position, velocity, on_ground, no_gravity, kind}`, kind `:tnt` or
/// `:falling_block`.
type BlockBodyT<'a> = (Vec3, Vec3, bool, bool, Atom);

mod kinds {
    rustler::atoms! { tnt, falling_block }
}

/// One tick for each primed TNT or falling block (VMC-050a): `{:ok,
/// results}` in input order, each `{:ok, position, velocity, on_ground,
/// moved_y}`, `{:unreadable, pos}` or `:limit` (the body keeps its state).
#[rustler::nif]
fn physics_block_bodies<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    bodies: Vec<BlockBodyT<'a>>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    block_bodies_step(env, view_term, bodies, border)
}

/// `physics_block_bodies` for batches past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_block_bodies_dirty<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    bodies: Vec<BlockBodyT<'a>>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    block_bodies_step(env, view_term, bodies, border)
}

fn block_bodies_step<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    bodies: Vec<BlockBodyT<'a>>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let mut inputs = Vec::with_capacity(bodies.len());
    for (p, v, on_ground, no_gravity, kind) in bodies {
        let kind = if kind == kinds::tnt() {
            block_body::Kind::Tnt
        } else if kind == kinds::falling_block() {
            block_body::Kind::FallingBlock
        } else {
            return Err(rustler::Error::BadArg);
        };
        let body = block_body::BlockBody {
            position: v3(p),
            velocity: v3(v),
            on_ground,
            no_gravity,
        };
        inputs.push((body, kind));
    }
    let Some(region) = union(
        &inputs
            .iter()
            .map(|(b, _)| {
                let p = b.position;
                Aabb::new(
                    [p[0] - 1.5, p[1] - 2.0, p[2] - 1.5],
                    [p[0] + 1.5, p[1] + 3.0, p[2] + 1.5],
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
    let results: Vec<Term> = inputs
        .iter()
        .map(
            |(b, kind)| match block_body::step(&view, facts, b, *kind, border.as_ref()) {
                Ok(s) => (
                    atoms::ok(),
                    t3(s.body.position),
                    t3(s.body.velocity),
                    s.body.on_ground,
                    s.moved_y,
                )
                    .encode(env),
                Err(ItemFault::Limit) | Err(ItemFault::Inside) => atoms::limit().encode(env),
                Err(ItemFault::Unreadable(p)) => {
                    (atoms::unreadable(), (p[0], p[1], p[2])).encode(env)
                }
            },
        )
        .collect();
    Ok(ok(env, results))
}
