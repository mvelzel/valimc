//! A group's natural spawning over resident inputs (VMC-081g2).
//!
//! The group's `MobWorld` keeps, per section, what spawning reads beside
//! the blocks: the Region resource and native mob section, the simulated
//! and absent chunks (as masks), the owner's own mobs and living bodies, its
//! spawner blocks with their countdowns, and the kept starts of structures
//! that override spawns. The owner pushes a part only when its source
//! changed (`mob_world_spawn_set`). The counts toward the caps are the
//! native sections' censuses (`valimc_core::spawning::census`), refreshed
//! from the mobs that changed since the last tick, plus the owner's mobs.
//! A tick (`mob_world_spawn`) reads blocks through each section's store,
//! locked when first read, and gathers the potential charges only when a
//! spawn's biome has spawn costs.
//!
//! What it returns: the spawns, the mobs that despawn and those whose idle
//! time restarts (with their sections), the two randoms after the tick and
//! the spawner blocks' spawns.

use crate::mob_section::{self as ms, MobSectionRes};
use crate::mob_tick::{MobWorldRes, WorldState};
use crate::region::Region;
use crate::spawn::{self, Environment, Out, SPAWN};
use rustler::{Atom, Env, NifMap, NifResult, ResourceArc, Term};
use std::cell::{Cell, OnceCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{MutexGuard, OnceLock, PoisonError};
use valimc_core::column::{Column, ColumnStore, HEIGHT, MIN_Y};
use valimc_core::flags::BlockFlags;
use valimc_core::mobs::combat::Rules;
use valimc_core::mobs::section::Slot;
use valimc_core::physics::Aabb;
use valimc_core::spawning::block_spawner;
use valimc_core::spawning::census::Counted;
use valimc_core::spawning::facts::{Category, Facts};
use valimc_core::spawning::level::Level;
use valimc_core::spawning::rules::{overlaps, Player, World};
use valimc_core::spawning::spawner::{self, Charges, Despawn, Drawn, SpawnState, Tick};
use valimc_core::spawning::structures::{Area, Areas, Kept};
use valimc_core::worldgen::random::Random;

mod atoms {
    rustler::atoms! {
        ok, drop, region, native, simulated, absent, elixir, spawners, structures, not_owner,
    }
}

/// An owner's mob row: `{id, type, {x, y, z}, flags, idle, lived}` (flags:
/// 1 persistent, 2 alive in a simulated chunk).
type Row = (u32, u16, (f64, f64, f64), u8, i32, i32);

type Box6 = (f64, f64, f64, f64, f64, f64);

/// A spawner block as its owner pushes it (`BaseSpawner.load`): its
/// position, a stamp of its saved compound, its saved countdown and
/// configuration.
#[derive(NifMap)]
struct PushedSpawner {
    position: (i32, i32, i32),
    stamp: i64,
    delay: i32,
    kind: Option<u16>,
    min_delay: i32,
    max_delay: i32,
    count: i32,
    max_nearby: i32,
    player_range: i32,
    spawn_range: i32,
}

/// A spawner block kept here, with its running countdown (None: it starts
/// again from its saved one).
struct Spawner {
    pos: [i32; 3],
    stamp: i64,
    saved: i32,
    config: block_spawner::Config,
    delay: Cell<Option<i32>>,
}

/// One section's resident inputs.
struct Section {
    region: ResourceArc<Region>,
    native: Option<ResourceArc<MobSectionRes>>,
    simulated: u64,
    absent: u64,
    elixir: Vec<Row>,
    bodies: Vec<Aabb>,
    spawners: Vec<Spawner>,
    areas: Areas,
}

/// A group's resident spawning inputs, by section key.
#[derive(Default)]
pub(crate) struct Resident {
    sections: BTreeMap<(i32, i32), Section>,
}

/// The chunk bit of a section's 8 × 8 mask (`NativeMobs.simulated_mask/2`).
fn bit(chunk: (i32, i32)) -> u64 {
    1u64 << ((chunk.1 & 7) * 8 + (chunk.0 & 7))
}

fn key_of(chunk: (i32, i32)) -> (i32, i32) {
    (chunk.0 >> 3, chunk.1 >> 3)
}

fn chunks_of(key: (i32, i32), mask: u64) -> impl Iterator<Item = (i32, i32)> {
    (0..64i32)
        .filter(move |i| mask >> i & 1 != 0)
        .map(move |i| (key.0 * 8 + i % 8, key.1 * 8 + i / 8))
}

fn owned_world<'a>(env: Env, world: &'a MobWorldRes) -> NifResult<MutexGuard<'a, WorldState>> {
    if env.pid() != *world.owner.lock().map_err(|_| rustler::Error::BadArg)? {
        return Err(rustler::Error::Term(Box::new(atoms::not_owner())));
    }
    world.inner.lock().map_err(|_| rustler::Error::BadArg)
}

