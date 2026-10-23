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
use valimc_core::physics::collide::{self, Extra};
use valimc_core::physics::explosion;
use valimc_core::physics::facts::Facts;
use valimc_core::physics::item::{self, ItemBody, ItemFault};
use valimc_core::physics::orb::{self, OrbBody};
use valimc_core::physics::source::{BlockSource, Rows, States};
use valimc_core::physics::{Aabb, Context, Unreadable};

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
        noclip: None,
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
pub(crate) enum View<S> {
    Rows(Rows<S>),
    States(States),
}

impl<S: std::ops::Deref<Target = valimc_core::snapshot::ChunkSnapshot>> BlockSource for View<S> {
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

    fn moving(&self, x: i32, y: i32, z: i32) -> Option<valimc_core::piston::Moving> {
        match self {
            View::Rows(r) => r.moving(x, y, z),
            View::States(_) => None,
        }
    }
}

/// A view for the cells of `region` (two blocks of margin).
pub(crate) fn view<'a>(
    term: Term<'a>,
    facts: &Facts,
    region: &Aabb,
) -> NifResult<View<&'a valimc_core::snapshot::ChunkSnapshot>> {
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
    let snapshots: Vec<&'a valimc_core::snapshot::ChunkSnapshot> =
        snapshots.into_iter().map(|s| &s.0).collect();
    // Special colliders are looked up in the sections near the region only.
    let lowest = ((region.min[1] - 2.0).floor() as i32 + 64).max(0) >> 4;
    let highest = ((region.max[1] + 2.0).floor() as i32 + 64).clamp(0, 383) >> 4;
    let mut rows = Rows::new(outside);
    for snapshot in snapshots {
        rows.insert(snapshot, lowest as usize..=highest as usize, &facts.shapes);
    }
    Ok(View::Rows(rows))
}

pub(crate) fn unreadable<'a>(env: Env<'a>, u: Unreadable) -> Term<'a> {
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

pub(crate) type ExtraT = (Vec<BoxT>, Option<(f64, f64, f64, f64)>);

pub(crate) fn extra(e: ExtraT, subject: [f64; 2]) -> Extra {
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

/// Whether each box meets a collider (blocks, entity boxes, the border):
/// `{:ok, [colliding?]}`. Live: where a player stands up from a bed
/// (`World.StandUp`, VMC-040a).
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
                Ok(s) => (
                    atoms::ok(),
                    t3(s.body.position),
                    t3(s.body.velocity),
                    s.body.on_ground,
                    s.lava,
                    crate::player::fires(&s.touched),
                )
                    .encode(env),
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
/// `{:ok, position, velocity, on_ground, lava, fire_contacts}`, `:inside`,
/// `{:unreadable, pos}` or `:limit` (the item keeps its state).
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
                Ok(s) => (
                    atoms::ok(),
                    t3(s.body.position),
                    t3(s.body.velocity),
                    s.body.on_ground,
                    s.lava,
                    crate::player::fires(&s.touched),
                )
                    .encode(env),
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
    rustler::atoms! { wait, move_to, jumping, set, set_lift, ground, fish, guardian, squid, strafe, flying }
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
    fall_scale: f64,
    rise: bool,
    powder_snow_walkable: bool,
    was_powder_snow: bool,
    fixed: bool,
    pushable: bool,
    pushes: bool,
    /// A wall climber's climbing (VMC-043b4), nil for the others.
    wall_climb: Option<bool>,
    /// A rabbit's hop (VMC-043c), or nil.
    hop: Option<HopT>,
    travel: (Atom, bool),
    fluid_pushed: bool,
    impulse: Vec3,
    vertical_collision: bool,
    emits: bool,
    move_dist: f64,
    next_step: f64,
    /// A ghast's move control: `%{wanted, duration, random, speed}`, or nil.
    float: Option<FloatT>,
}

/// A ghast's move control (`valimc_core::physics::mob::Float`).
#[derive(rustler::NifMap)]
struct FloatT {
    wanted: Option<Vec3>,
    duration: i32,
    random: i64,
    speed: f64,
}

