//! A section's native mob tick over resident state (VMC-081d).
//!
//! What the turns read lives in Rust and is refreshed only where it
//! changed: the group's `MobWorld` holds the level (set once per group tick),
//! its sensed players and the push boxes they make, the loot registry and
//! the group's sections (their Region resources and native mob sections);
//! each `MobSection` keeps a resident block view over the published chunk
//! snapshots of its own and its neighbouring Region resources, synced by
//! their publication counters. The owner names only what the section cannot
//! know: the game tick, the simulated chunks (a 64-bit mask), the level
//! random, the items its mobs sense and a few rare extras.
//!
//! One call (`mob_section_tick`) runs every turn in id order: the mobs'
//! ageing is its own call (`mob_section_age_tick`), earlier in the entity
//! phase.
//!
//! What comes back is what changed: the mobs whose physical state moved as
//! one packed binary (`<<id::32, x, y, z, yaw, pitch, head_yaw, vx, vy, vz ::
//! float-64, on_ground::8>>` each), and for each mob with a new row, events,
//! effects or a move out of the section `{id, row | nil, events, effects,
//! outside}` (`outside` its position there, nil while it stays, its move
//! left out of the binary). A mob's body stays here; its owner reads it on
//! demand.

use crate::mob_section::{self as ms, MobSectionRes};
use crate::mob_section_level::{self, LevelEnv};
use crate::mob_term;
use crate::physics::{self as physics_nif, SnapshotArc, Vec3, View};
use crate::region::Region;
use rustler::{Atom, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use valimc_core::mobs::ai::brain::Reaction;
use valimc_core::mobs::ai::think::SectionAi;
use valimc_core::mobs::combat::Rules;
use valimc_core::mobs::model::NativeMob;
use valimc_core::mobs::publish;
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::section::MobSection;
use valimc_core::mobs::sensing::{Kind as RefKind, Ref, SensedItem, SensedPlayer};
use valimc_core::mobs::tick::{self, Entrant, Tick, TurnWorld};
use valimc_core::physics::mob::{Attributes, Ticker};
use valimc_core::physics::player::World;
use valimc_core::physics::source::{AirWhereUnreadable, Rows};
use valimc_core::physics::Aabb;

mod atoms {
    rustler::atoms! {
        ok, world, scene, all, anger, player, portal, only,
        level, players, sections, loot, items, knots, goals, events, located,
        loot_seeds, missing, invalid, not_owner, dragon, crystals, previous_kill,
        crystal_bodies,
    }
}

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

// -------------------------------------------------------------- the world

/// A group's level, players and sections, owned by the group process and
/// read by its sections' ticks.
pub struct MobWorldRes {
    pub(crate) owner: Mutex<LocalPid>,
    pub(crate) inner: Mutex<WorldState>,
}

#[rustler::resource_impl]
impl rustler::Resource for MobWorldRes {}

#[derive(Default)]
pub(crate) struct WorldState {
    pub(crate) level: Option<LevelEnv>,
    pub(crate) players: Vec<SensedPlayer>,
    /// The players' standing boxes, which push the mobs they touch.
    pub(crate) pushers: Vec<([f64; 3], Aabb)>,
    pub(crate) sections: Vec<WorldSection>,
    pub(crate) loot: Option<Arc<valimc_core::loot::Loot>>,
    /// Natural spawning's resident inputs (VMC-081g2).
    pub(crate) spawn: crate::spawn_world::Resident,
}

#[derive(Clone)]
pub(crate) struct WorldSection {
    pub(crate) key: (i32, i32),
    pub(crate) region: ResourceArc<Region>,
    pub(crate) native: Option<ResourceArc<MobSectionRes>>,
}

/// A new world owned by the caller (a group process).
#[rustler::nif]
fn mob_world_new(env: Env) -> ResourceArc<MobWorldRes> {
    ResourceArc::new(MobWorldRes {
        owner: Mutex::new(env.pid()),
        inner: Mutex::new(WorldState::default()),
    })
}

fn pushers(players: &[SensedPlayer]) -> Vec<([f64; 3], Aabb)> {
    players
        .iter()
        .map(|p| {
            let [x, y, z] = p.position;
            (
                p.position,
                Aabb::new([x - 0.3, y, z - 0.3], [x + 0.3, y + 1.8, z + 0.3]),
            )
        })
        .collect()
}

/// Changes what the world holds: a map of any of `level` (the map
/// `LevelEnv::decode` reads), `players` (sensed players), `sections`
/// (`[{sx, sz, region, native | nil}]`) and `loot` (the loot registry).
#[rustler::nif]
fn mob_world_set<'a>(
    env: Env<'a>,
    world: ResourceArc<MobWorldRes>,
    changes: Term<'a>,
) -> NifResult<Atom> {
    if env.pid() != *world.owner.lock().map_err(|_| bad())? {
        return Err(rustler::Error::Term(Box::new(atoms::not_owner())));
    }
    let level = match changes.map_get(atoms::level()) {
        Ok(t) => Some(LevelEnv::decode(t)?),
        Err(_) => None,
    };
    let players = match changes.map_get(atoms::players()) {
        Ok(t) => Some(
            t.decode::<Vec<Term>>()?
                .into_iter()
                .map(mob_section_level::player)
                .collect::<NifResult<Vec<_>>>()?,
        ),
        Err(_) => None,
    };
    let sections = match changes.map_get(atoms::sections()) {
        Ok(t) => Some(
            t.decode::<Vec<(
                i32,
                i32,
                ResourceArc<Region>,
                Option<ResourceArc<MobSectionRes>>,
            )>>()?
            .into_iter()
            .map(|(sx, sz, region, native)| WorldSection {
                key: (sx, sz),
                region,
                native,
            })
            .collect::<Vec<_>>(),
        ),
        Err(_) => None,
    };
    let loot = match changes.map_get(atoms::loot()) {
        Ok(t) => Some(
            t.decode::<ResourceArc<crate::loot::LootRegistry>>()?
                .loot
                .clone(),
        ),
        Err(_) => None,
    };
    let mut inner = world.inner.lock().map_err(|_| bad())?;
    if let Some(level) = level {
        inner.level = Some(level);
    }
    if let Some(players) = players {
        inner.pushers = pushers(&players);
        inner.players = players;
    }
    if let Some(sections) = sections {
        inner.sections = sections;
    }
    if let Some(loot) = loot {
        inner.loot = Some(loot);
    }
    Ok(atoms::ok())
}

