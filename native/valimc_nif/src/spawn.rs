//! Natural spawning (VMC-042a) over the Region resource: `spawn_facts_install`
//! parses the spawn facts once; `natural_spawn` (a normal NIF and its dirty
//! twin) runs one tick's spawning for a group's sections, `spawn_generated`
//! the creatures new chunks get. Both read the section's store and its
//! group's others without changing them, and draw from the random states
//! the caller passes in and gets back. `spawn_scene` (parity builds) replays
//! an oracle scene.

use crate::region::Region;
use rustler::{NifMap, NifResult, ResourceArc};
use std::collections::HashSet;
use std::sync::{MutexGuard, OnceLock};
use valimc_core::column::ColumnStore;
use valimc_core::physics::Aabb;
use valimc_core::spawning::block_spawner;
use valimc_core::spawning::facts::Facts;
use valimc_core::spawning::level::{Level, Live};
use valimc_core::spawning::rules::{Player, World};
use valimc_core::spawning::spawner::{self, Counted, Despawn, Drawn, SpawnState, Spawned, Tick};
use valimc_core::spawning::structures::{Area, Areas};
use valimc_core::worldgen::random::Random;

pub(crate) static SPAWN: OnceLock<Facts> = OnceLock::new();

/// Install the spawn facts (`Valimc.Data.SpawnFacts.install!`); a second
/// install keeps the first.
#[rustler::nif(schedule = "DirtyCpu")]
fn spawn_facts_install(facts: rustler::Term) -> NifResult<(rustler::Atom, bool)> {
    crate::reply((|| {
        if SPAWN.get().is_some() {
            return Ok(false);
        }
        let json = crate::worldgen::json_of(facts)?;
        Ok(SPAWN.set(Facts::parse(&json)?).is_ok())
    })())
}

/// A mob of the group: `{id, type, {x, y, z}, flags, idle, lived}`.
type Mob = (u32, u16, (f64, f64, f64), u8, i32, i32);

/// A chunk's generated creatures.
type Generated = Vec<((i32, i32), Vec<Out>)>;

/// The tick's environment as the group sends it.
#[derive(NifMap)]
pub(crate) struct Environment {
    dimension: String,
    zoom_seed: i64,
    seed: i64,
    sea_level: i32,
    max_y: i32,
    darken: i32,
    thundering: bool,
    difficulty: i32,
    slime_chance: f64,
    border: (f64, f64, f64, f64),
}

/// One tick's spawning and despawning: the group's players `{x, y, z,
/// spectator, creative}`, its living entities' boxes, its mobs `{id, type,
/// {x, y, z}, flags, idle, lived}` (flags: 1 persistent, 2 in a simulated
/// chunk, so its despawn is checked), its simulated chunks, the world spawn
/// here, whether monsters and persistent categories spawn, and the level
/// random's and the mobs' random's states.
#[derive(NifMap)]
pub(crate) struct Request {
    environment: Environment,
    players: Vec<(f64, f64, f64, bool, bool)>,
    bodies: Vec<(f64, f64, f64, f64, f64, f64)>,
    mobs: Vec<Mob>,
    chunks: Vec<(i32, i32)>,
    respawn: Option<(i32, i32, i32)>,
    enemies: bool,
    persistent: bool,
    random: u64,
    finalize: u64,
    /// The spawner blocks near the group's players, when spawner blocks
    /// work (VMC-042b).
    spawners: Vec<SpawnerBlock>,
    /// The simulated chunks' kept starts of structures that override spawns
    /// (VMC-042b): per chunk `{structure, box, pieces}`, boxes as six ints.
    structures: Vec<((i32, i32), Vec<Kept>)>,
}

/// A kept start: its structure, box and pieces in the chunk.
pub(crate) type Kept = (String, Vec<i32>, Vec<Vec<i32>>);

