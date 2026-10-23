//! The player's travel rules for Elixir (VMC-077l2): one call validates a
//! move packet and one samples a resting player, each over the published
//! rows of the chunks around the player (as `physics` takes views). A player
//! is a map of its position, look, pose id, `Valimc.PlayerMotion` (paths as
//! `{from, to, axis}` tuples), input flags, mode and travel effects; results
//! are maps the connection applies.

use crate::physics::{facts, t3, v3, view, Vec3};
use rustler::{Atom, Encoder, Env, NifMap, NifResult, Term};
use valimc_core::physics::border::Border;
use valimc_core::physics::player::contacts::{Contact, Source, Touched};
use valimc_core::physics::player::frame::{self, Moved, Rested};
use valimc_core::physics::player::kinetics::Kinetics;
use valimc_core::physics::player::paths::Path;
use valimc_core::physics::player::{Fault, Mode, Motion, Player, World};
use valimc_core::physics::Aabb;

mod atoms {
    rustler::atoms! {
        ok, error, unreadable, survival, creative, adventure, spectator,
        fire, soul_fire, powder_snow, lava, water,
        hot_floor, campfire, cactus, sweet_berry_bush,
    }
}

pub(crate) type PathT = (Vec3, Vec3, Option<Vec3>);

#[derive(NifMap)]
pub(crate) struct MotionT {
    fall_distance: f64,
    velocity: Vec3,
    physical_ground: bool,
    settled: bool,
    swimming: bool,
    paths: Vec<PathT>,
    stuck_multiplier: Vec3,
    known_movement: Vec3,
    on_ground: bool,
    horizontal_collision: bool,
    received: bool,
}

#[derive(NifMap)]
pub(crate) struct PlayerT {
    position: Vec3,
    yaw: f64,
    pitch: f64,
    pose: u8,
    motion: MotionT,
    shift: bool,
    sprint: bool,
    loaded: bool,
    jump: bool,
    sneak: bool,
    flying: bool,
    mode: Atom,
    invulnerable: bool,
    jump_boost: i32,
    slow_falling: bool,
    levitation: Option<i32>,
}

pub(crate) fn path(p: &PathT) -> Path {
    Path {
        from: v3(p.0),
        to: v3(p.1),
        axis: p.2.map(v3),
    }
}

pub(crate) fn path_t(p: &Path) -> PathT {
    (t3(p.from), t3(p.to), p.axis.map(t3))
}

pub(crate) fn motion(m: &MotionT) -> Motion {
    Motion {
        fall_distance: m.fall_distance,
        velocity: v3(m.velocity),
        physical_ground: m.physical_ground,
        settled: m.settled,
        swimming: m.swimming,
        paths: m.paths.iter().map(path).collect(),
        stuck_multiplier: v3(m.stuck_multiplier),
        known_movement: v3(m.known_movement),
        on_ground: m.on_ground,
        horizontal_collision: m.horizontal_collision,
        received: m.received,
    }
}

pub(crate) fn motion_t(m: &Motion) -> MotionT {
    MotionT {
        fall_distance: m.fall_distance,
        velocity: t3(m.velocity),
        physical_ground: m.physical_ground,
        settled: m.settled,
        swimming: m.swimming,
        paths: m.paths.iter().map(path_t).collect(),
        stuck_multiplier: t3(m.stuck_multiplier),
        known_movement: t3(m.known_movement),
        on_ground: m.on_ground,
        horizontal_collision: m.horizontal_collision,
        received: m.received,
    }
}

pub(crate) fn player(p: &PlayerT) -> NifResult<Player> {
    let mode = if p.mode == atoms::survival() {
        Mode::Survival
    } else if p.mode == atoms::creative() {
        Mode::Creative
    } else if p.mode == atoms::adventure() {
        Mode::Adventure
    } else if p.mode == atoms::spectator() {
        Mode::Spectator
    } else {
        return Err(rustler::Error::BadArg);
    };
    Ok(Player {
        position: v3(p.position),
        yaw: p.yaw,
        pitch: p.pitch,
        pose: p.pose,
        motion: motion(&p.motion),
        shift: p.shift,
        sprint: p.sprint,
        loaded: p.loaded,
        jump_pressed: p.jump,
        shift_pressed: p.sneak,
        flying: p.flying,
        mode,
        invulnerable: p.invulnerable,
        jump_boost: p.jump_boost,
        slow_falling: p.slow_falling,
        levitation: p.levitation,
    })
}