// ------------------------------------------------------- resident blocks

/// A section's resident block view: the published snapshots of its own and
/// its neighbouring Region resources, with the publication each was synced
/// at.
#[derive(Default)]
pub(crate) struct Resident {
    view: Option<View<SnapshotArc>>,
    synced: Vec<((i32, i32), usize, u64)>,
}

fn region_id(region: &ResourceArc<Region>) -> usize {
    &**region as *const Region as usize
}

/// The section `key`'s view, synced with the group's `sections`.
fn sync<'r>(
    resident: &'r mut Resident,
    key: (i32, i32),
    sections: &[WorldSection],
) -> NifResult<&'r View<SnapshotArc>> {
    let facts = physics_nif::facts()?;
    let near: Vec<&WorldSection> = sections
        .iter()
        .filter(|s| (s.key.0 - key.0).abs() <= 1 && (s.key.1 - key.1).abs() <= 1)
        .collect();
    let mut wanted = Vec::with_capacity(near.len());
    for s in &near {
        let revision = s.region.published.lock().map_err(|_| bad())?.revision;
        wanted.push((s.key, region_id(&s.region), revision));
    }
    wanted.sort_unstable();
    let fresh = resident.view.is_none();
    if !fresh && resident.synced == wanted {
        return Ok(resident.view.as_ref().expect("view"));
    }
    let view = resident
        .view
        .get_or_insert_with(|| View::Rows(Rows::new(0)));
    if !matches!(view, View::Rows(_)) {
        *view = View::Rows(Rows::new(0));
    }
    let View::Rows(rows) = view else {
        unreachable!()
    };
    let section_of = |c: (i32, i32)| (c.0 >> 3, c.1 >> 3);
    // The chunks of regions gone or changed.
    let gone: Vec<(i32, i32)> = resident
        .synced
        .iter()
        .filter(|old| !wanted.iter().any(|w| w.0 == old.0 && w.1 == old.1))
        .map(|old| old.0)
        .collect();
    if !gone.is_empty() {
        let drop: Vec<(i32, i32)> = rows
            .chunks()
            .filter(|c| gone.contains(&section_of(*c)))
            .collect();
        for c in drop {
            rows.remove(c);
        }
    }
    for s in &near {
        let current = (s.key, region_id(&s.region));
        let unchanged = resident
            .synced
            .iter()
            .any(|old| (old.0, old.1) == current && wanted.contains(old));
        if unchanged {
            continue;
        }
        let published = s.region.published.lock().map_err(|_| bad())?;
        for (&chunk, handle) in &published.chunks {
            if rows.snapshot(chunk).is_some_and(|held| held.same(handle)) {
                continue;
            }
            rows.insert(
                SnapshotArc(handle.clone()),
                0..=valimc_core::column::SECTIONS - 1,
                &facts.shapes,
            );
        }
    }
    resident.synced = wanted;
    Ok(resident.view.as_ref().expect("view"))
}

// ------------------------------------------------------------- the tick

/// What a tick reads beside its section: the group's world, or a scene an
/// oracle supplies (its view, level map, players and region).
enum Source<'a> {
    World(ResourceArc<MobWorldRes>),
    Scene {
        view: Term<'a>,
        level: Term<'a>,
        players: Vec<Term<'a>>,
        region: Option<ResourceArc<Region>>,
    },
}

fn source(term: Term) -> NifResult<Source> {
    let t = rustler::types::tuple::get_tuple(term)?;
    let tag: Atom = t.first().ok_or_else(bad)?.decode()?;
    if tag == atoms::world() && t.len() == 2 {
        Ok(Source::World(t[1].decode()?))
    } else if tag == atoms::scene() && t.len() == 5 {
        Ok(Source::Scene {
            view: t[1],
            level: t[2],
            players: t[3].decode()?,
            region: t[4].decode()?,
        })
    } else {
        Err(bad())
    }
}

/// The section's extras: its items, the knots (where the group has any),
/// whether goals run, the players' anger events, structure queries
/// answered and loot seeds.
#[derive(Default)]
pub(crate) struct Extras {
    items: Vec<SensedItem>,
    knots: Option<HashMap<[i32; 3], i32>>,
    goals: Option<bool>,
    events: Vec<Reaction>,
    located: HashMap<([u8; 16], u64), Option<[i32; 3]>>,
    loot_seeds: Vec<i64>,
    /// The native mobs that take turns (an oracle's live ones); None: every
    /// one in the simulated chunks.
    only: Option<Vec<i32>>,
    /// A dragon's arena (`dragon_world`), where the group holds one.
    dragon: Option<tick::DragonWorld>,
}

/// A box `{x0, y0, z0, x1, y1, z1}`.
type Box6 = (f64, f64, f64, f64, f64, f64);