/// A rabbit's hopping controls (`valimc_core::physics::mob::Hop`).
#[derive(rustler::NifMap)]
struct HopT {
    jumping: bool,
    wanted: Vec3,
    speed: f64,
    next_speed: f64,
    path_up: bool,
    baby: bool,
    started: bool,
    jumped: bool,
    nav_speed: Option<f64>,
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
    landing_pos: Option<(i32, i32, i32)>,
    fire_contacts: crate::player::FiresT,
    climbing: bool,
    powder_snow: bool,
    /// The water and lava heights the move left.
    depths: (f64, f64),
    /// A swim sound's volume, when the move made one.
    swim: Option<f64>,
}

fn mob(m: &MobT) -> NifResult<valimc_core::physics::mob::Mob> {
    use valimc_core::physics::mob::{Attributes, Control, Mob, Travel};
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
    } else if op == mob_atoms::set() || op == mob_atoms::set_lift() {
        Control::Set {
            speed,
            lift: op == mob_atoms::set_lift(),
        }
    } else if op == mob_atoms::strafe() {
        let [forward, right, _] = v3(target.ok_or(rustler::Error::BadArg)?);
        Control::Strafe {
            forward: forward as f32,
            right: right as f32,
            speed,
        }
    } else {
        return Err(rustler::Error::BadArg);
    };
    let (kind, sink) = m.travel;
    let travel = if kind == mob_atoms::ground() {
        Travel::Ground
    } else if kind == mob_atoms::fish() {
        Travel::Fish { sink }
    } else if kind == mob_atoms::guardian() {
        Travel::Guardian { sink }
    } else if kind == mob_atoms::squid() {
        Travel::Squid
    } else if kind == mob_atoms::flying() {
        Travel::Flying
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
        fall_scale: m.fall_scale,
        rise: m.rise,
        powder_snow_walkable: m.powder_snow_walkable,
        was_powder_snow: m.was_powder_snow,
        fixed: m.fixed,
        pushable: m.pushable,
        pushes: m.pushes,
        wall_climb: m.wall_climb,
        hop: m.hop.as_ref().map(|h| valimc_core::physics::mob::Hop {
            jumping: h.jumping,
            wanted: v3(h.wanted),
            speed: h.speed,
            next_speed: h.next_speed,
            path_up: h.path_up,
            baby: h.baby,
            started: h.started,
            jumped: h.jumped,
            nav_speed: h.nav_speed,
        }),
        travel,
        fluid_pushed: m.fluid_pushed,
        impulse: v3(m.impulse),
        vertical_collision: m.vertical_collision,
        emits: m.emits,
        move_dist: m.move_dist as f32,
        next_step: m.next_step as f32,
        float: m.float.as_ref().map(|f| valimc_core::physics::mob::Float {
            wanted: f.wanted.map(v3),
            duration: f.duration,
            random: f.random as u64,
            speed: f.speed,
        }),
    })
}