#[derive(NifMap)]
pub(crate) struct FiresT {
    immediate: Vec<(Atom, f64)>,
    steps: Vec<Vec<Atom>>,
    active: bool,
}

pub(crate) fn contact(c: Contact) -> Atom {
    match c {
        Contact::Fire => atoms::fire(),
        Contact::SoulFire => atoms::soul_fire(),
        Contact::PowderSnow => atoms::powder_snow(),
        Contact::Lava => atoms::lava(),
        Contact::Water => atoms::water(),
    }
}

pub(crate) fn source(s: Source) -> Atom {
    match s {
        Source::HotFloor => atoms::hot_floor(),
        Source::Campfire => atoms::campfire(),
        Source::Cactus => atoms::cactus(),
        Source::SweetBerryBush => atoms::sweet_berry_bush(),
    }
}

pub(crate) fn fires(t: &Touched) -> FiresT {
    FiresT {
        immediate: t.immediate.iter().map(|&(s, a)| (source(s), a)).collect(),
        steps: t
            .steps
            .iter()
            .map(|step| step.iter().map(|&c| contact(c)).collect())
            .collect(),
        active: t.active,
    }
}

#[derive(NifMap)]
struct KineticsT {
    velocity: Vec3,
    physical_ground: bool,
    settled: bool,
    bounced: bool,
    water: bool,
    lava: bool,
    reset_fall: bool,
    stuck_multiplier: Vec3,
    paths: Vec<PathT>,
    fire_contacts: FiresT,
}

fn kinetics(k: &Kinetics) -> KineticsT {
    KineticsT {
        velocity: t3(k.velocity),
        physical_ground: k.physical_ground,
        settled: k.settled,
        bounced: k.bounced,
        water: k.water,
        lava: k.lava,
        reset_fall: k.reset_fall,
        stuck_multiplier: t3(k.stuck_multiplier),
        paths: k.paths.iter().map(path_t).collect(),
        fire_contacts: fires(&k.touched),
    }
}

#[derive(NifMap)]
struct ExhaustionT {
    jump: f64,
    travel: f64,
}

#[derive(NifMap)]
struct MovedT {
    accepted: bool,
    pose: u8,
    swimming: bool,
    moved: Vec3,
    powder_snow: bool,
    eye_water: bool,
    eye_state: u16,
    top: f64,
    exhaustion: ExhaustionT,
    packet: KineticsT,
    tick: KineticsT,
    landing: Option<(u16, f64)>,
    landing_pos: Option<(i32, i32, i32)>,
    motion: MotionT,
    ticked: MotionT,
}

fn moved_t(m: &Moved) -> MovedT {
    MovedT {
        accepted: m.accepted,
        pose: m.pose,
        swimming: m.swimming,
        moved: t3(m.moved),
        powder_snow: m.powder_snow,
        eye_water: m.eye_water,
        eye_state: m.eye_state,
        top: m.top,
        exhaustion: ExhaustionT {
            jump: m.exhaustion.0,
            travel: m.exhaustion.1,
        },
        packet: kinetics(&m.packet),
        tick: kinetics(&m.tick),
        landing: m.landing,
        landing_pos: m.landing_pos.map(|p| (p[0], p[1], p[2])),
        motion: motion_t(&m.motion),
        ticked: motion_t(&m.ticked),
    }
}

#[derive(NifMap)]
struct RestedT {
    pose: u8,
    swimming: bool,
    powder_snow: bool,
    eye_water: bool,
    eye_state: u16,
    top: f64,
    tick: KineticsT,
    ticked: MotionT,
}