fn box6(b: Box6) -> [f64; 6] {
    [b.0, b.1, b.2, b.3, b.4, b.5]
}

/// A dragon's arena from its owner: `%{crystals: n | nil, previous_kill,
/// crystal_bodies: [{uuid, {x, y, z}, box}]}`.
fn dragon_world(term: Term) -> NifResult<tick::DragonWorld> {
    use valimc_core::mobs::boss::dragon::Crystal;
    let crystal_bodies = term
        .map_get(atoms::crystal_bodies())?
        .decode::<Vec<(Term, Vec3, Box6)>>()?
        .into_iter()
        .map(|(uuid, p, b)| {
            Ok(Crystal {
                uuid: uuid16(uuid)?,
                position: [p.0, p.1, p.2],
                bbox: box6(b),
            })
        })
        .collect::<NifResult<_>>()?;
    Ok(tick::DragonWorld {
        crystals: term.map_get(atoms::crystals())?.decode()?,
        previous_kill: term.map_get(atoms::previous_kill())?.decode()?,
        crystal_bodies,
        others: Vec::new(),
        flame_uuid: [0; 16],
    })
}

/// 16 fresh bytes: a breath's cloud uuid.
fn fresh_uuid() -> [u8; 16] {
    let mut out = [0u8; 16];
    out[..8].copy_from_slice(&ms::seed().to_be_bytes());
    out[8..].copy_from_slice(&ms::seed().to_be_bytes());
    out
}

/// The native mobs of `section` the dragon may touch, where they are.
fn dragon_targets(
    rules: &Rules,
    section: &MobSection,
) -> Vec<valimc_core::mobs::boss::dragon::MobTarget> {
    use valimc_core::mobs::boss::dragon::{recent, MobTarget};
    section
        .slots()
        .filter_map(|(_, slot)| {
            let m = &slot.mob;
            let ty = rules.of(&m.body.entity_type)?;
            let [width, height, _] =
                valimc_core::mobs::living::body::dimensions(rules, ty, &m.body);
            Some(MobTarget {
                uuid: m.uuid,
                position: m.position,
                width,
                height,
                bbox: rules.family(ty).bounding_box(&m.body, m.position),
                recent: recent(&m.body.mob),
            })
        })
        .collect()
}

fn uuid16(t: Term) -> NifResult<[u8; 16]> {
    let b: rustler::Binary = t.decode()?;
    b.as_slice().try_into().map_err(|_| bad())
}

fn extras(term: Term) -> NifResult<Extras> {
    let mut x = Extras::default();
    let get = |a: Atom| {
        term.map_get(a).ok().filter(|t| {
            !t.is_atom()
                || t.decode::<Atom>()
                    .map_or(true, |a| a != rustler::types::atom::nil())
        })
    };
    if let Some(t) = get(atoms::items()) {
        x.items = t
            .decode::<Vec<Term>>()?
            .into_iter()
            .map(mob_section_level::item)
            .collect::<NifResult<_>>()?;
    }
    if let Some(t) = get(atoms::knots()) {
        x.knots = Some(
            t.decode::<Vec<((i32, i32, i32), i32)>>()?
                .into_iter()
                .map(|((a, b, c), id)| ([a, b, c], id))
                .collect(),
        );
    }
    if let Some(t) = get(atoms::goals()) {
        x.goals = Some(t.decode()?);
    }
    if let Some(t) = get(atoms::events()) {
        for e in t.decode::<Vec<Term>>()? {
            let (tag, (kind, uuid), seen): (Atom, (Atom, Term), bool) = e.decode()?;
            if tag == atoms::anger() && kind == atoms::player() {
                x.events.push(Reaction::Anger {
                    player: Ref {
                        kind: RefKind::Player,
                        uuid: uuid16(uuid)?,
                    },
                    seen,
                });
            }
        }
    }
    if let Some(t) = get(atoms::located()) {
        for (uuid, token, result) in t.decode::<Vec<(Term, u64, Option<(i32, i32, i32)>)>>()? {
            x.located
                .insert((uuid16(uuid)?, token), result.map(|(a, b, c)| [a, b, c]));
        }
    }
    if let Some(t) = get(atoms::loot_seeds()) {
        x.loot_seeds = t.decode()?;
    }
    if let Some(t) = get(atoms::only()) {
        let mut only: Vec<i32> = t.decode()?;
        only.sort_unstable();
        x.only = Some(only);
    }
    if let Some(t) = get(atoms::dragon()) {
        x.dragon = Some(dragon_world(t)?);
    }
    Ok(x)
}

/// What a tick's level is made from between its runs: the level's scalars
/// and the parts its turns use up.
pub(crate) struct LevelParts {
    pub(crate) env: LevelEnv,
    pub(crate) moving: Moving,
    pub(crate) loot: Option<Arc<valimc_core::loot::Loot>>,
}

/// The parts of a level its turns use up or change: the players' events,
/// the POI claims, structure queries answered and loot seeds.
#[derive(Default)]
pub(crate) struct Moving {
    events: Vec<Reaction>,
    pois: HashMap<[i32; 3], i32>,
    located: HashMap<([u8; 16], u64), Option<[i32; 3]>>,
    loot_seeds: std::collections::VecDeque<i64>,
}

impl Moving {
    fn give(&mut self, level: &mut valimc_core::mobs::level::Level) {
        level.events = std::mem::take(&mut self.events);
        level.pois = std::mem::take(&mut self.pois);
        level.located = std::mem::take(&mut self.located);
        level.loot_seeds = std::mem::take(&mut self.loot_seeds);
    }