/// The kept starts as the kernel reads them; structures without overrides
/// in the facts are left out.
fn areas(facts: &Facts, chunks: &[((i32, i32), Vec<Kept>)]) -> Result<Areas, String> {
    let corners = |v: &[i32]| -> Result<[i32; 6], String> {
        v.try_into().map_err(|_| "a box of six ints".to_string())
    };
    let mut out = Areas::new();
    for (chunk, kept) in chunks {
        let mut list = Vec::new();
        for (name, bbox, pieces) in kept {
            let Some(&structure) = facts.structure_names.get(name) else {
                continue;
            };
            list.push(Area {
                structure,
                bbox: corners(bbox)?,
                pieces: pieces
                    .iter()
                    .map(|p| corners(p))
                    .collect::<Result<_, _>>()?,
            });
        }
        if !list.is_empty() {
            out.entry(*chunk).or_default().extend(list);
        }
    }
    Ok(out)
}

/// A spawner block (`BaseSpawner`): its position and countdown, the type
/// it spawns (nil when empty) and its saved configuration.
#[derive(NifMap)]
pub(crate) struct SpawnerBlock {
    position: (i32, i32, i32),
    delay: i32,
    kind: Option<u16>,
    min_delay: i32,
    max_delay: i32,
    count: i32,
    max_nearby: i32,
    player_range: i32,
    spawn_range: i32,
}

impl SpawnerBlock {
    fn spawner(&self) -> block_spawner::Spawner {
        let (x, y, z) = self.position;
        block_spawner::Spawner {
            pos: [x, y, z],
            delay: self.delay,
            config: block_spawner::Config {
                kind: self.kind,
                min_delay: self.min_delay,
                max_delay: self.max_delay,
                count: self.count,
                max_nearby: self.max_nearby,
                player_range: self.player_range,
                spawn_range: self.spawn_range,
            },
        }
    }
}

/// A spawner's tick: its position, its countdown after it and its spawns.
type SpawnerOut = ((i32, i32, i32), i32, Vec<Out>);

type Out = (u16, f64, f64, f64, f32, bool, Option<usize>);

fn out(s: &Spawned) -> Out {
    (
        s.kind, s.pos[0], s.pos[1], s.pos[2], s.yaw, s.school, s.pack,
    )
}

fn world<'a>(
    level: &'a dyn Level,
    env: &Environment,
    players: Vec<Player>,
    bodies: Vec<Aabb>,
) -> Result<World<'a>, String> {
    let facts = SPAWN.get().ok_or("spawn facts not installed")?;
    let states = crate::facts::STATES
        .get()
        .ok_or("block facts not installed")?;
    let physics = crate::facts::PHYSICS
        .get()
        .ok_or("physics facts not installed")?;
    let dimension = *facts
        .dimensions
        .get(&env.dimension)
        .ok_or_else(|| format!("no spawn facts for {}", env.dimension))?;
    Ok(World {
        level,
        facts,
        states,
        table: &physics.shapes,
        dimension,
        sea_level: env.sea_level,
        max_y: env.max_y,
        darken: env.darken,
        thundering: env.thundering,
        difficulty: env.difficulty,
        seed: env.seed,
        slime_chance: env.slime_chance as f32,
        border: [env.border.0, env.border.1, env.border.2, env.border.3],
        players,
        bodies: std::cell::RefCell::new(bodies),
    })
}

fn lock<'r>(
    region: &'r Region,
    siblings: &'r [ResourceArc<Region>],
) -> Result<Vec<MutexGuard<'r, ColumnStore>>, String> {
    let mut regions: Vec<&Region> = vec![region];
    for sibling in siblings {
        if !regions.iter().any(|r| std::ptr::eq(*r, &**sibling)) {
            regions.push(sibling);
        }
    }
    regions
        .iter()
        .map(|r| r.store.lock().map_err(|_| "poisoned region".to_string()))
        .collect()
}

/// The tick's spawns, the mobs it discards and those whose idle time
/// restarts, the two randoms' states after it and its spawners' ticks.
type Natural = (Vec<Out>, Vec<u32>, Vec<u32>, u64, u64, Vec<SpawnerOut>);