fn mob_t(m: &valimc_core::physics::mob::Mob) -> MobT {
    use valimc_core::physics::mob::{Control, Travel};
    let a = &m.attributes;
    let control = match m.control {
        Control::Wait => (mob_atoms::wait(), None, 0.0),
        Control::MoveTo { target, speed } => (mob_atoms::move_to(), Some(t3(target)), speed),
        Control::Jumping { speed } => (mob_atoms::jumping(), None, speed),
        Control::Set { speed, lift } => (
            if lift {
                mob_atoms::set_lift()
            } else {
                mob_atoms::set()
            },
            None,
            speed,
        ),
        Control::Strafe {
            forward,
            right,
            speed,
        } => (
            mob_atoms::strafe(),
            Some((forward as f64, right as f64, 0.0)),
            speed,
        ),
    };
    let travel = match m.travel {
        Travel::Ground => (mob_atoms::ground(), false),
        Travel::Fish { sink } => (mob_atoms::fish(), sink),
        Travel::Guardian { sink } => (mob_atoms::guardian(), sink),
        Travel::Squid => (mob_atoms::squid(), false),
        Travel::Flying => (mob_atoms::flying(), false),
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
        fall_scale: m.fall_scale,
        rise: m.rise,
        powder_snow_walkable: m.powder_snow_walkable,
        was_powder_snow: m.was_powder_snow,
        fixed: m.fixed,
        pushable: m.pushable,
        pushes: m.pushes,
        wall_climb: m.wall_climb,
        hop: m.hop.map(|h| HopT {
            jumping: h.jumping,
            wanted: t3(h.wanted),
            speed: h.speed,
            next_speed: h.next_speed,
            path_up: h.path_up,
            baby: h.baby,
            started: h.started,
            jumped: h.jumped,
            nav_speed: h.nav_speed,
        }),
        travel,
        fluid_pushed: m.fluid_pushed,
        impulse: t3(m.impulse),
        vertical_collision: m.vertical_collision,
        emits: m.emits,
        move_dist: m.move_dist as f64,
        next_step: m.next_step as f64,
        float: m.float.map(|f| FloatT {
            wanted: f.wanted.map(t3),
            duration: f.duration,
            random: f.random as i64,
            speed: f.speed,
        }),
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
            Ok(t) => ok(env, ticked_t(t)),
            Err(f) => crate::player::fault(env, *f),
        })
        .collect();
    Ok(ok(env, results))
}

/// A shared snapshot a kernel resource holds for its whole tick.
pub(crate) struct SnapshotArc(rustler::ResourceArc<Snapshot>);

impl std::ops::Deref for SnapshotArc {
    type Target = valimc_core::snapshot::ChunkSnapshot;
    fn deref(&self) -> &Self::Target {
        &self.0 .0
    }
}

/// `view` with its snapshots held, not borrowed (a resource's).
fn owned_view(term: Term, facts: &Facts, region: &Aabb) -> NifResult<View<SnapshotArc>> {
    let tuple = rustler::types::tuple::get_tuple(term)?;
    let tag: Atom = tuple.first().ok_or(invalid())?.decode()?;
    if tag == atoms::states() {
        return match view(term, facts, region)? {
            View::States(states) => Ok(View::States(states)),
            View::Rows(_) => Err(invalid()),
        };
    }
    if tag != atoms::rows() || tuple.len() != 3 {
        return Err(invalid());
    }
    let snapshots: Vec<rustler::ResourceArc<Snapshot>> = tuple[1].decode()?;
    let outside: u16 = tuple[2].decode()?;
    let lowest = ((region.min[1] - 2.0).floor() as i32 + 64).max(0) >> 4;
    let highest = ((region.max[1] + 2.0).floor() as i32 + 64).clamp(0, 383) >> 4;
    let mut rows = Rows::new(outside);
    for snapshot in snapshots {
        rows.insert(
            SnapshotArc(snapshot),
            lowest as usize..=highest as usize,
            &facts.shapes,
        );
    }
    Ok(View::Rows(rows))
}

/// An owner's mobs ticking one at a time (VMC-043e): the view read once,
/// the mobs' motion and the push grid kept between the steps the owner's AI
/// interleaves (`valimc_core::physics::mob::Ticker`). Owned by the owner
/// for one tick.
pub struct MobTicker(std::sync::Mutex<Option<TickerState>>);

pub(crate) struct TickerState {
    view: View<SnapshotArc>,
    border: Option<(f64, f64, f64, f64)>,
    players: Vec<([f64; 3], Aabb)>,
    ticker: valimc_core::physics::mob::Ticker,
}

#[rustler::resource_impl]
impl rustler::Resource for MobTicker {}