// ------------------------------------------------------------ the pushes

fn spawner_of(p: PushedSpawner, before: Option<&Spawner>) -> Spawner {
    let (x, y, z) = p.position;
    let pos = [x, y, z];
    Spawner {
        pos,
        stamp: p.stamp,
        saved: p.delay,
        config: block_spawner::Config {
            kind: p.kind,
            min_delay: p.min_delay,
            max_delay: p.max_delay,
            count: p.count,
            max_nearby: p.max_nearby,
            player_range: p.player_range,
            spawn_range: p.spawn_range,
        },
        // The countdown runs on while its compound is the same.
        delay: Cell::new(
            before
                .filter(|b| b.pos == pos && b.stamp == p.stamp)
                .and_then(|b| b.delay.get()),
        ),
    }
}

/// Changes the group's resident spawning inputs: per section key `:drop`
/// or a map of any of `region`, `native` (nil for none), `simulated` and
/// `absent` (masks), `elixir` (`{rows, boxes}`), `spawners` and
/// `structures` (`[{chunk, kept}]`). A new section names its region. With
/// `reset`, the sections `changes` does not name are dropped first.
#[rustler::nif]
fn mob_world_spawn_set<'a>(
    env: Env<'a>,
    world: ResourceArc<MobWorldRes>,
    reset: bool,
    changes: Vec<((i32, i32), Term<'a>)>,
) -> NifResult<Atom> {
    let facts = SPAWN.get().ok_or(rustler::Error::BadArg)?;
    let mut inner = owned_world(env, &world)?;
    let resident = &mut inner.spawn;
    if reset {
        let named: HashSet<(i32, i32)> = changes.iter().map(|(k, _)| *k).collect();
        resident.sections.retain(|k, _| named.contains(k));
    }
    for (key, change) in changes {
        if change.is_atom() {
            if change.decode::<Atom>()? == atoms::drop() {
                resident.sections.remove(&key);
            }
            continue;
        }
        let get = |name: Atom| change.map_get(name).ok();
        let section = match resident.sections.entry(key) {
            std::collections::btree_map::Entry::Occupied(e) => e.into_mut(),
            std::collections::btree_map::Entry::Vacant(e) => e.insert(Section {
                region: get(atoms::region())
                    .ok_or(rustler::Error::BadArg)?
                    .decode()?,
                native: None,
                simulated: 0,
                absent: 0,
                elixir: Vec::new(),
                bodies: Vec::new(),
                spawners: Vec::new(),
                areas: Areas::new(),
            }),
        };
        if let Some(t) = get(atoms::region()) {
            section.region = t.decode()?;
        }
        if let Some(t) = get(atoms::native()) {
            section.native = t.decode()?;
        }
        if let Some(t) = get(atoms::simulated()) {
            section.simulated = t.decode()?;
        }
        if let Some(t) = get(atoms::absent()) {
            section.absent = t.decode()?;
        }
        if let Some(t) = get(atoms::elixir()) {
            let (rows, boxes): (Vec<Row>, Vec<Box6>) = t.decode()?;
            section.elixir = rows;
            section.bodies = boxes
                .into_iter()
                .map(|(a, b, c, d, e, f)| Aabb::from_array([a, b, c, d, e, f]))
                .collect();
        }
        if let Some(t) = get(atoms::spawners()) {
            let pushed: Vec<PushedSpawner> = t.decode()?;
            let before = std::mem::take(&mut section.spawners);
            section.spawners = pushed
                .into_iter()
                .map(|p| {
                    let (x, y, z) = p.position;
                    let old = before.iter().find(|b| b.pos == [x, y, z]);
                    spawner_of(p, old)
                })
                .collect();
        }
        if let Some(t) = get(atoms::structures()) {
            let kept: Vec<((i32, i32), Vec<spawn::Kept>)> = t.decode()?;
            section.areas = spawn::areas(facts, &kept).map_err(crate::raise)?;
        }
    }
    Ok(atoms::ok())
}