fn natural(
    region: &Region,
    siblings: &[ResourceArc<Region>],
    absent: Vec<(i32, i32)>,
    request: Request,
) -> Result<Natural, String> {
    let guards = lock(region, siblings)?;
    let stores: Vec<&ColumnStore> = guards.iter().map(|g| &**g).collect();
    let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
    let flags = crate::facts::FLAGS
        .get()
        .ok_or("block facts not installed")?;
    let facts = SPAWN.get().ok_or("spawn facts not installed")?;
    let live = Live::new(
        &stores,
        &absent,
        flags,
        request.environment.zoom_seed,
        facts.plains,
    );
    let players = request
        .players
        .iter()
        .map(|&(x, y, z, spectator, creative)| Player {
            pos: [x, y, z],
            spectator,
            creative,
        })
        .collect();
    let bodies = request
        .bodies
        .iter()
        .map(|&(a, b, c, d, e, f)| Aabb::from_array([a, b, c, d, e, f]))
        .collect();
    let world = world(&live, &request.environment, players, bodies)?;
    let block = |p: (f64, f64, f64)| [p.0.floor() as i32, p.1.floor() as i32, p.2.floor() as i32];
    let mobs: Vec<Counted> = request
        .mobs
        .iter()
        .filter(|m| m.3 & 1 == 0)
        .map(|m| Counted {
            kind: m.1,
            block: block(m.2),
        })
        .filter(|m| live.holds((m.block[0] >> 4, m.block[2] >> 4)))
        .collect();
    let simulated: HashSet<(i32, i32)> = request
        .chunks
        .iter()
        .copied()
        .filter(|&c| live.holds(c))
        .collect();
    let ticking = |c: (i32, i32)| {
        simulated.contains(&c)
            && world.within_border((c.0 * 16) as f64, (c.1 * 16) as f64)
            && world.within_border((c.0 * 16 + 15) as f64, (c.1 * 16 + 15) as f64)
    };
    let state = SpawnState::new(&world, spawner::spawnable_chunks(&world), &mobs);
    let categories = spawner::categories(&world, &state, request.enemies, request.persistent);
    let structures = areas(facts, &request.structures)?;
    let mut tick = Tick {
        world: &world,
        state,
        random: Random::legacy_at(request.random),
        spawned: Vec::new(),
        ticking: &ticking,
        respawn: request.respawn.map(|(x, y, z)| [x, y, z]),
        caps: true,
        structures: &structures,
    };
    // `collectSpawningChunks` then `Util.shuffle` with the level random.
    let mut chunks: Vec<(i32, i32)> = request
        .chunks
        .iter()
        .copied()
        .filter(|&c| simulated.contains(&c) && !spawner::players_near(&world, c).is_empty())
        .collect();
    chunks.sort();
    spawner::shuffle(&mut chunks, &mut tick.random);
    let mut finalize = Random::legacy_at(request.finalize);
    if !categories.is_empty() {
        for chunk in chunks {
            if ticking(chunk) {
                tick.chunk(chunk, &categories, &mut Drawn(&mut finalize));
            }
        }
    }
    // `checkDespawn`, after the spawning as vanilla's entity tick.
    let (mut discarded, mut reset) = (Vec::new(), Vec::new());
    for &(id, kind, (x, y, z), flags, idle, lived) in &request.mobs {
        let Some(kind) = facts.kind(kind) else {
            continue;
        };
        if flags & 2 == 0 {
            continue;
        }
        match spawner::despawn(
            &world,
            kind,
            [x, y, z],
            flags & 1 != 0,
            idle,
            lived,
            &mut finalize,
        ) {
            Despawn::Discard => discarded.push(id),
            Despawn::Reset if idle > 0 => reset.push(id),
            _ => {}
        }
    }
    // Spawner blocks tick after the entities (`tickBlockEntities`): they
    // count the mobs left and the tick's natural spawns.
    let mut random = tick.random;
    let spawned: Vec<Out> = tick.spawned.iter().map(out).collect();
    let mut mobs: block_spawner::Mobs = request
        .mobs
        .iter()
        .filter(|m| !discarded.contains(&m.0))
        .map(|m| (m.1, m.2))
        .chain(
            tick.spawned
                .iter()
                .map(|s| (s.kind, (s.pos[0], s.pos[1], s.pos[2]))),
        )
        .filter_map(|(kind, (x, y, z))| Some((kind, World::body(facts.kind(kind)?, x, y, z))))
        .collect();
    let spawners = request
        .spawners
        .iter()
        .map(|block| {
            let mut spawner = block.spawner();
            let ticked =
                block_spawner::tick(&world, &mut spawner, &mut mobs, &mut random, &mut |_, _| {});
            (
                block.position,
                spawner.delay,
                ticked.spawned.iter().map(out).collect(),
            )
        })
        .collect();
    Ok((
        spawned,
        discarded,
        reset,
        random.legacy_state().unwrap_or(0),
        finalize.legacy_state().unwrap_or(0),
        spawners,
    ))
}