fn rested_t(r: &Rested) -> RestedT {
    RestedT {
        pose: r.pose,
        swimming: r.swimming,
        powder_snow: r.powder_snow,
        eye_water: r.eye_water,
        eye_state: r.eye_state,
        top: r.top,
        tick: kinetics(&r.tick),
        ticked: motion_t(&r.ticked),
    }
}

/// `{:error, {:unreadable, position}}` or `{:error, reason}`.
pub(crate) fn fault<'a>(env: Env<'a>, f: Fault) -> Term<'a> {
    match f {
        Fault::Unreadable(p) => {
            (atoms::error(), (atoms::unreadable(), (p[0], p[1], p[2]))).encode(env)
        }
        Fault::Limit(name) => match Atom::from_str(env, name) {
            Ok(atom) => (atoms::error(), atom).encode(env),
            Err(_) => (atoms::error(), atoms::error()).encode(env),
        },
    }
}

pub(crate) fn reply<'a, T: Encoder>(env: Env<'a>, r: Result<T, Fault>) -> Term<'a> {
    match r {
        Ok(v) => (atoms::ok(), v).encode(env),
        Err(f) => fault(env, f),
    }
}

pub(crate) fn border(b: Option<(f64, f64, f64, f64)>) -> Option<Border> {
    b.map(|(min_x, min_z, max_x, max_z)| Border {
        min_x,
        min_z,
        max_x,
        max_z,
    })
}

/// The box a move (with a target) or a rest reads: `{:ok, box}` or
/// `{:error, reason}` past the query bounds.
#[rustler::nif]
fn physics_player_query<'a>(
    env: Env<'a>,
    p: PlayerT,
    target: Option<Vec3>,
    flags: u8,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let p = player(&p)?;
    let found = frame::query(&facts.player.poses, &p, target.map(v3), flags)
        .map(|b: Aabb| (b.min[0], b.min[1], b.min[2], b.max[0], b.max[1], b.max[2]));
    Ok(reply(env, found))
}

/// Validate a move packet to `target` with `flags` (`handleMovePlayer`):
/// `{:ok, outcome}` with the acceptance, the pose and swimming, the fluid,
/// powder snow and eye contact, the packet's and the tick's kinetics, the
/// landing, the exhaustion and the motion after the packet and after the
/// tick; or `{:error, reason}`.
#[rustler::nif]
fn physics_player_move<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    p: PlayerT,
    target: Vec3,
    flags: u8,
    border_t: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let p = player(&p)?;
    let catalog = &facts.player.poses;
    let region = match frame::query(catalog, &p, Some(v3(target)), flags) {
        Ok(b) => b,
        Err(f) => return Ok(fault(env, f)),
    };
    let view = view(view_term, facts, &region)?;
    let world = World {
        source: &view,
        facts,
        border: border(border_t),
    };
    Ok(reply(
        env,
        frame::validate(&world, catalog, &p, v3(target), flags).map(|m| moved_t(&m)),
    ))
}

/// Sample a resting player's tick where it stands: `{:ok, outcome}` with
/// the pose, swimming, fluid, powder snow and eye contact, the tick's
/// kinetics and the motion after it; or `{:error, reason}`.
#[rustler::nif]
fn physics_player_rest<'a>(
    env: Env<'a>,
    view_term: Term<'a>,
    p: PlayerT,
    border_t: Option<(f64, f64, f64, f64)>,
) -> NifResult<Term<'a>> {
    let facts = facts()?;
    let p = player(&p)?;
    let catalog = &facts.player.poses;
    let region = match frame::query(catalog, &p, None, 0) {
        Ok(b) => b,
        Err(f) => return Ok(fault(env, f)),
    };
    let view = view(view_term, facts, &region)?;
    let world = World {
        source: &view,
        facts,
        border: border(border_t),
    };
    Ok(reply(
        env,
        frame::rest(&world, catalog, &p).map(|r| rested_t(&r)),
    ))
}