/// A spawner block's position and running countdown.
type Countdown = ((i32, i32, i32), Option<i32>);

/// The spawner blocks' running countdowns, `[{position, delay}]` (nil: it
/// starts from its saved one), by position.
#[rustler::nif]
fn mob_world_spawners(env: Env, world: ResourceArc<MobWorldRes>) -> NifResult<Vec<Countdown>> {
    let inner = owned_world(env, &world)?;
    let mut out: Vec<_> = inner
        .spawn
        .sections
        .values()
        .flat_map(|s| s.spawners.iter())
        .map(|s| ((s.pos[0], s.pos[1], s.pos[2]), s.delay.get()))
        .collect();
    out.sort();
    Ok(out)
}

// -------------------------------------------------------------- the level

/// A section's store lock, taken when the section is first read.
type Lock<'r> = OnceCell<MutexGuard<'r, ColumnStore>>;

/// The group's blocks, light, heightmaps and biomes over its sections'
/// stores (the chunks `Live` would hold: in a section, not absent). The
/// last chunk read keeps its column at hand: a chunk's categories read the
/// same column, a pack the ones beside it.
struct Stores<'g, 'r> {
    index: HashMap<(i32, i32), usize>,
    regions: Vec<&'r Region>,
    absent: Vec<u64>,
    locks: &'g [Lock<'r>],
    flags: &'g BlockFlags,
    zoom_seed: i64,
    plains: u16,
    last: Cell<Option<((i32, i32), usize)>>,
    column: Cell<Option<Chunk<'g>>>,
    biome: Cell<Option<([i32; 3], u16)>>,
}

/// A held chunk: its store and its column (None: the store's base profile).
#[derive(Clone, Copy)]
struct Chunk<'g> {
    at: (i32, i32),
    store: &'g ColumnStore,
    column: Option<&'g Column>,
}

impl<'g, 'r> Stores<'g, 'r> {
    fn section(&self, key: (i32, i32)) -> Option<usize> {
        if let Some((k, i)) = self.last.get() {
            if k == key {
                return Some(i);
            }
        }
        let i = *self.index.get(&key)?;
        self.last.set(Some((key, i)));
        Some(i)
    }

    fn store(&self, chunk: (i32, i32)) -> Option<&'g ColumnStore> {
        Some(self.chunk(chunk)?.store)
    }

    fn chunk(&self, at: (i32, i32)) -> Option<Chunk<'g>> {
        if let Some(c) = self.column.get() {
            if c.at == at {
                return Some(c);
            }
        }
        let i = self.section(key_of(at))?;
        if self.absent[i] & bit(at) != 0 {
            return None;
        }
        let region = self.regions[i];
        let store: &'g ColumnStore = self.locks[i]
            .get_or_init(|| region.store.lock().unwrap_or_else(PoisonError::into_inner));
        let c = Chunk {
            at,
            store,
            column: store.columns.get(&at),
        };
        self.column.set(Some(c));
        Some(c)
    }

    fn holds(&self, chunk: (i32, i32)) -> bool {
        self.section(key_of(chunk))
            .is_some_and(|i| self.absent[i] & bit(chunk) == 0)
    }
}