fn ticker_begin(
    view_term: Term,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<rustler::ResourceArc<MobTicker>> {
    let facts = facts()?;
    let bodies = mobs.iter().map(mob).collect::<NifResult<Vec<_>>>()?;
    let region = union(
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
    )
    .ok_or(invalid())?;
    let view = owned_view(view_term, facts, &region)?;
    let players = players.into_iter().map(|(f, b)| (v3(f), aabb(b))).collect();
    Ok(rustler::ResourceArc::new(MobTicker(std::sync::Mutex::new(
        Some(TickerState {
            view,
            border,
            players,
            ticker: valimc_core::physics::mob::Ticker::new(bodies),
        }),
    ))))
}

/// Begin an owner's mob tick over `view` (the cells around every mob),
/// `mobs` as they start it, the `players` that push them and the border.
#[rustler::nif]
fn physics_mobs_begin(
    view_term: Term,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<rustler::ResourceArc<MobTicker>> {
    ticker_begin(view_term, mobs, players, border)
}

/// `physics_mobs_begin` for views past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_mobs_begin_dirty(
    view_term: Term,
    mobs: Vec<MobT>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<rustler::ResourceArc<MobTicker>> {
    ticker_begin(view_term, mobs, players, border)
}

fn ticked_t(t: &valimc_core::physics::mob::Ticked) -> TickedT {
    TickedT {
        mob: mob_t(&t.mob),
        water: t.water,
        lava: t.lava,
        eye_water: t.eye_water,
        eye_state: t.eye_state,
        landing: t.landing,
        landing_pos: t.landing_pos.map(|p| (p[0], p[1], p[2])),
        fire_contacts: crate::player::fires(&t.touched),
        climbing: t.climbing,
        powder_snow: t.powder_snow,
        depths: (t.depths.water, t.depths.lava),
        swim: t.swim.map(|v| v as f64),
    }
}

/// Mob `index`'s tick with `input` (its AI's): `{result, pushed}`, the
/// result `{:ok, ticked}` or `{:error, reason}` (it keeps its state) and
/// the mobs it pushed, `[{index, velocity}]`.
#[rustler::nif]
fn physics_mobs_step<'a>(
    env: Env<'a>,
    resource: rustler::ResourceArc<MobTicker>,
    index: usize,
    input: MobT,
) -> NifResult<Term<'a>> {
    ticker_step(env, resource, index, input)
}

/// `physics_mobs_step` for a step past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn physics_mobs_step_dirty<'a>(
    env: Env<'a>,
    resource: rustler::ResourceArc<MobTicker>,
    index: usize,
    input: MobT,
) -> NifResult<Term<'a>> {
    ticker_step(env, resource, index, input)
}

fn ticker_step<'a>(
    env: Env<'a>,
    resource: rustler::ResourceArc<MobTicker>,
    index: usize,
    input: MobT,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let input = mob(&input)?;
    let mut guard = resource.0.lock().map_err(|_| invalid())?;
    let state = guard.as_mut().ok_or(invalid())?;
    if index >= state.ticker.current.len() {
        return Err(invalid());
    }
    let TickerState {
        view,
        border,
        players,
        ticker,
    } = state;
    let world = valimc_core::physics::player::World {
        source: view,
        facts,
        border: crate::player::border(*border),
    };
    let (result, pushed) = ticker.step(&world, index, input, players);
    let result = match &result {
        Ok(t) => ok(env, ticked_t(t)),
        Err(f) => crate::player::fault(env, *f),
    };
    let pushed: Vec<(usize, Vec3)> = pushed.into_iter().map(|(j, v)| (j, t3(v))).collect();
    Ok((result, pushed).encode(env))
}

/// Mob `index`'s motion as its tick ended (a squid's stroke): later pushes
/// add to it.
#[rustler::nif]
fn physics_mobs_velocity(
    resource: rustler::ResourceArc<MobTicker>,
    index: usize,
    velocity: Vec3,
) -> NifResult<Atom> {
    let mut guard = resource.0.lock().map_err(|_| invalid())?;
    let state = guard.as_mut().ok_or(invalid())?;
    let mob = state.ticker.current.get_mut(index).ok_or(invalid())?;
    mob.velocity = v3(velocity);
    Ok(atoms::ok())
}