    fn keep(&mut self, level: &mut valimc_core::mobs::level::Level) {
        self.events = std::mem::take(&mut level.events);
        self.pois = std::mem::take(&mut level.pois);
        self.located = std::mem::take(&mut level.located);
        self.loot_seeds = std::mem::take(&mut level.loot_seeds);
    }
}

/// The structure queries answered this tick that no mob took: kept for
/// their mobs' next ticks where they are still the section's.
fn keep_located(inner: &mut ms::Inner, moving: &mut Moving) {
    let mut left = std::mem::take(&mut moving.located);
    left.retain(|(uuid, _), _| inner.section.id_of(uuid).is_some());
    inner.located = left;
}

/// The types whose AI moves them far within a turn (a teleport).
const TELEPORTERS: [&str; 2] = ["minecraft:enderman", "minecraft:shulker"];

/// Whether a native mob's turn may leave the section or meet a chunk the
/// view cannot read: it keeps its state before the tick as its fallback.
fn keeps(section: &MobSection, view: &View<SnapshotArc>, mob: &NativeMob) -> bool {
    let View::Rows(rows) = view else {
        return true;
    };
    if TELEPORTERS.contains(&mob.body.entity_type.as_str()) {
        return true;
    }
    let v = mob.body.velocity;
    let margin = 8.0 + v[0].abs().max(v[1].abs()).max(v[2].abs());
    let [x, _, z] = mob.position;
    if !section.anywhere {
        let (sx, sz) = section.section;
        let (x0, z0) = ((sx * 128) as f64, (sz * 128) as f64);
        if x - margin < x0
            || x + margin >= x0 + 128.0
            || z - margin < z0
            || z + margin >= z0 + 128.0
        {
            return true;
        }
    }
    let chunk = |c: f64| (c.floor() as i64 >> 4) as i32;
    for cx in chunk(x - margin)..=chunk(x + margin) {
        for cz in chunk(z - margin)..=chunk(z + margin) {
            if !rows.contains((cx, cz)) {
                return true;
            }
        }
    }
    false
}

fn aabb6(b: [f64; 6]) -> Aabb {
    Aabb::new([b[0], b[1], b[2]], [b[3], b[4], b[5]])
}

fn merge(into: &mut HashMap<[i32; 3], i32>, more: &HashMap<[i32; 3], i32>) {
    for (p, n) in more {
        *into.entry(*p).or_insert(0) += n;
    }
}

/// A kernel map as a fixed collider: it takes no turn and neither pushes
/// nor is pushed.
fn fix(m: &mut valimc_core::physics::mob::Mob) {
    m.fixed = true;
    m.pushable = false;
    m.pushes = false;
    m.velocity = [0.0; 3];
}

/// Runs a section's tick: every mob takes its turn in id order.
///
/// `source` is `{:world, world}` or `{:scene, view, level, players,
/// region}`; `tick` the game tick (nil in scenes without one); `mask` the
/// simulated chunks of the section (bit `z * 8 + x` of its local chunk) or
/// `:all`; `random` the section's level random (its state); `extra` a map
/// of the section's extras (`Extras`).
///
/// `{random, moved, changes}` (see the module docs).
#[rustler::nif]
fn mob_section_tick<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    source_term: Term<'a>,
    tick: Option<i64>,
    mask: Term<'a>,
    random: i64,
    extra: Term<'a>,
) -> NifResult<Term<'a>> {
    tick_section(env, res, source_term, tick, mask, random, extra)
}

/// `mob_section_tick/6` past the normal scheduler's budget (many mobs).
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_section_tick_dirty<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    source_term: Term<'a>,
    tick: Option<i64>,
    mask: Term<'a>,
    random: i64,
    extra: Term<'a>,
) -> NifResult<Term<'a>> {
    tick_section(env, res, source_term, tick, mask, random, extra)
}

