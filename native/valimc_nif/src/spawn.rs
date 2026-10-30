//! Natural spawning (VMC-042a) over the Region resource: `spawn_facts_install`
//! parses the spawn facts once; `spawn_generated` gives the creatures new
//! chunks get, reading the section's store and its group's others without
//! changing them. A group's tick of natural spawning runs over its resident
//! inputs (`spawn_world`, VMC-081g2). `spawn_scene` (parity builds) replays an
//! oracle scene.

use crate::region::Region;
use rustler::{NifMap, NifResult, ResourceArc};
use std::collections::HashSet;
use std::sync::{MutexGuard, OnceLock};
use valimc_core::column::ColumnStore;
use valimc_core::physics::Aabb;
use valimc_core::spawning::facts::Facts;
use valimc_core::spawning::level::{Level, Live};
use valimc_core::spawning::rules::{Player, World};
use valimc_core::spawning::spawner::{self, Spawned};
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

/// A chunk's generated creatures.
type Generated = Vec<((i32, i32), Vec<Out>)>;

/// The tick's environment as the group sends it.
#[derive(NifMap)]
pub(crate) struct Environment {
    pub(crate) dimension: String,
    pub(crate) zoom_seed: i64,
    pub(crate) seed: i64,
    pub(crate) sea_level: i32,
    pub(crate) max_y: i32,
    pub(crate) darken: i32,
    pub(crate) thundering: bool,
    pub(crate) difficulty: i32,
    pub(crate) slime_chance: f64,
    pub(crate) border: (f64, f64, f64, f64),
}

/// A kept start: its structure, box and pieces in the chunk.
pub(crate) type Kept = (String, Vec<i32>, Vec<Vec<i32>>);

/// The kept starts as the kernel reads them; structures without overrides
/// in the facts are left out.
pub(crate) fn areas(facts: &Facts, chunks: &[((i32, i32), Vec<Kept>)]) -> Result<Areas, String> {
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

/// A spawn: its type, position, yaw, school and pack.
pub(crate) type Out = (u16, f64, f64, f64, f32, bool, Option<usize>);

pub(crate) fn out(s: &Spawned) -> Out {
    (
        s.kind, s.pos[0], s.pos[1], s.pos[2], s.yaw, s.school, s.pack,
    )
}

pub(crate) fn world<'a>(
    level: &'a dyn Level,
    env: &Environment,
    players: Vec<Player>,
    bodies: Vec<Aabb>,
    resident: Option<&'a dyn Fn(&Aabb) -> bool>,
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
        resident,
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
        let world = world(&live, &environment, Vec::new(), Vec::new(), None)?;
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
        let world = world(&live, &env, Vec::new(), Vec::new(), None)?;
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
    use valimc_core::spawning::block_spawner;
    use valimc_core::spawning::spawner::{Counted, Despawn, SpawnState, Tick};

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
            let world = world(&scene, &env, vec![player], Vec::new(), None)?;
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
                let world = world(&scene, &env, players.clone(), player_boxes(&players), None)?;
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
                    let world = world(&scene, &env, Vec::new(), Vec::new(), None)?;
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
                        let world = world(&scene, &env, players.clone(), bodies.clone(), None)?;
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