impl Level for Stores<'_, '_> {
    fn state(&self, p: [i32; 3]) -> Option<u16> {
        if !(MIN_Y..MIN_Y + HEIGHT as i32).contains(&p[1]) {
            return None;
        }
        let c = self.chunk((p[0] >> 4, p[2] >> 4))?;
        Some(match c.column {
            Some(column) => column.get(p[0], p[1], p[2]),
            None => c.store.layers[(p[1] - MIN_Y) as usize],
        })
    }

    fn light(&self, p: [i32; 3]) -> (u8, u8) {
        self.store((p[0] >> 4, p[2] >> 4))
            .and_then(|s| s.light_at(p[0], p[1], p[2]))
            .unwrap_or((0, 0))
    }

    fn height(&self, map: usize, x: i32, z: i32) -> i32 {
        let Some(Chunk { store, column, .. }) = self.chunk((x >> 4, z >> 4)) else {
            return MIN_Y;
        };
        let mask = 1u8 << map;
        MIN_Y
            + match column {
                Some(column) => valimc_core::column::height(
                    &column.sections,
                    (x & 15) as usize,
                    (z & 15) as usize,
                    self.flags,
                    mask,
                ) as i32,
                None => (0..HEIGHT)
                    .rev()
                    .find(|&y| self.flags.get(store.layers[y]) & mask != 0)
                    .map_or(0, |y| y as i32 + 1),
            }
    }

    fn biome(&self, p: [i32; 3]) -> u16 {
        if let Some((at, biome)) = self.biome.get() {
            if at == p {
                return biome;
            }
        }
        let quart = valimc_core::worldgen::surface::zoom(self.zoom_seed, p[0], p[1], p[2]);
        let biome = self
            .store((quart.0 >> 2, quart.2 >> 2))
            .and_then(|s| s.noise_biome(quart, self.plains))
            .unwrap_or(self.plains);
        self.biome.set(Some((p, biome)));
        biome
    }
}

// --------------------------------------------------------------- the tick

/// One tick's environment and switches.
#[derive(NifMap)]
struct Request {
    environment: Environment,
    /// `{x, y, z, spectator, creative}`.
    players: Vec<(f64, f64, f64, bool, bool)>,
    /// The world spawn in this dimension.
    respawn: Option<(i32, i32, i32)>,
    /// The `spawn_mobs` rule: chunks spawn at all.
    spawn_mobs: bool,
    /// Monsters spawn (not peaceful, `spawn_monsters`).
    enemies: bool,
    /// The persistent categories spawn this tick (every 400th).
    persistent: bool,
    random: u64,
    finalize: u64,
    /// Spawner blocks work, and the spawner block's state.
    spawners: bool,
    spawner_state: u16,
}

/// The tick's spawns, the mobs it discards and those whose idle time
/// restarts (each with its section), the two randoms after it and the
/// spawner blocks' spawns.
type Natural = (
    Vec<Out>,
    Vec<((i32, i32), u32)>,
    Vec<((i32, i32), u32)>,
    u64,
    u64,
    Vec<((i32, i32, i32), Vec<Out>)>,
);

/// What a native mob counts as: its type
/// (kept from before: a slot's type never changes) and its position's chunk,
/// toward its category unless persistent or from a bucket.
fn count(rules: &Rules, facts: &Facts, slot: &Slot, before: Option<&Counted>) -> Option<Counted> {
    let (kind, bucketable) = match before {
        Some(b) => (b.kind, b.bucketable),
        None => (
            rules.of(&slot.mob.body.entity_type)?.id,
            slot.mob.body.data.get("from_bucket").is_some(),
        ),
    };
    let persistent = slot.mob.body.mob.persistent || bucketable && from_bucket(slot);
    let category = facts
        .kind(kind)
        .map(|t| t.category)
        .filter(|&c| c != Category::Misc && !persistent)
        .map(|c| c.index() as u8);
    Some(Counted {
        kind,
        category,
        chunk: valimc_core::mobs::section::chunk_of(slot.mob.position),
        persistent,
        bucketable,
    })
}