fn tick_section<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    source_term: Term<'a>,
    tick: Option<i64>,
    mask: Term<'a>,
    random: i64,
    extra: Term<'a>,
) -> NifResult<Term<'a>> {
    let rules = ms::rules()?;
    let physics = physics_nif::facts()?;
    let families = ms::families(&rules)?;
    let mut extras = extras(extra)?;
    let all = mask.decode::<Atom>().ok() == Some(atoms::all());
    let mask: u64 = if all { u64::MAX } else { mask.decode()? };

    // What the group holds now.
    let (env_level, players, pushers, sections, loot, scene_view, scene_region) =
        match source(source_term)? {
            Source::World(world) => {
                let w = world.inner.lock().map_err(|_| bad())?;
                let level = w.level.clone().ok_or_else(bad)?;
                (
                    level,
                    w.players.clone(),
                    w.pushers.clone(),
                    w.sections.clone(),
                    w.loot.clone(),
                    None,
                    None,
                )
            }
            Source::Scene {
                view,
                level,
                players,
                region,
            } => {
                let players = players
                    .into_iter()
                    .map(mob_section_level::player)
                    .collect::<NifResult<Vec<_>>>()?;
                let pushers = pushers(&players);
                (
                    LevelEnv::decode(level)?,
                    players,
                    pushers,
                    Vec::new(),
                    None,
                    Some(view),
                    region,
                )
            }
        };

    let mut guard = ms::owned(env, &res)?;
    let inner = &mut *guard;
    let key = inner.section.section;
    let in_mask = |chunk: (i32, i32)| {
        if all {
            return true;
        }
        let (lx, lz) = (chunk.0 - key.0 * 8, chunk.1 - key.1 * 8);
        (0..8).contains(&lx) && (0..8).contains(&lz) && mask & (1u64 << (lz * 8 + lx)) != 0
    };
    let natives: Vec<i32> = inner
        .section
        .slots()
        .filter(|(_, s)| in_mask(s.chunk) && (tick.is_none() || s.ticked != tick) && !s.pending)
        .filter(|(id, _)| {
            extras
                .only
                .as_ref()
                .is_none_or(|only| only.binary_search(id).is_ok())
        })
        .map(|(id, _)| id)
        .collect();
    // A dragon's arena: its owner's, with the native mobs of the group's
    // other sections it may touch.
    let dragon = natives
        .iter()
        .any(|id| inner.section.get(*id).is_some_and(|s| tick::dragon(&s.mob)))
        .then(|| {
            let mut dw = extras.dragon.take().unwrap_or_default();
            for s in &sections {
                if s.key == key {
                    continue;
                }
                if let Some(other) = s.native.as_ref().and_then(|n| ms::sibling(n)) {
                    dw.others.extend(dragon_targets(&rules, &other.section));
                }
            }
            dw.flame_uuid = fresh_uuid();
            dw
        });
    let region = scene_region.or_else(|| {
        sections
            .iter()
            .find(|s| s.key == key)
            .map(|s| s.region.clone())
    });

    // Every mob of the section in id order, then the solids that take no
    // turn.
    let mut order: Vec<Entrant> = Vec::with_capacity(natives.len());
    let mut bodies = Vec::with_capacity(natives.len());
    let mut colliders: Vec<(usize, Option<Aabb>)> = Vec::new();
    let travel: HashMap<u16, Attributes> = HashMap::new();
    for &id in &natives {
        let i = order.len();
        let mob = &inner.section.get(id).ok_or_else(bad)?.mob;
        let ty = rules.of(&mob.body.entity_type).ok_or_else(bad)?;
        // Its whole input is built at its own step.
        bodies.push(tick::kernel_body(&rules, &families, ty, mob));
        if let Some(b) = families
            .kinds
            .kind(ty.id)
            .and_then(|kind| kind.collider(&mob.body, mob.position))
        {
            colliders.push((i, Some(aabb6(b))));
        }
        order.push(Entrant::Native(id));
    }
    if order.is_empty() {
        let out = (crate::bytes(env, Vec::new()), Vec::<Term>::new());
        return Ok((random, out.0, out.1).encode(env));
    }
    let reach = {
        let boxes: Vec<Aabb> = bodies
            .iter()
            .map(|m| {
                let [x, y, z] = m.position;
                let (w, h) = (m.size.width / 2.0, m.size.height);
                Aabb::new([x - w, y, z - w], [x + w, y + h, z + w])
            })
            .collect();
        physics_nif::union(&boxes).map(|b| b.inflate(66.0))
    };
    // The group's native solids within reach that take no turn here.
    if let Some(reach) = reach {
        let mut add = |section: &MobSection, own: bool| {
            for (id, slot) in section.slots() {
                if own && natives.binary_search(&id).is_ok() {
                    continue;
                }
                let mob = &slot.mob;
                let Some(ty) = rules.of(&mob.body.entity_type) else {
                    continue;
                };
                let Some(b) = families
                    .kinds
                    .kind(ty.id)
                    .and_then(|kind| kind.collider(&mob.body, mob.position))
                    .map(aabb6)
                else {
                    continue;
                };
                if !b.intersects(&reach) {
                    continue;
                }
                let attributes = tick::travel_attributes(&rules, ty, mob);
                let mut m = tick::kernel_input(&rules, &families, ty, mob, attributes);
                fix(&mut m);
                colliders.push((bodies.len(), Some(b)));
                bodies.push(m);
                order.push(Entrant::Fixed);
            }
        };
        if inner.section.solids() > 0 {
            add(&inner.section, true);
        }
        for s in &sections {
            if s.key == key {
                continue;
            }
            if let Some(native) = &s.native {
                if let Some(other) = ms::sibling(native).filter(|o| o.section.solids() > 0) {
                    add(&other.section, false);
                }
            }
        }
    }

    // The blocks: the section's resident view, or the scene's.
    let scene_owned;
    let view: &View<SnapshotArc> = match scene_view {
        None => sync(&mut inner.resident, key, &sections)?,
        Some(term) => {
            let region_box = physics_nif::union(
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
            .ok_or_else(bad)?;
            scene_owned = physics_nif::owned_view(term, physics, &region_box)?;
            &scene_owned
        }
    };

    // The level: the group's scalars and this section's extras.
    let mut env_level = env_level;
    if let Some(knots) = extras.knots {
        env_level.knots = knots;
    }
    if let Some(goals) = extras.goals {
        env_level.goals = goals;
    }
    // The POI claims (`World.pois`): this section's villagers' and its
    // siblings' as they keep them.
    let mut pois = HashMap::new();
    merge(
        &mut pois,
        &valimc_core::mobs::ai::pois::store_claims(
            rules.facts,
            inner.section.slots().map(|(_, s)| &s.mob),
            &env_level.dimension,
        ),
    );
    for s in &sections {
        if s.key != key {
            if let Some(native) = &s.native {
                if let Some(other) = ms::sibling(native) {
                    merge(&mut pois, &other.claims);
                }
            }
        }
    }
    let mut parts = LevelParts {
        env: env_level,
        moving: Moving {
            events: extras.events,
            pois,
            located: {
                let mut kept = std::mem::take(&mut inner.located);
                kept.extend(extras.located);
                kept
            },
            loot_seeds: extras.loot_seeds.into_iter().collect(),
        },
        loot,
    };

    // Each native mob's fallback where its turn may need one.
    let kept: std::collections::HashSet<i32> = natives
        .iter()
        .copied()
        .filter(|id| {
            inner
                .section
                .get(*id)
                .is_some_and(|s| keeps(&inner.section, view, &s.mob))
        })
        .collect();
    let mut state = Tick::begin(&mut inner.section, order, tick, |id| kept.contains(&id));
    let border = parts.env.border.map(|b| (b[0], b[1], b[2], b[3]));
    let mut ticker = Ticker::new(bodies);
    for (i, b) in colliders {
        ticker.collider(i, ticker.current[i].position, b);
    }

    let world = World {
        source: view,
        facts: physics,
        border: crate::player::border(border),
        entities: &[],
    };
    let tw = TurnWorld {
        rules: &rules,
        motion: &families,
        kinds: families.kinds,
        world: &world,
        players: &pushers[..],
        mob_griefing: parts.env.rules.mob_griefing,
        travel: std::cell::RefCell::new(travel),
        dragon: dragon.as_ref(),
    };
    let section_env = ms::section_env(&rules, region.as_deref(), view, &parts.env);
    let air = AirWhereUnreadable(view);
    let blocks = parts.env.blocks(view, &air);
    let random = LegacyRandom::from_state(random as u64).ok_or_else(bad)?;
    let locator = parts.env.locate.map(mob_section_level::FixedLocator);
    let mut level = parts.env.level(blocks, &section_env, rules.facts, random)?;
    parts.moving.give(&mut level);
    level.loot = parts.loot.as_deref();
    level.locator = locator
        .as_ref()
        .map(|l| l as &dyn valimc_core::mobs::level::Locator);
    // `AI.prepare/2` over the level random: the mobs' minds, the sensing of
    // every mob, the brain mobs' reactions.
    let mut ai = {
        let turning = &state.turns;
        let mobs = inner.section.mobs_mut(|id| turning.contains_key(&id));
        SectionAi::begin(ms::ctx(&rules)?, &mut level, players, extras.items, mobs)
    };
    state.run(&mut inner.section, &tw, &mut ai, &mut ticker);
    drop(ai);
    let random = level.random.seed as i64;
    parts.moving.keep(&mut level);
    drop(level);
    keep_located(inner, &mut parts.moving);
    let velocities = ticker.finish(&pushers);
    let (moved, changes) = finish_out(
        env,
        &rules,
        physics,
        inner,
        state,
        &velocities,
        region.as_deref(),
        &parts.env.dimension,
        parts.env.min_y as f64 - 64.0,
    )?;
    Ok((random, moved, changes).encode(env))
}