/// The tick's end: the players push, and every mob's motion for its next
/// tick, in order. The resource is spent.
#[rustler::nif]
fn physics_mobs_finish(resource: rustler::ResourceArc<MobTicker>) -> NifResult<Vec<Vec3>> {
    let mut guard = resource.0.lock().map_err(|_| invalid())?;
    let state = guard.take().ok_or(invalid())?;
    Ok(state
        .ticker
        .finish(&state.players)
        .into_iter()
        .map(t3)
        .collect())
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

/// A body moving pistons may push (VMC-048b): feet, `{half width, height}`,
/// velocity, `{on_ground, max_step, simulates, ignored}` and `{bounciness,
/// suppresses_bounce, living, gravity, air_drag}`.
type PushBodyT = (
    Vec3,
    (f64, f64),
    Vec3,
    (bool, f32, bool, bool),
    (f64, bool, bool, f64, f64),
);

/// A tick's moving-block pushes (VMC-048b) on `bodies` over a view:
/// `pushes` are `piston::Moving` records each followed by its new progress
/// (float bits), `states` the slime and honey block states. Each body
/// comes back as `{feet, velocity, on_ground, pushed}`.
#[rustler::nif]
fn physics_pistons<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    pushes: rustler::Binary<'a>,
    bodies: Vec<PushBodyT>,
    states: (u16, u16),
    border: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    use valimc_core::physics::piston::{push_all, Push, PushBody, PushStates, World};
    let facts = facts()?;
    let packed = pushes.as_slice();
    let record = valimc_core::piston::PACKED;
    if !packed.len().is_multiple_of(record + 7) {
        return Err(invalid());
    }
    let mut list = Vec::new();
    for chunk in packed.chunks_exact(record + 7) {
        let (pos, moving) = valimc_core::piston::Moving::unpack(&chunk[..record])
            .and_then(|v| v.into_iter().next())
            .ok_or_else(invalid)?;
        let progress = f32::from_bits(u32::from_be_bytes(
            chunk[record..record + 4].try_into().unwrap(),
        ));
        list.push(Push {
            pos,
            moving,
            progress,
            state: u16::from_be_bytes([chunk[record + 4], chunk[record + 5]]),
            landed: chunk[record + 6] != 0,
        });
    }
    let mut bodies: Vec<PushBody> = bodies
        .into_iter()
        .map(
            |(
                p,
                (half_width, height),
                v,
                (on_ground, step, simulates, ignored),
                (bounciness, suppress_bounce, living, gravity, air_drag),
            )| PushBody {
                position: v3(p),
                half_width,
                height,
                velocity: v3(v),
                on_ground,
                step,
                simulates,
                ignored,
                bounciness,
                suppress_bounce,
                living,
                gravity,
                air_drag,
                pushed: false,
            },
        )
        .collect();
    let mut areas: Vec<Aabb> = list
        .iter()
        .filter(|p| !p.landed)
        .map(|p| {
            let c = p.pos.map(|v| v as f64);
            Aabb::new(
                [c[0] - 3.0, c[1] - 3.0, c[2] - 3.0],
                [c[0] + 4.0, c[1] + 4.0, c[2] + 4.0],
            )
        })
        .collect();
    areas.extend(bodies.iter().map(|b| {
        let p = b.position;
        Aabb::new(
            [
                p[0] - b.half_width - 2.0,
                p[1] - 2.0,
                p[2] - b.half_width - 2.0,
            ],
            [
                p[0] + b.half_width + 2.0,
                p[1] + b.height + 2.0,
                p[2] + b.half_width + 2.0,
            ],
        )
    }));
    let Some(region) = union(&areas) else {
        return Ok(ok(env, Vec::<Term>::new()));
    };
    let view = view(view_term, facts, &region)?;
    let border = border.map(|(min_x, min_z, max_x, max_z)| Border {
        min_x,
        min_z,
        max_x,
        max_z,
    });
    let world = World {
        source: &view,
        facts,
        border: border.as_ref(),
        states: PushStates {
            slime: states.0,
            honey: states.1,
        },
    };
    push_all(&world, &list, &mut bodies);
    let out: Vec<Term> = bodies
        .iter()
        .map(|b| (t3(b.position), t3(b.velocity), b.on_ground, b.pushed).encode(env))
        .collect();
    Ok(ok(env, out))
}