fn from_bucket(slot: &Slot) -> bool {
    slot.mob
        .body
        .data
        .get("from_bucket")
        .and_then(|v| v.as_bool())
        == Some(true)
}

/// The types with a spawn cost in some biome: only their mobs carry
/// potential charges.
fn charged(facts: &Facts) -> &'static HashSet<u16> {
    static CHARGED: OnceLock<HashSet<u16>> = OnceLock::new();
    CHARGED.get_or_init(|| {
        facts
            .biomes
            .iter()
            .flat_map(|b| b.costs.keys().copied())
            .collect()
    })
}

/// The widest half-width of any type: a body farther than it from a box's
/// chunks cannot overlap it.
fn reach(rules: &Rules) -> f64 {
    static REACH: OnceLock<f64> = OnceLock::new();
    *REACH.get_or_init(|| {
        rules
            .facts
            .entities
            .types
            .iter()
            .map(|t| t.width / 2.0)
            .fold(0.0, f64::max)
    })
}

fn natural(env: Env, world: &MobWorldRes, request: Request) -> Result<Natural, String> {
    let facts = SPAWN.get().ok_or("spawn facts not installed")?;
    let flags = crate::facts::FLAGS
        .get()
        .ok_or("block facts not installed")?;
    let inner = owned_world(env, world).map_err(|_| "not the world's owner")?;
    let sections: Vec<((i32, i32), &Section)> =
        inner.spawn.sections.iter().map(|(&k, s)| (k, s)).collect();
    let rules = if sections.iter().any(|(_, s)| s.native.is_some()) {
        Some(ms::rules().map_err(|_| "mob facts not installed")?)
    } else {
        None
    };
    // The native sections, their censuses refreshed.
    let mut guards = Vec::with_capacity(sections.len());
    for (_, s) in &sections {
        let guard = match &s.native {
            Some(native) => Some(ms::read(native).map_err(|_| "poisoned mobs")?),
            None => None,
        };
        guards.push(guard);
    }
    if let Some(rules) = &rules {
        for guard in guards.iter_mut().flatten() {
            guard
                .section
                .census(|_, slot, before| count(rules, facts, slot, before));
        }
    }
    let locks: Vec<Lock> = sections.iter().map(|_| OnceCell::new()).collect();
    let level = Stores {
        index: sections
            .iter()
            .enumerate()
            .map(|(i, (k, _))| (*k, i))
            .collect(),
        regions: sections.iter().map(|(_, s)| &*s.region).collect(),
        absent: sections.iter().map(|(_, s)| s.absent).collect(),
        locks: &locks,
        flags,
        zoom_seed: request.environment.zoom_seed,
        plains: facts.plains,
        last: Cell::new(None),
        column: Cell::new(None),
        biome: Cell::new(None),
    };
    let players: Vec<Player> = request
        .players
        .iter()
        .map(|&(x, y, z, spectator, creative)| Player {
            pos: [x, y, z],
            spectator,
            creative,
        })
        .collect();
    let player_boxes = players
        .iter()
        .map(|p| {
            let [x, y, z] = p.pos;
            Aabb::from_array([x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3])
        })
        .collect();
    // The bodies kept here: the owners' living entities, the native mobs.
    let resident_bodies = |b: &Aabb| -> bool {
        let r = rules.as_ref().map_or(0.0, reach);
        let [x0, _, z0, x1, _, z1] = b.to_array();
        let c0 = (
            ((x0 - r).floor() as i32) >> 4,
            ((z0 - r).floor() as i32) >> 4,
        );
        let c1 = (
            ((x1 + r).floor() as i32) >> 4,
            ((z1 + r).floor() as i32) >> 4,
        );
        let (k0, k1) = (key_of(c0), key_of(c1));
        for kx in k0.0..=k1.0 {
            for kz in k0.1..=k1.1 {
                let Some(i) = level.index.get(&(kx, kz)).copied() else {
                    continue;
                };
                if sections[i].1.bodies.iter().any(|o| overlaps(b, o)) {
                    return true;
                }
                let (Some(guard), Some(rules)) = (&guards[i], &rules) else {
                    continue;
                };
                let section = &guard.section;
                let chunks = (c0.0..=c1.0).flat_map(|cx| (c0.1..=c1.1).map(move |cz| (cx, cz)));
                for id in section.in_chunks(chunks.filter(|&c| key_of(c) == (kx, kz))) {
                    let Some(slot) = section.get(id) else {
                        continue;
                    };
                    let Some(ty) = section
                        .census_read()
                        .get(id)
                        .and_then(|c| rules.facts.entities.types.get(c.kind as usize))
                    else {
                        continue;
                    };
                    let [x, y, z] = slot.mob.position;
                    let half = ty.width / 2.0;
                    let body = Aabb::from_array([
                        x - half,
                        y,
                        z - half,
                        x + half,
                        y + ty.height,
                        z + half,
                    ]);
                    if overlaps(b, &body) {
                        return true;
                    }
                }
            }
        }
        false
    };
    let world = spawn::world(
        &level,
        &request.environment,
        players,
        player_boxes,
        Some(&resident_bodies),
    )?;
    let block = |p: (f64, f64, f64)| [p.0.floor() as i32, p.1.floor() as i32, p.2.floor() as i32];
    // `createState`: the categories' counts and each player's local
    // counts; the charges when a spawn needs them.
    let mut counts = [0i32; 8];
    let mut local = vec![[0i32; 8]; world.players.len()];
    let mut add = |chunk: (i32, i32), n: &[u32; 8]| {
        for (c, &v) in n.iter().enumerate() {
            counts[c] += v as i32;
        }
        for i in spawner::near(&world, chunk) {
            for (c, &v) in n.iter().enumerate() {
                local[i][c] += v as i32;
            }
        }
    };
    for (_, s) in &sections {
        for row in &s.elixir {
            let Some(kind) = facts.kind(row.1) else {
                continue;
            };
            let p = block(row.2);
            if row.3 & 1 == 0
                && kind.category != Category::Misc
                && level.holds((p[0] >> 4, p[2] >> 4))
            {
                let mut one = [0; 8];
                one[kind.category.index()] = 1;
                add((p[0] >> 4, p[2] >> 4), &one);
            }
        }
    }
    for guard in guards.iter().flatten() {
        for (chunk, n) in guard.section.census_read().by_chunk() {
            if level.holds(chunk) {
                add(chunk, n);
            }
        }
    }
    let charges = || -> Charges {
        let charged = charged(facts);
        let mut out = Charges::new();
        let mut charge = |kind: u16, at: [i32; 3]| {
            if !charged.contains(&kind) || !level.holds((at[0] >> 4, at[2] >> 4)) {
                return;
            }
            if let Some(&(_, c)) = facts.biome(level.biome(at)).costs.get(&kind) {
                if c != 0.0 {
                    out.push((at, c));
                }
            }
        };
        for (_, s) in &sections {
            for row in &s.elixir {
                let counted = facts
                    .kind(row.1)
                    .is_some_and(|k| k.category != Category::Misc);
                if row.3 & 1 == 0 && counted {
                    charge(row.1, block(row.2));
                }
            }
        }
        for guard in guards.iter().flatten() {
            let section = &guard.section;
            let mut ids: Vec<(i32, u16)> = section
                .census_read()
                .entries()
                .filter(|(_, c)| c.category.is_some() && charged.contains(&c.kind))
                .map(|(id, c)| (id, c.kind))
                .collect();
            ids.sort_unstable();
            for (id, kind) in ids {
                if let Some(slot) = section.get(id) {
                    let [x, y, z] = slot.mob.position;
                    charge(kind, block((x, y, z)));
                }
            }
        }
        out
    };
    let state = SpawnState::resident(spawner::spawnable_chunks(&world), counts, local, &charges);
    let categories = spawner::categories(&world, &state, request.enemies, request.persistent);
    let simulated = |c: (i32, i32)| {
        level
            .section(key_of(c))
            .is_some_and(|i| sections[i].1.simulated & bit(c) != 0)
            && level.holds(c)
    };
    let ticking = |c: (i32, i32)| {
        simulated(c)
            && world.within_border((c.0 * 16) as f64, (c.1 * 16) as f64)
            && world.within_border((c.0 * 16 + 15) as f64, (c.1 * 16 + 15) as f64)
    };
    let areas = SectionAreas {
        level: &level,
        sections: &sections,
    };
    let mut tick = Tick {
        world: &world,
        state,
        random: Random::legacy_at(request.random),
        spawned: Vec::new(),
        ticking: &ticking,
        respawn: request.respawn.map(|(x, y, z)| [x, y, z]),
        caps: true,
        structures: &areas,
    };
    // `collectSpawningChunks` then `Util.shuffle` with the level random.
    let mut chunks: Vec<(i32, i32)> = if request.spawn_mobs {
        sections
            .iter()
            .flat_map(|(k, s)| chunks_of(*k, s.simulated))
            .filter(|&c| level.holds(c) && spawner::near(&world, c).next().is_some())
            .collect()
    } else {
        Vec::new()
    };
    chunks.sort_unstable();
    spawner::shuffle(&mut chunks, &mut tick.random);
    let mut finalize = Random::legacy_at(request.finalize);
    if !categories.is_empty() {
        for chunk in chunks {
            if ticking(chunk) {
                tick.chunk(chunk, &categories, &mut Drawn(&mut finalize));
            }
        }
    }
    // `checkDespawn`, after the spawning as vanilla's entity tick: the
    // owners' mobs, then the native ones, section by section in id order.
    let (mut discarded, mut reset) = (Vec::new(), Vec::new());
    let mut check = |key: (i32, i32),
                     id: u32,
                     kind: u16,
                     pos: [f64; 3],
                     persistent: bool,
                     idle: i32,
                     lived: i32| {
        let Some(kind) = facts.kind(kind) else {
            return;
        };
        match spawner::despawn(&world, kind, pos, persistent, idle, lived, &mut finalize) {
            Despawn::Discard => discarded.push((key, id)),
            Despawn::Reset if idle > 0 => reset.push((key, id)),
            _ => {}
        }
    };
    for (key, s) in &sections {
        for &(id, kind, (x, y, z), flags, idle, lived) in &s.elixir {
            if flags & 2 != 0 {
                check(*key, id, kind, [x, y, z], flags & 1 != 0, idle, lived);
            }
        }
    }
    let clamp = |v: i64| v.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
    for ((key, s), guard) in sections.iter().zip(&guards) {
        let Some(guard) = guard else {
            continue;
        };
        let section = &guard.section;
        let census = section.census_read();
        // In id order, those whose chunk simulates.
        for (id, slot) in section.slots() {
            if key_of(slot.chunk) != *key || s.simulated & bit(slot.chunk) == 0 {
                continue;
            }
            let Some(c) = census.get(id) else {
                continue;
            };
            if !valimc_core::mobs::living::mob::alive(&slot.mob.body.mob) {
                continue;
            }
            check(
                *key,
                id as u32,
                c.kind,
                slot.mob.position,
                c.persistent,
                clamp(slot.idle),
                clamp(slot.lived),
            );
        }
    }
    let mut random = tick.random;
    let spawned: Vec<Out> = tick.spawned.iter().map(spawn::out).collect();
    // Spawner blocks tick after the entities (`tickBlockEntities`): they
    // count the mobs left and the tick's natural spawns. Out of a simulated
    // chunk a countdown starts again from the saved one.
    let mut requested: Vec<(usize, usize)> = Vec::new();
    for (i, (_, s)) in sections.iter().enumerate() {
        for (j, spawner) in s.spawners.iter().enumerate() {
            let chunk = (spawner.pos[0] >> 4, spawner.pos[2] >> 4);
            if s.simulated & bit(chunk) == 0 || s.absent & bit(chunk) != 0 {
                spawner.delay.set(None);
            } else if request.spawners {
                requested.push((i, j));
            }
        }
    }
    let mut ticked = Vec::new();
    requested.retain(|&(i, j)| {
        let spawner = &sections[i].1.spawners[j];
        let range = spawner.config.player_range as f64;
        let [x, y, z] = spawner.pos.map(|v| v as f64 + 0.5);
        world.players.iter().any(|p| {
            let d = (p.pos[0] - x).powi(2) + (p.pos[1] - y).powi(2) + (p.pos[2] - z).powi(2);
            !p.spectator && d < range * range
        }) && level.state(spawner.pos) == Some(request.spawner_state)
    });
    if !requested.is_empty() {
        requested.sort_by_key(|&(i, j)| sections[i].1.spawners[j].pos);
        let gone: HashSet<((i32, i32), u32)> = discarded.iter().copied().collect();
        let mut mobs: block_spawner::Mobs = Vec::new();
        let mut push = |kind: u16, (x, y, z): (f64, f64, f64)| {
            if let Some(t) = facts.kind(kind) {
                mobs.push((kind, World::body(t, x, y, z)));
            }
        };
        for (key, s) in &sections {
            for row in &s.elixir {
                if !gone.contains(&(*key, row.0)) {
                    push(row.1, row.2);
                }
            }
        }
        for ((key, _), guard) in sections.iter().zip(&guards) {
            let Some(guard) = guard else {
                continue;
            };
            for (id, slot) in guard.section.slots() {
                let Some(c) = guard.section.census_read().get(id) else {
                    continue;
                };
                if !gone.contains(&(*key, id as u32)) {
                    let [x, y, z] = slot.mob.position;
                    push(c.kind, (x, y, z));
                }
            }
        }
        for s in &tick.spawned {
            push(s.kind, (s.pos[0], s.pos[1], s.pos[2]));
        }
        for (i, j) in requested {
            let kept = &sections[i].1.spawners[j];
            let mut spawner = block_spawner::Spawner {
                pos: kept.pos,
                delay: kept.delay.get().unwrap_or(kept.saved),
                config: kept.config,
            };
            let out =
                block_spawner::tick(&world, &mut spawner, &mut mobs, &mut random, &mut |_, _| {});
            kept.delay.set(Some(spawner.delay));
            if !out.spawned.is_empty() {
                let [x, y, z] = kept.pos;
                ticked.push(((x, y, z), out.spawned.iter().map(spawn::out).collect()));
            }
        }
    }
    Ok((
        spawned,
        discarded,
        reset,
        random.legacy_state().unwrap_or(0),
        finalize.legacy_state().unwrap_or(0),
        ticked,
    ))
}

/// The kept starts of the group's sections, each chunk's in its section.
struct SectionAreas<'a, 'g, 'r> {
    level: &'a Stores<'g, 'r>,
    sections: &'a [((i32, i32), &'r Section)],
}

impl Kept for SectionAreas<'_, '_, '_> {
    fn kept(&self, chunk: (i32, i32)) -> &[Area] {
        self.level
            .section(key_of(chunk))
            .and_then(|i| self.sections[i].1.areas.get(&chunk))
            .map_or(&[], Vec::as_slice)
    }
}

/// One tick of the group's natural spawning over its resident inputs (see
/// the module); a normal NIF, its dirty twin for many simulated chunks.
#[rustler::nif]
fn mob_world_spawn(
    env: Env,
    world: ResourceArc<MobWorldRes>,
    request: Request,
) -> NifResult<(Atom, Natural)> {
    crate::reply(natural(env, &world, request))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn mob_world_spawn_dirty(
    env: Env,
    world: ResourceArc<MobWorldRes>,
    request: Request,
) -> NifResult<(Atom, Natural)> {
    crate::reply(natural(env, &world, request))
}