/// The bosses never travel through portals (`canUsePortal`).
const BOSSES: [&str; 2] = ["minecraft:ender_dragon", "minecraft:wither"];

/// The tick's end: `(moved, changes)` (see the module docs). A mob that
/// touched a portal renews its cooldown, or, off cooldown, tells its owner
/// `{:portal, kind, cell}` among its effects.
#[allow(clippy::too_many_arguments)]
fn finish_out<'a>(
    env: Env<'a>,
    rules: &Rules,
    physics: &valimc_core::physics::facts::Facts,
    inner: &mut ms::Inner,
    state: Tick,
    velocities: &[[f64; 3]],
    region: Option<&Region>,
    dimension: &valimc_core::mobs::term::Atom,
    void: f64,
) -> NifResult<(Term<'a>, Vec<Term<'a>>)> {
    use valimc_core::mobs::term::Value;
    let steps = tick::finish(&mut inner.section, state, velocities, void);
    let section = &mut inner.section;
    // Portal sweeps read the section's own blocks: none where it holds no
    // portal (VMC-081j).
    let store = match region {
        Some(r) => Some(r.store.lock().map_err(|_| bad())?)
            .filter(|s| s.cells.may_hold(valimc_core::cell_count::PORTAL)),
        None => None,
    };
    let mut moved: Vec<u8> = Vec::with_capacity(steps.len() * 77);
    let mut changes = Vec::new();
    for step in steps {
        let slot = section.peek_kept(step.id).ok_or_else(bad)?;
        let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
            continue;
        };
        let mut effects: Vec<Value> = step
            .effects
            .iter()
            .filter_map(|e| ms::effect(rules, e))
            .collect();
        // Portals it met on its way (`EntityPortals.contacts/4`).
        if let Some(store) = &store {
            if valimc_core::mobs::living::mob::alive(&slot.mob.body.mob)
                && !BOSSES.contains(&slot.mob.body.entity_type.as_str())
            {
                let touch = tick::portal_touch(
                    rules.facts,
                    physics,
                    (ty.facts.width, ty.facts.height),
                    step.from,
                    slot.mob.position,
                    |cells| {
                        cells
                            .iter()
                            .map(|c| store.get(c[0], c[1], c[2]).ok())
                            .collect()
                    },
                );
                if let Some((kind, cell)) = touch {
                    if slot.mob.body.portal_cooldown > 0 {
                        slot.mob.body.portal_cooldown = valimc_core::mobs::tick::PORTAL_COOLDOWN;
                    } else {
                        effects.push(Value::tuple([
                            Value::atom("portal"),
                            Value::atom(kind.name()),
                            Value::ivec3([cell[0].into(), cell[1].into(), cell[2].into()]),
                        ]));
                    }
                }
            }
        }
        if step.moved && !step.outside {
            let b = &slot.mob.body;
            moved.extend_from_slice(&step.id.to_be_bytes());
            for v in slot.mob.position {
                moved.extend_from_slice(&v.to_be_bytes());
            }
            for v in [b.yaw, b.pitch, b.head_yaw] {
                moved.extend_from_slice(&v.to_be_bytes());
            }
            for v in b.velocity {
                moved.extend_from_slice(&v.to_be_bytes());
            }
            moved.push(b.on_ground as u8);
        }
        let row_changed = slot
            .row
            .as_ref()
            .is_none_or(|k| !k.matches(rules, ty, &slot.mob))
            || !slot
                .shown
                .as_ref()
                .is_some_and(|s| publish::shows(rules, ty, &slot.mob, s));
        if row_changed || step.outside || !step.events.is_empty() || !effects.is_empty() {
            let row = if row_changed || step.outside {
                mob_term::encode(env, &ms::row(rules, slot, false))?
            } else {
                rustler::types::atom::nil().encode(env)
            };
            changes.push(
                (
                    step.id,
                    row,
                    mob_term::encode(env, &ms::events_value(rules, &step.events))?,
                    mob_term::encode(env, &Value::List(effects))?,
                    step.outside.then(|| {
                        let p = slot.mob.position;
                        (p[0], p[1], p[2])
                    }),
                )
                    .encode(env),
            );
        }
    }
    drop(store);
    // The claims its villagers hold, which its siblings' ticks read.
    inner.claims = valimc_core::mobs::ai::pois::store_claims(
        rules.facts,
        inner.section.slots().map(|(_, s)| &s.mob),
        dimension,
    );
    Ok((crate::bytes(env, moved).encode(env), changes))
}