#[rustler::nif]
fn natural_spawn(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    absent: Vec<(i32, i32)>,
    request: Request,
) -> NifResult<(rustler::Atom, Natural)> {
    crate::reply(natural(&region, &siblings, absent, request))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn natural_spawn_dirty(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    absent: Vec<(i32, i32)>,
    request: Request,
) -> NifResult<(rustler::Atom, Natural)> {
    crate::reply(natural(&region, &siblings, absent, request))
}

/// A custom spawner's checks (VMC-044a3: a village's cat; VMC-044a4: a
/// wandering trader): whether every chunk within `reach` blocks of `pos` is
/// loaded (`hasChunksAt`) and `SpawnPlacements.isSpawnPositionOk` of a mob
/// of type `kind` there, with the height it checked: `pos`'s, or the top of
/// the type's spawn heightmap where its y is nil (`getHeight`).
#[rustler::nif]
fn spawn_position_ok(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    absent: Vec<(i32, i32)>,
    environment: Environment,
    kind: u16,
    pos: (i32, Option<i32>, i32),
    reach: i32,
) -> NifResult<(rustler::Atom, (bool, bool, i32))> {
    crate::reply((|| {
        let guards = lock(&region, &siblings)?;
        let stores: Vec<&ColumnStore> = guards.iter().map(|g| &**g).collect();
        let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
        let flags = crate::facts::FLAGS
            .get()
            .ok_or("block facts not installed")?;
        let facts = SPAWN.get().ok_or("spawn facts not installed")?;
        let live = Live::new(&stores, &absent, flags, environment.zoom_seed, facts.plains);
        let (x, y, z) = pos;
        let loaded = ((x - reach) >> 4..=(x + reach) >> 4)
            .all(|cx| ((z - reach) >> 4..=(z + reach) >> 4).all(|cz| live.holds((cx, cz))));
        if !loaded {
            return Ok((false, false, y.unwrap_or(0)));
        }
        let world = world(&live, &environment, Vec::new(), Vec::new())?;
        let kind = facts.kind(kind).ok_or("no spawn facts for the type")?;
        let y = y.unwrap_or_else(|| world.level.height(kind.heightmap, x, z));
        Ok((true, world.position_ok(kind, [x, y, z]), y))
    })())
}

/// The creatures generated chunks get (`spawnMobsForChunkGeneration`, each
/// chunk's random decoration-seeded from the world seed): per chunk its
/// spawns. Chunk generation reads a level with no entities and no sky
/// darkening.
#[rustler::nif(schedule = "DirtyCpu")]
fn spawn_generated(
    region: ResourceArc<Region>,
    siblings: Vec<ResourceArc<Region>>,
    absent: Vec<(i32, i32)>,
    environment: Environment,
    chunks: Vec<(i32, i32)>,
) -> NifResult<(rustler::Atom, Generated)> {
    crate::reply((|| {
        let guards = lock(&region, &siblings)?;
        let stores: Vec<&ColumnStore> = guards.iter().map(|g| &**g).collect();
        let absent: HashSet<(i32, i32)> = absent.into_iter().collect();
        let flags = crate::facts::FLAGS
            .get()
            .ok_or("block facts not installed")?;
        let facts = SPAWN.get().ok_or("spawn facts not installed")?;
        let live = Live::new(&stores, &absent, flags, environment.zoom_seed, facts.plains);
        let mut env = environment;
        env.darken = 0;
        let world = world(&live, &env, Vec::new(), Vec::new())?;
        let mut rules = Random::legacy(0);
        Ok(chunks
            .into_iter()
            .filter(|&c| live.holds(c))
            .map(|c| {
                let mut random = Random::legacy(0);
                random.set_decoration_seed(world.seed, c.0 * 16, c.1 * 16);
                (
                    c,
                    spawner::generate(&world, c, &mut random, &mut rules)
                        .iter()
                        .map(out)
                        .collect(),
                )
            })
            .collect())
    })())
}

#[cfg(feature = "parity")]
pub(crate) mod parity {
    use super::*;

    /// `checkDespawn` of a fresh mob of type `kind` at `distance` east of a
    /// player at the origin (idle 100 ticks): `{discarded, idle after}`.
    #[rustler::nif]
    fn spawn_despawn(
        kind: u16,
        difficulty: i32,
        distance: f64,
        persistent: bool,
    ) -> NifResult<(rustler::Atom, (bool, i32))> {
        crate::reply((|| {
            let flags = crate::facts::FLAGS
                .get()
                .ok_or("block facts not installed")?;
            let facts = SPAWN.get().ok_or("spawn facts not installed")?;
            let scene = Scene::new(Vec::new(), Vec::new(), 15, facts.plains, flags);
            let env = Environment {
                dimension: "minecraft:overworld".into(),
                zoom_seed: 0,
                seed: 0,
                sea_level: 63,
                max_y: 319,
                darken: 0,
                thundering: false,
                difficulty,
                slime_chance: 0.0,
                border: (-3e7, -3e7, 3e7, 3e7),
            };
            let player = Player {
                pos: [0.5, 64.0, 0.5],
                spectator: false,
                creative: false,
            };
            let world = world(&scene, &env, vec![player], Vec::new())?;
            let kind = facts.kind(kind).ok_or("unknown type")?;
            let mut random = Random::legacy(0);
            Ok(
                match spawner::despawn(
                    &world,
                    kind,
                    [0.5 + distance, 64.0, 0.5],
                    persistent,
                    100,
                    0,
                    &mut random,
                ) {
                    Despawn::Discard => (true, 100),
                    Despawn::Reset => (false, 0),
                    Despawn::Keep => (false, 100),
                },
            )
        })())
    }
    use valimc_core::spawning::facts::Category;
    use valimc_core::spawning::level::Scene;
    use valimc_core::spawning::spawner::Recorded;
    use valimc_core::worldgen::json::Json;

    /// Per run its spawns and the level random's state after them.
    type Runs = Vec<(Vec<Out>, u64)>;

    fn ints(j: &Json) -> Result<Vec<i32>, String> {
        j.as_array()?.iter().map(Json::as_i32).collect()
    }

    fn f64s(j: &Json) -> Result<Vec<f64>, String> {
        j.as_array()?.iter().map(Json::as_f64).collect()
    }

    /// Per run, per tick a spawner's delay after it and its spawns, and the
    /// level random's state after the run.
    type SpawnerRuns = Vec<(Vec<(i32, Vec<Out>)>, u64)>;

    /// Replay one `NaturalSpawnOracle` spawner case (VMC-042b): the spawner
    /// block's ticks from its generated state over the scene, each spawn's
    /// `finalizeSpawn` leaving the random where vanilla's recorded it.
    #[rustler::nif(schedule = "DirtyCpu")]
    fn spawn_spawner_scene(
        case: rustler::Term,
        biome: u16,
        kind: u16,
    ) -> NifResult<(rustler::Atom, SpawnerRuns)> {
        crate::reply((|| {
            let case = crate::worldgen::json_of(case)?;
            let flags = crate::facts::FLAGS
                .get()
                .ok_or("block facts not installed")?;
            let (scene, players, env) = scene_of(&case, biome, flags)?;
            let at = ints(case.field("spawner")?)?;
            let mut runs = Vec::new();
            for run in case.field("runs")?.as_array()? {
                let run = run.as_array()?;
                let mut random = Random::legacy_at(run[0].as_f64()? as u64);
                let world = world(&scene, &env, players.clone(), player_boxes(&players))?;
                let mut spawner = block_spawner::Spawner {
                    pos: [at[0], at[1], at[2]],
                    delay: 20,
                    config: block_spawner::Config {
                        kind: Some(kind),
                        min_delay: 200,
                        max_delay: 800,
                        count: 4,
                        max_nearby: 6,
                        player_range: 16,
                        spawn_range: 4,
                    },
                };
                let clear = case.field("clear")?.as_i32()? as usize;
                let mut mobs = Vec::new();
                let mut ticks = Vec::new();
                for (t, tick) in run[2].as_array()?.iter().enumerate() {
                    let states: Vec<u64> = tick.as_array()?[1]
                        .as_array()?
                        .iter()
                        .map(|s| Ok(s.as_array()?[6].as_f64()? as u64))
                        .collect::<Result<_, String>>()?;
                    let ticked = block_spawner::tick(
                        &world,
                        &mut spawner,
                        &mut mobs,
                        &mut random,
                        &mut |r, i| {
                            if let Some(&state) = states.get(i) {
                                *r = Random::legacy_at(state);
                            }
                        },
                    );
                    ticks.push((spawner.delay, ticked.spawned.iter().map(out).collect()));
                    // The scene's mobs leave (killed) every `clear` ticks.
                    if (t + 1) % clear == 0 {
                        mobs.clear();
                        *world.bodies.borrow_mut() = player_boxes(&players);
                    }
                }
                runs.push((ticks, random.legacy_state().unwrap_or(0)));
            }
            Ok(runs)
        })())
    }

    /// A scene's structure starts (VMC-042b), each referenced by every chunk
    /// its box reaches: `{id, box, pieces}`.
    fn scene_structures(case: &Json, facts: &Facts) -> Result<Areas, String> {
        let mut by_chunk: Vec<((i32, i32), Vec<Kept>)> = Vec::new();
        let Some(list) = case.get("structures") else {
            return Ok(Areas::new());
        };
        for start in list.as_array()? {
            let id = start.field("id")?.as_str()?.to_string();
            let bbox = ints(start.field("box")?)?;
            let pieces = start
                .field("pieces")?
                .as_array()?
                .iter()
                .map(ints)
                .collect::<Result<Vec<_>, _>>()?;
            for cx in bbox[0] >> 4..=bbox[3] >> 4 {
                for cz in bbox[2] >> 4..=bbox[5] >> 4 {
                    by_chunk.push(((cx, cz), vec![(id.clone(), bbox.clone(), pieces.clone())]));
                }
            }
        }
        areas(facts, &by_chunk)
    }

    fn player_boxes(players: &[Player]) -> Vec<Aabb> {
        players
            .iter()
            .map(|p| {
                Aabb::new(
                    [p.pos[0] - 0.3, p.pos[1], p.pos[2] - 0.3],
                    [p.pos[0] + 0.3, p.pos[1] + 1.8, p.pos[2] + 0.3],
                )
            })
            .collect()
    }

    /// A case's scene, players and environment.
    fn scene_of(
        case: &Json,
        biome: u16,
        flags: &'static valimc_core::flags::BlockFlags,
    ) -> Result<(Scene<'static>, Vec<Player>, Environment), String> {
        let mut fills = Vec::new();
        for f in case.field("fills")?.as_array()? {
            let f = ints(f)?;
            fills.push(([f[0], f[1], f[2]], [f[3], f[4], f[5]], f[6] as u16));
        }
        let mut lights = Vec::new();
        for l in case.field("lights")?.as_array()? {
            let l = ints(l)?;
            lights.push(([l[0], l[1], l[2]], l[3]));
        }
        let sky = case.field("sky")?.as_i32()? as u8;
        let scene = Scene::new(fills, lights, sky, biome, flags);
        let players: Vec<Player> = case
            .field("players")?
            .as_array()?
            .iter()
            .map(|p| {
                let p = f64s(p)?;
                Ok(Player {
                    pos: [p[0], p[1], p[2]],
                    spectator: p[3] != 0.0,
                    creative: false,
                })
            })
            .collect::<Result<_, String>>()?;
        let env = Environment {
            dimension: case.field("dimension")?.as_str()?.to_string(),
            zoom_seed: 0,
            seed: case.field("seed")?.as_f64()? as i64,
            sea_level: case.field("sea_level")?.as_i32()?,
            max_y: 319,
            darken: case.field("darken")?.as_i32()?,
            thundering: case.field("thundering")?.as_bool()?,
            difficulty: case.field("difficulty")?.as_i32()?,
            slime_chance: case.field("slime_chance")?.as_f64()?,
            border: (-29_999_984.0, -29_999_984.0, 29_999_984.0, 29_999_984.0),
        };
        Ok((scene, players, env))
    }

    /// Replay one `NaturalSpawnOracle` case (tick or generation), given the
    /// biome's registry id and each entity's type id (`types`, the scene's
    /// entities in order): per run `{spawns, random after}`.
    #[rustler::nif(schedule = "DirtyCpu")]
    fn spawn_scene(
        case: rustler::Term,
        biome: u16,
        types: Vec<u16>,
    ) -> NifResult<(rustler::Atom, Runs)> {
        crate::reply((|| {
            let case = crate::worldgen::json_of(case)?;
            let flags = crate::facts::FLAGS
                .get()
                .ok_or("block facts not installed")?;
            let (scene, players, env) = scene_of(&case, biome, flags)?;
            let facts = SPAWN.get().ok_or("spawn facts not installed")?;
            let mut mobs = Vec::new();
            let mut bodies = Vec::new();
            for (e, &kind) in case.field("entities")?.as_array()?.iter().zip(&types) {
                let e = e.as_array()?;
                let (x, y, z) = (e[1].as_f64()?, e[2].as_f64()?, e[3].as_f64()?);
                mobs.push(Counted {
                    kind,
                    block: [x.floor() as i32, y.floor() as i32, z.floor() as i32],
                });
                let t = facts.kind(kind).ok_or("unknown entity type")?;
                bodies.push(World::body(t, x, y, z));
            }
            bodies.extend(player_boxes(&players));
            let spawn = ints(case.field("spawn")?)?;
            let structures = scene_structures(&case, facts)?;
            let overworld = env.dimension == "minecraft:overworld";
            let chunk = (
                case.field("chunk_x")?.as_i32()?,
                case.field("chunk_z")?.as_i32()?,
            );
            match case.field("kind")?.as_str()? {
                "generation" => {
                    let mut env = env;
                    env.darken = 0;
                    let world = world(&scene, &env, Vec::new(), Vec::new())?;
                    let mut random = Random::legacy(0);
                    random.set_decoration_seed(world.seed, chunk.0 * 16, chunk.1 * 16);
                    let mut rules = Random::legacy(0);
                    let spawned = spawner::generate(&world, chunk, &mut random, &mut rules);
                    Ok(vec![(spawned.iter().map(out).collect(), 0)])
                }
                _ => {
                    let categories: Vec<Category> = case
                        .field("categories")?
                        .as_array()?
                        .iter()
                        .map(|c| Category::of(c.as_str()?))
                        .collect::<Result<_, String>>()?;
                    let mut runs = Vec::new();
                    for run in case.field("runs")?.as_array()? {
                        let run = run.as_array()?;
                        let start = run[0].as_f64()? as u64;
                        let schools: Vec<bool> = run[2]
                            .as_array()?
                            .iter()
                            .map(|s| s.as_array().and_then(|s| s[5].as_bool()))
                            .collect::<Result<_, String>>()?;
                        let world = world(&scene, &env, players.clone(), bodies.clone())?;
                        let state = SpawnState::new(&world, 289, &mobs);
                        let filtered = spawner::categories(
                            &world,
                            &state,
                            env.difficulty != 0,
                            case.field("persistent")?.as_bool()?,
                        );
                        if filtered != categories {
                            return Err(format!("categories {filtered:?}, vanilla {categories:?}"));
                        }
                        let ticking = |_c: (i32, i32)| true;
                        let mut tick = Tick {
                            world: &world,
                            state,
                            random: Random::legacy_at(start),
                            spawned: Vec::new(),
                            ticking: &ticking,
                            respawn: overworld.then_some([spawn[0], spawn[1], spawn[2]]),
                            caps: false,
                            structures: &structures,
                        };
                        tick.chunk(chunk, &categories, &mut Recorded(schools));
                        runs.push((
                            tick.spawned.iter().map(out).collect(),
                            tick.random.legacy_state().unwrap_or(0),
                        ));
                    }
                    Ok(runs)
                }
            }
        })())
    }
}