// ----------------------------------------------------------------- ageing

/// The timers of the section's native mobs for this game tick
/// (`Store.age_chunks/4`'s, `tick::age`): `budget` the ticks owed by chunk
/// `[{{cx, cz}, ticks}]`; `min_y` the dimension's bottom. `[{id, row | nil,
/// events, done}]` for each mob with a new row, events, or whose death
/// animation ended or that fell 64 below the world (`done`).
#[rustler::nif]
fn mob_section_age_tick<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    tick: Option<i64>,
    budget: Vec<((i32, i32), u32)>,
    min_y: f64,
) -> NifResult<Term<'a>> {
    let rules = ms::rules()?;
    let mut inner = ms::owned(env, &res)?;
    let budget: HashMap<(i32, i32), u32> = budget.into_iter().collect();
    let aged = tick::age(&mut inner.section, &budget, tick, min_y - 64.0);
    let mut out = Vec::new();
    for a in aged {
        let slot = inner.section.peek_kept(a.id).ok_or_else(bad)?;
        let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
            continue;
        };
        let done = a.done || slot.mob.position[1] < min_y - 64.0;
        let row_changed = a.changed
            && (slot
                .row
                .as_ref()
                .is_none_or(|k| !k.matches(&rules, ty, &slot.mob))
                || !slot
                    .shown
                    .as_ref()
                    .is_some_and(|s| publish::shows(&rules, ty, &slot.mob, s)));
        if !(row_changed || done || !a.events.is_empty()) {
            continue;
        }
        let row = if row_changed {
            mob_term::encode(env, &ms::row(&rules, slot, false))?
        } else {
            rustler::types::atom::nil().encode(env)
        };
        out.push(
            (
                a.id,
                row,
                mob_term::encode(env, &ms::events_value(&rules, &a.events))?,
                done,
            )
                .encode(env),
        );
    }
    Ok(out.encode(env))
}

/// The section's mobs as redstone's entity contacts see them
/// (`Redstone.entity_box/1`: their type's box where their store holds them,
/// living): `{count, packed}`, each `<<min x, y, z, max x, y, z ::
/// float-64, 1>>` as the rules' context packs an entity. `chunks`: `:all`,
/// or the chunks holding a contact block, and only the mobs whose cells
/// reach one of them are packed (VMC-081j).
#[rustler::nif]
fn mob_section_contacts<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    chunks: Term<'a>,
) -> NifResult<(usize, rustler::Binary<'a>)> {
    let rules = ms::rules()?;
    let only: Option<std::collections::HashSet<(i32, i32)>> =
        if chunks.decode::<Atom>().ok() == Some(atoms::all()) {
            None
        } else {
            Some(chunks.decode::<Vec<(i32, i32)>>()?.into_iter().collect())
        };
    let inner = ms::read(&res)?;
    let mut out = Vec::with_capacity(inner.section.len() * 49);
    let mut n = 0;
    for (_, slot) in inner.section.slots() {
        let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
            continue;
        };
        // A mob whose move out waits is where its store still holds it.
        let [x, y, z] = match (&slot.before, slot.start) {
            (Some(before), _) if slot.pending => before.0.position,
            (_, Some(start)) if slot.pending => start,
            _ => slot.mob.position,
        };
        let half = ty.facts.width / 2.0;
        if let Some(only) = &only {
            // The chunks of the cells its box, less 1e-5 each way, touches.
            let chunk = |v: f64| ((v.floor() as i64) >> 4) as i32;
            let (x0, x1) = (chunk(x - half + 1.0e-5), chunk(x + half - 1.0e-5));
            let (z0, z1) = (chunk(z - half + 1.0e-5), chunk(z + half - 1.0e-5));
            if !(x0..=x1).any(|cx| (z0..=z1).any(|cz| only.contains(&(cx, cz)))) {
                continue;
            }
        }
        for v in [
            x - half,
            y,
            z - half,
            x + half,
            y + ty.facts.height,
            z + half,
        ] {
            out.extend_from_slice(&v.to_be_bytes());
        }
        out.push(1);
        n += 1;
    }
    Ok((n, crate::bytes(env, out)))
}

/// The idle times of mobs `ids` restart (a player came within 32 blocks,
/// `Store.reset_idle/2`).
#[rustler::nif]
fn mob_section_reset_idle(
    env: Env,
    res: ResourceArc<MobSectionRes>,
    ids: Vec<i32>,
) -> NifResult<Atom> {
    let mut inner = ms::owned(env, &res)?;
    for id in ids {
        if let Some(slot) = inner.section.peek_kept(id) {
            slot.idle = 0;
        }
    }
    Ok(atoms::ok())
}

/// Mob `id`'s row (the store's `NativeBody`) as it is now, on demand.
#[rustler::nif]
fn mob_section_body<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
) -> NifResult<Term<'a>> {
    let rules = ms::rules()?;
    let inner = ms::read(&res)?;
    let slot = inner
        .section
        .get(id)
        .ok_or_else(|| rustler::Error::Term(Box::new(atoms::missing())))?;
    let (idle, lived) = inner.section.counters(slot);
    let mut copy = slot.clone();
    let p = copy.mob.position;
    let row = ms::row(&rules, &mut copy, true);
    Ok((
        (p[0], p[1], p[2]),
        mob_term::encode(env, &row)?,
        idle,
        lived,
    )
        .encode(env))
}

/// `Actor.crystal_destroyed/6` of the native dragon `id`: the end crystal
/// `crystal` it may heal from was destroyed (`direct` `{uuid, entity_id,
/// position}`, the explosion's direct entity) by `striker` (`{id, position,
/// height, eligible, attacker}` or nil) over its arena (`arena`, as the
/// tick's `dragon` extra), its level `level` (`RegionData.native_level/2`'s)
/// over the group's sections (`world`): its head hit and a holding dragon's
/// strafe. `{:ok, {nil, events, {position, row}}}`.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn mob_section_dragon_crystal<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    world: ResourceArc<MobWorldRes>,
    level: Term<'a>,
    id: i32,
    crystal: Term<'a>,
    direct: (Term<'a>, i32, Vec3),
    striker: Option<(i64, Vec3, f64, bool, Term<'a>)>,
    arena: Term<'a>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::boss::dragon::{
        self as dragon,
        actor::{self, CrystalHit, Striker},
        Arena, Player,
    };
    let rules = ms::rules()?;
    let facts = rules.facts.dragon.as_ref().ok_or_else(bad)?;
    let crystal = uuid16(crystal)?;
    let direct = CrystalHit {
        uuid: uuid16(direct.0)?,
        entity_id: direct.1,
        position: [direct.2 .0, direct.2 .1, direct.2 .2],
    };
    let striker = match striker {
        Some((pid, p, height, eligible, attacker)) => Some(Striker {
            player: Player {
                id: pid,
                position: [p.0, p.1, p.2],
                height,
            },
            eligible,
            attacker: ms::attacker(&mob_term::decode(attacker)?)?,
        }),
        None => None,
    };
    let mut dw = dragon_world(arena)?;
    dw.flame_uuid = fresh_uuid();
    let level_env = LevelEnv::decode(level)?;
    let (players, sections) = {
        let w = world.inner.lock().map_err(|_| bad())?;
        (w.players.clone(), w.sections.clone())
    };
    let mut guard = ms::owned(env, &res)?;
    let inner = &mut *guard;
    let key = inner.section.section;
    let region = sections
        .iter()
        .find(|s| s.key == key)
        .map(|s| s.region.clone());
    let view = sync(&mut inner.resident, key, &sections)?;
    let section_env = ms::section_env(&rules, region.as_deref(), view, &level_env);
    let air = AirWhereUnreadable(view);
    let blocks = level_env.blocks(view, &air);
    let level = level_env.level(blocks, &section_env, rules.facts, LegacyRandom { seed: 0 })?;
    let slot = inner
        .section
        .get_mut(id)
        .ok_or_else(|| rustler::Error::Term(Box::new(atoms::missing())))?;
    let height = |x: i64, z: i64| tick::arena_height(&level, x, z);
    let arena = Arena {
        height: &height,
        podium: [0, height(0, 0), 0],
        crystals: dw.crystals,
        crystal_bodies: dw.crystal_bodies,
        mobs: Vec::new(),
        previous_kill: dw.previous_kill,
        flame_uuid: dw.flame_uuid,
    };
    let mut denv = dragon::environment(facts, rules.facts, &level, &slot.mob, &arena, &players);
    let events = actor::crystal_destroyed(
        &rules,
        &mut slot.mob,
        &crystal,
        &direct,
        striker.as_ref(),
        &mut denv,
    );
    let row = ms::row(&rules, slot, false);
    let p = slot.mob.position;
    inner.section.relocate(id);
    Ok((
        atoms::ok(),
        (
            rustler::types::atom::nil(),
            mob_term::encode(env, &ms::events_value(&rules, &events))?,
            ((p[0], p[1], p[2]), mob_term::encode(env, &row)?),
        ),
    )
        .encode(env))
}

/// A POI ticket count: `{{x, y, z}, n}`.
type Claim = ((i32, i32, i32), i32);

/// The POI tickets the section's villagers hold as of its last tick
/// (`Pois.store_claims/2` of its native mobs): `[{{x, y, z}, n}]`.
#[rustler::nif]
fn mob_section_claims(res: ResourceArc<MobSectionRes>) -> NifResult<Vec<Claim>> {
    let inner = ms::read(&res)?;
    Ok(inner
        .claims
        .iter()
        .map(|(p, n)| ((p[0], p[1], p[2]), *n))
        .collect())
}
