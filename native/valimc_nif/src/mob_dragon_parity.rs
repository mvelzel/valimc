//! The native dragon (VMC-081d, `mobs::boss::dragon`) against
//! `Valimc.AI.Dragon.Actor` and `Valimc.Entity.Dragon`, built only with the
//! `parity` feature.
//!
//! `mob_parity_dragon` runs one dragon (a store record) tick by tick over a
//! region's store as `test/native_mob_dragon_test.exs` runs the Elixir: the
//! tick's outside actions (a crystal destroyed, a hit on a part, its phase
//! or health set, its AI turned off), its living timers, then its actor's
//! tick over the arena the scene gives (players moving, the mobs it may
//! touch, crystals standing, the fight's crystal count). Each tick answers
//! its record, its position, its events, its effects and the actions'
//! events.

use crate::mob_ai_parity::{mode, over_region};
use crate::mob_term;
use crate::mobs::MobRecordFacts;
use crate::region::Region;
use rustler::{Atom, Binary, Encoder, Env, NifMap, NifResult, ResourceArc, Term};
use valimc_core::mobs::boss::dragon::{
    self,
    actor::{self, CrystalHit, Striker},
    Arena, Crystal, MobTarget, Player,
};
use valimc_core::mobs::combat::{self, Attacker, Hit, Rules};
use valimc_core::mobs::record;
use valimc_core::mobs::sensing::{GameMode, SensedPlayer};
use valimc_core::mobs::term::Value;

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

type V3 = (f64, f64, f64);

fn uuid(b: &[u8]) -> NifResult<[u8; 16]> {
    b.try_into().map_err(|_| bad())
}

fn v3(v: V3) -> [f64; 3] {
    [v.0, v.1, v.2]
}

#[derive(NifMap)]
struct PlayerT<'a> {
    uuid: Binary<'a>,
    id: i32,
    position: V3,
    mode: Atom,
    alive: bool,
    invulnerable: bool,
}

#[derive(NifMap)]
struct MobT<'a> {
    uuid: Binary<'a>,
    position: V3,
    width: f64,
    height: f64,
    recent: bool,
}

#[derive(NifMap)]
struct CrystalT<'a> {
    uuid: Binary<'a>,
    entity_id: i32,
    position: V3,
    bbox: (f64, f64, f64, f64, f64, f64),
}

#[derive(NifMap)]
struct SceneT<'a> {
    dragon: Term<'a>,
    ticks: i32,
    time: i64,
    players: Vec<PlayerT<'a>>,
    /// Each tick's player positions (none: they stand).
    moves: Vec<Vec<V3>>,
    mobs: Vec<MobT<'a>>,
    crystals: Vec<CrystalT<'a>>,
    /// The fight's alive crystals, and changes `{tick, count}`.
    alive: Option<i64>,
    counts: Vec<(i32, Option<i64>)>,
    /// `{x, z, height}` of the arena's columns.
    heights: Vec<(i64, i64, i64)>,
    podium: (i64, i64, i64),
    previous_kill: bool,
    mob_griefing: bool,
    mob_drops: bool,
    max_y: i32,
    /// `{tick, action}`.
    acts: Vec<(i32, Term<'a>)>,
}

fn sensed(p: &PlayerT) -> NifResult<SensedPlayer> {
    let m = mode(p.mode)?;
    Ok(SensedPlayer {
        uuid: uuid(p.uuid.as_slice())?,
        id: p.id,
        position: v3(p.position),
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.62f32 as f64,
        width: 0.6f32 as f64,
        height: 1.8f32 as f64,
        mode: m,
        invulnerable: p.invulnerable,
        alive: p.alive,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        equipment: [None; 6],
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    })
}

fn attacker_of(p: &SensedPlayer) -> Attacker {
    Attacker {
        uuid: p.uuid,
        entity_id: p.id,
        player: true,
        entity_type: "minecraft:player".to_owned(),
        mainhand: None,
    }
}

fn rules() -> NifResult<Rules<'static>> {
    Ok(Rules {
        facts: crate::mob_facts::facts()?,
        living: crate::mob_living::facts()?,
        families: crate::mob_facts::kinds()?,
        mind: &combat::AiMind,
    })
}

fn player_index(v: &Value, players: &[SensedPlayer]) -> NifResult<Option<SensedPlayer>> {
    match v.as_int() {
        Some(i) => players.get(i as usize).cloned().map(Some).ok_or_else(bad),
        None => Ok(None),
    }
}

/// `{ticks: [{record, position, events, effects, act events}]}` of `scene`.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_parity_dragon<'a>(
    env: Env<'a>,
    region: ResourceArc<Region>,
    zoom_seed: i64,
    record_facts: ResourceArc<MobRecordFacts>,
    scene: SceneT<'a>,
) -> NifResult<Vec<Term<'a>>> {
    let rules = rules()?;
    let facts = rules.facts;
    let dragon_facts = facts.dragon.as_ref().ok_or(bad())?;
    let value = mob_term::decode(scene.dragon)?;
    let mut mob = record::restore(&value, &record_facts.0).map_err(|_| bad())?;
    let mut players = scene
        .players
        .iter()
        .map(sensed)
        .collect::<NifResult<Vec<_>>>()?;
    let mobs: Vec<MobTarget> = scene
        .mobs
        .iter()
        .map(|m| {
            Ok(MobTarget {
                uuid: uuid(m.uuid.as_slice())?,
                position: v3(m.position),
                width: m.width,
                height: m.height,
                bbox: None,
                recent: m.recent,
            })
        })
        .collect::<NifResult<_>>()?;
    let mut crystals: Vec<(i32, Crystal)> = scene
        .crystals
        .iter()
        .map(|c| {
            let b = c.bbox;
            Ok((
                c.entity_id,
                Crystal {
                    uuid: uuid(c.uuid.as_slice())?,
                    position: v3(c.position),
                    bbox: [b.0, b.1, b.2, b.3, b.4, b.5],
                },
            ))
        })
        .collect::<NifResult<_>>()?;
    let heights = scene.heights.clone();
    let height = move |x: i64, z: i64| {
        heights
            .iter()
            .find(|&&(hx, hz, _)| hx == x && hz == z)
            .map_or(0, |&(_, _, h)| h)
    };
    let acts = scene
        .acts
        .iter()
        .map(|&(t, a)| Ok((t, mob_term::decode(a)?)))
        .collect::<NifResult<Vec<_>>>()?;
    let mut alive = scene.alive;
    let mut out = Vec::new();
    over_region(&region, zoom_seed, |level| {
        level.max_y = scene.max_y;
        level.rules.mob_griefing = scene.mob_griefing;
        level.rules.mob_drops = scene.mob_drops;
        for tick in 0..scene.ticks {
            level.time = scene.time + tick as i64;
            if let Some(moved) = scene.moves.get(tick as usize) {
                for (p, at) in players.iter_mut().zip(moved) {
                    p.position = v3(*at);
                }
            }
            for &(at, count) in &scene.counts {
                if at == tick {
                    alive = count;
                }
            }
            let mut flame = [0u8; 16];
            flame[..8].copy_from_slice(&(9000 + tick as u64).to_be_bytes());
            let mut act_events = Vec::new();
            for (at, act) in &acts {
                if *at != tick {
                    continue;
                }
                let items = act.as_tuple().ok_or(bad())?;
                let tag = items
                    .first()
                    .and_then(Value::as_atom)
                    .ok_or(bad())?
                    .as_str();
                match (tag, &items[1..]) {
                    ("crystal", [id, who]) => {
                        let id = uuid(id.as_binary().ok_or(bad())?)?;
                        let Some(index) = crystals.iter().position(|(_, c)| c.uuid == id) else {
                            return Err(bad());
                        };
                        let (entity_id, crystal) = crystals.remove(index);
                        let striker = player_index(who, &players)?.map(|p| Striker {
                            player: Player {
                                id: p.id as i64,
                                position: p.position,
                                height: p.height,
                            },
                            eligible: p.alive
                                && !matches!(p.mode, GameMode::Creative | GameMode::Spectator)
                                && !p.invulnerable,
                            attacker: attacker_of(&p),
                        });
                        let arena = Arena {
                            height: &height,
                            podium: [scene.podium.0, scene.podium.1, scene.podium.2],
                            crystals: alive,
                            crystal_bodies: crystals.iter().map(|(_, c)| c.clone()).collect(),
                            mobs: mobs.clone(),
                            previous_kill: scene.previous_kill,
                            flame_uuid: flame,
                        };
                        let mut denv =
                            dragon::environment(dragon_facts, facts, level, &mob, &arena, &players);
                        let direct = CrystalHit {
                            uuid: crystal.uuid,
                            entity_id,
                            position: crystal.position,
                        };
                        let events = actor::crystal_destroyed(
                            &rules,
                            &mut mob,
                            &crystal.uuid,
                            &direct,
                            striker.as_ref(),
                            &mut denv,
                        );
                        act_events.extend(events);
                    }
                    ("hit", [part, amount, source, who, direct]) => {
                        let source = std::str::from_utf8(source.as_binary().ok_or(bad())?)
                            .map_err(|_| bad())?;
                        let source = facts
                            .damage_types
                            .id(&format!("minecraft:{source}"))
                            .ok_or(bad())?;
                        let player = player_index(who, &players)?;
                        let attacker = player.as_ref().map(attacker_of);
                        let direct = match direct.as_binary() {
                            Some(t) => Some(Attacker {
                                uuid: [7; 16],
                                entity_id: 5000,
                                player: false,
                                entity_type: String::from_utf8_lossy(t).into_owned(),
                                mainhand: None,
                            }),
                            None => attacker.clone(),
                        };
                        let hit = Hit {
                            attacker,
                            direct,
                            position: Some(player.map_or([0.5, 64.0, 0.5], |p| p.position)),
                            dragon_part: part.as_int().map(|p| p as u8),
                            ..Hit::new(source, amount.as_number().ok_or(bad())?)
                        };
                        act_events.extend(combat::hit_body(&rules, &mut mob, &hit).0);
                    }
                    ("phase", [n]) => {
                        mob.body.data.set("phase", n.clone());
                    }
                    ("health", [v]) => {
                        mob.body.mob.living.health.value = v.as_number().ok_or(bad())?;
                    }
                    ("no_ai", [v]) => {
                        mob.body.mob.no_ai = v.as_bool().ok_or(bad())?;
                    }
                    _ => return Err(bad()),
                }
            }
            dragon::timers(&mut mob.body);
            let arena = Arena {
                height: &height,
                podium: [scene.podium.0, scene.podium.1, scene.podium.2],
                crystals: alive,
                crystal_bodies: crystals.iter().map(|(_, c)| c.clone()).collect(),
                mobs: mobs.clone(),
                previous_kill: scene.previous_kill,
                flame_uuid: flame,
            };
            let mut denv = dragon::environment(dragon_facts, facts, level, &mob, &arena, &players);
            let step = actor::tick(&rules, &mut mob, &mut denv);
            mob.position = step.position;
            let events = Value::List(step.events.iter().map(|e| e.value()).collect());
            let effects = Value::List(step.effects.iter().map(|e| e.value()).collect());
            let act_events = Value::List(
                act_events
                    .iter()
                    .map(|e| crate::mob_living_parity::event(facts, e))
                    .collect(),
            );
            let [x, y, z] = step.position;
            out.push(
                (
                    mob_term::encode(env, &record::record(&mob))?,
                    (x, y, z),
                    mob_term::encode(env, &events)?,
                    mob_term::encode(env, &effects)?,
                    mob_term::encode(env, &act_events)?,
                )
                    .encode(env),
            );
        }
        Ok(())
    })?;
    Ok(out)
}

// ------------------------------------------------- the stages' native modes

/// The dragon stages' native modes (`--native`): their hand-built scenes as
/// the native dragon's inputs. A scene's env (`scene`) is a map of `height`
/// (every column's, or `[{x, z, height}]`), `podium`, `crystals`, `players`
/// (`[%{id, position, height}]`), `sees` (whether it sees them), `blocks`
/// (`[{{x, y, z}, state}]`, with `ground` below `floor` and air above),
/// `collision`, `wall`, `targets` (`[{kind, uuid, position, recent, box}]`),
/// `crystal_bodies` (`[{uuid, position, box}]`), `mob_griefing`,
/// `mob_drops`, `previous_kill` and `time`, each optional.
mod oracle {
    use super::*;
    use std::collections::HashMap;
    use valimc_core::mobs::boss::dragon::{
        codec, flight::Flight, paths, phases::Phases, DragonFacts, Env as DragonEnv, Target,
    };
    use valimc_core::mobs::level::{Level, Unknown};
    use valimc_core::mobs::random::LegacyRandom;
    use valimc_core::mobs::sensing::{Kind as RefKind, Ref};
    use valimc_core::mobs::term::Map;
    use valimc_core::physics::source::BlockSource;

    /// A scene's blocks: those it names, its ground below its floor, air
    /// above.
    struct SceneBlocks {
        cells: HashMap<[i32; 3], u16>,
        floor: i32,
        ground: u16,
    }

    impl BlockSource for SceneBlocks {
        fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
            Some(
                self.cells
                    .get(&[x, y, z])
                    .copied()
                    .unwrap_or(if y < self.floor { self.ground } else { 0 }),
            )
        }
    }

    /// What a scene's env holds beside its level.
    struct Scene {
        heights: Heights,
        podium: [i64; 3],
        crystals: Option<i64>,
        players: Vec<Player>,
        sees: Option<bool>,
        collision: bool,
        wall: bool,
        targets: Vec<Target>,
        crystal_bodies: Vec<Crystal>,
        previous_kill: bool,
    }

    enum Heights {
        All(i64),
        Columns(HashMap<(i64, i64), i64>),
    }

    impl Heights {
        fn at(&self, x: i64, z: i64) -> i64 {
            match self {
                Heights::All(h) => *h,
                Heights::Columns(c) => c.get(&(x, z)).copied().unwrap_or(0),
            }
        }
    }

    fn get<'v>(m: &'v Map, key: &str) -> Option<&'v Value> {
        m.get_atom(key).filter(|v| !v.is_nil())
    }

    fn uuid_of(v: &Value) -> NifResult<[u8; 16]> {
        uuid(v.as_binary().ok_or_else(bad)?)
    }

    fn box_of(v: &Value) -> NifResult<[f64; 6]> {
        let items = v.as_tuple().ok_or_else(bad)?;
        let n: Vec<f64> = items
            .iter()
            .map(Value::as_number)
            .collect::<Option<_>>()
            .ok_or_else(bad)?;
        n.try_into().map_err(|_| bad())
    }

    fn vec_of(v: &Value) -> NifResult<[f64; 3]> {
        let items = v.as_tuple().ok_or_else(bad)?;
        match items {
            [x, y, z] => Ok([
                x.as_number().ok_or_else(bad)?,
                y.as_number().ok_or_else(bad)?,
                z.as_number().ok_or_else(bad)?,
            ]),
            _ => Err(bad()),
        }
    }

    fn player_of(v: &Value) -> NifResult<Player> {
        let m = v.as_map().ok_or_else(bad)?;
        Ok(Player {
            id: get(m, "id").and_then(Value::as_int).ok_or_else(bad)?,
            position: vec_of(get(m, "position").ok_or_else(bad)?)?,
            height: get(m, "height")
                .and_then(Value::as_number)
                .ok_or_else(bad)?,
        })
    }

    fn list<'v>(m: &'v Map, key: &str) -> &'v [Value] {
        get(m, key).and_then(Value::as_list).unwrap_or(&[])
    }

    type Parts = (SceneBlocks, valimc_core::mobs::level::Rules, i64, Scene);

    /// A scene's env map: its level's blocks, rules and time, and the rest.
    fn scene(term: Term) -> NifResult<Parts> {
        let v = mob_term::decode(term)?;
        let m = v.as_map().ok_or_else(bad)?;
        let flag =
            |key: &str, default: bool| get(m, key).and_then(Value::as_bool).unwrap_or(default);
        let heights = match get(m, "height") {
            Some(Value::List(rows)) => Heights::Columns(
                rows.iter()
                    .map(|r| match r.as_tuple().ok_or_else(bad)? {
                        [x, z, h] => Ok((
                            (x.as_int().ok_or_else(bad)?, z.as_int().ok_or_else(bad)?),
                            h.as_int().ok_or_else(bad)?,
                        )),
                        _ => Err(bad()),
                    })
                    .collect::<NifResult<_>>()?,
            ),
            Some(h) => Heights::All(h.as_int().ok_or_else(bad)?),
            None => Heights::All(0),
        };
        let mut cells = HashMap::new();
        for row in list(m, "blocks") {
            let [cell, state] = row.as_tuple_n::<2>().ok_or_else(bad)?;
            let c = cell.as_ivec3().ok_or_else(bad)?;
            cells.insert(
                [c[0] as i32, c[1] as i32, c[2] as i32],
                state.as_int().ok_or_else(bad)? as u16,
            );
        }
        let blocks = SceneBlocks {
            cells,
            floor: get(m, "floor")
                .and_then(Value::as_int)
                .map_or(i32::MIN, |f| f as i32),
            ground: get(m, "ground").and_then(Value::as_int).unwrap_or(0) as u16,
        };
        let rules = valimc_core::mobs::level::Rules {
            mob_griefing: flag("mob_griefing", true),
            mob_drops: flag("mob_drops", true),
            ..Default::default()
        };
        let targets = list(m, "targets")
            .iter()
            .map(|t| {
                let [kind, id, position, recent, b] = t.as_tuple_n::<5>().ok_or_else(bad)?;
                let kind = match kind.as_atom().map(|a| a.as_str()) {
                    Some("player") => RefKind::Player,
                    Some("mob") => RefKind::Mob,
                    _ => return Err(bad()),
                };
                Ok(Target {
                    target: Ref {
                        kind,
                        uuid: uuid_of(id)?,
                    },
                    position: vec_of(position)?,
                    recent: recent.as_bool().ok_or_else(bad)?,
                    bbox: box_of(b)?,
                })
            })
            .collect::<NifResult<_>>()?;
        let crystal_bodies = list(m, "crystal_bodies")
            .iter()
            .map(|c| {
                let [id, position, b] = c.as_tuple_n::<3>().ok_or_else(bad)?;
                Ok(Crystal {
                    uuid: uuid_of(id)?,
                    position: vec_of(position)?,
                    bbox: box_of(b)?,
                })
            })
            .collect::<NifResult<_>>()?;
        let scene = Scene {
            heights,
            podium: get(m, "podium")
                .and_then(Value::as_ivec3)
                .unwrap_or([0, 0, 0]),
            crystals: get(m, "crystals").and_then(Value::as_int),
            players: list(m, "players")
                .iter()
                .map(player_of)
                .collect::<NifResult<_>>()?,
            sees: get(m, "sees").and_then(Value::as_bool),
            collision: flag("collision", false),
            wall: flag("wall", false),
            targets,
            crystal_bodies,
            previous_kill: flag("previous_kill", true),
        };
        let time = get(m, "time").and_then(Value::as_int).unwrap_or(0);
        Ok((blocks, rules, time, scene))
    }

    /// Runs `f` with the scene's dragon env over its level.
    fn with_scene<T>(
        term: Term,
        f: impl FnOnce(&Rules, &DragonFacts, &mut DragonEnv) -> NifResult<T>,
    ) -> NifResult<T> {
        let rules = rules()?;
        let facts = rules.facts;
        let df = facts.dragon.as_ref().ok_or_else(bad)?;
        let physics = crate::facts::PHYSICS.get().ok_or_else(bad)?;
        let states = crate::facts::STATES.get().ok_or_else(bad)?;
        let (blocks, level_rules, time, scene) = scene(term)?;
        let mut level = Level::new(
            &blocks,
            &Unknown,
            facts,
            physics,
            states,
            LegacyRandom { seed: 0 },
        );
        level.rules = level_rules;
        level.time = time;
        let heights = &scene.heights;
        let mut env = DragonEnv {
            facts: df,
            level: &level,
            graph: paths::graph(df, &|x, z| heights.at(x, z)),
            podium: scene.podium,
            crystals: scene.crystals,
            crystal_bodies: &scene.crystal_bodies,
            previous_kill: scene.previous_kill,
            flame_uuid: [0; 16],
            players: scene.players.clone(),
            sight: Vec::new(),
            eye: [0.0; 3],
            targets: scene.targets.clone(),
            wall: scene.wall,
            collision: scene.collision,
            sees: scene.sees,
        };
        f(&rules, df, &mut env)
    }

    fn boxes<'a>(env: Env<'a>, facts: &DragonFacts, flight: &Flight) -> Term<'a> {
        flight
            .boxes(facts)
            .iter()
            .map(|b| (b[0], b[1], b[2], b[3], b[4], b[5]))
            .collect::<Vec<_>>()
            .encode(env)
    }

    /// `Flight.step/5` natively: `{flight, part boxes}`.
    #[rustler::nif]
    fn dragon_oracle_flight<'a>(
        env: Env<'a>,
        flight: Term<'a>,
        target: Option<V3>,
        phase: i64,
        wall: bool,
        no_ai: bool,
    ) -> NifResult<Term<'a>> {
        let facts = crate::mob_facts::facts()?;
        let df = facts.dragon.as_ref().ok_or_else(bad)?;
        let mut f = codec::flight(&mob_term::decode(flight)?).ok_or_else(bad)?;
        f.begin_tick(no_ai);
        if !no_ai {
            f.advance(df, target.map(v3), phase, wall);
        }
        Ok((
            mob_term::encode(env, &codec::flight_value(&f))?,
            boxes(env, df, &f),
        )
            .encode(env))
    }

    /// One `Paths.find/5` query: `{start, end, crystals, last}`.
    type Find = (usize, usize, Option<i64>, Option<(i64, i64, i64)>);

    /// The arena graph over the scene's heights, and `Paths.closest/3` of
    /// each `{position, crystals}` and `Paths.find/5` of each query:
    /// `{closest, paths}`.
    #[rustler::nif]
    fn dragon_oracle_paths<'a>(
        env: Env<'a>,
        scene_term: Term<'a>,
        closest: Vec<(V3, Option<i64>)>,
        finds: Vec<Find>,
    ) -> NifResult<Term<'a>> {
        with_scene(scene_term, |_, _, denv| {
            let near: Vec<usize> = closest
                .iter()
                .map(|(p, crystals)| paths::closest(&denv.graph, v3(*p), *crystals))
                .collect();
            let found: Vec<Option<Vec<(i64, i64, i64)>>> = finds
                .iter()
                .map(|&(start, finish, crystals, last)| {
                    paths::find(
                        &denv.graph,
                        start,
                        finish,
                        crystals,
                        last.map(|(x, y, z)| [x, y, z]),
                    )
                    .map(|p| p.into_iter().map(|[x, y, z]| (x, y, z)).collect())
                })
                .collect();
            Ok((near, found).encode(env))
        })
    }

    /// `Phases.set/2`, `strafe/3` or `tick/3` of `phases` (a `%Phases{}`)
    /// in the scene: `{:set, phase}`, `{:strafe, player}` or `{:tick,
    /// no_ai}`. `{phases, part boxes}` after.
    #[rustler::nif]
    fn dragon_oracle_phases<'a>(
        env: Env<'a>,
        phases: Term<'a>,
        op: Term<'a>,
        scene_term: Term<'a>,
    ) -> NifResult<Term<'a>> {
        let mut p: Phases = codec::phases(&mob_term::decode(phases)?).ok_or_else(bad)?;
        let op = mob_term::decode(op)?;
        let items = op.as_tuple().ok_or_else(bad)?;
        let tag = items.first().and_then(Value::as_atom).ok_or_else(bad)?;
        with_scene(scene_term, |_, df, denv| {
            match (tag.as_str(), &items[1..]) {
                ("set", [n]) => p.set(n.as_int().ok_or_else(bad)?),
                ("strafe", [player]) => {
                    let row = player_of(player)?;
                    p.strafe(&row, player.clone(), denv);
                }
                ("tick", [no_ai]) => p.tick(denv, no_ai.as_bool().ok_or_else(bad)?),
                _ => return Err(bad()),
            }
            Ok((
                mob_term::encode(env, &codec::phases_value(&p))?,
                boxes(env, df, &p.flight),
            )
                .encode(env))
        })
    }

    /// What a stage does to the dragon `id` of the oracle section `res` in
    /// its scene: `:tick` (its timers, then its actor's tick, its position
    /// following: `{position, events, effects}`), `{:timers, n}` (`:ok`),
    /// `{:crystal, uuid, {direct uuid, entity id, position}, striker | nil}`
    /// (`Actor.crystal_destroyed/6`, a striker `{id, position, height,
    /// eligible, attacker}`: its hurt's events) or `{:ignites, hit}`
    /// (`Dragon.ignites?/2`).
    #[rustler::nif]
    fn dragon_oracle_actor<'a>(
        env: Env<'a>,
        res: ResourceArc<crate::mob_section::MobSectionRes>,
        id: i32,
        op: Term<'a>,
        scene_term: Term<'a>,
    ) -> NifResult<Term<'a>> {
        let op = mob_term::decode(op)?;
        let (tag, args) = match &op {
            Value::Tuple(items) => (
                items.first().and_then(Value::as_atom).ok_or_else(bad)?,
                &items[1..],
            ),
            Value::Atom(a) => (a, &[][..]),
            _ => return Err(bad()),
        };
        let mut inner = crate::mob_section::owned(env, &res)?;
        let slot = inner.section.get_mut(id).ok_or_else(bad)?;
        let mob = &mut slot.mob;
        let out = with_scene(scene_term, |rules, _, denv| match (tag.as_str(), args) {
            ("tick", []) => {
                dragon::timers(&mut mob.body);
                let eye =
                    valimc_core::mobs::living::mob::Type::of(rules.facts, &mob.body.entity_type)
                        .map_or(0.0, |t| t.facts.eye_height);
                let [x, y, z] = mob.position;
                denv.eye = [x, y + eye, z];
                let step = actor::tick(rules, mob, denv);
                mob.position = step.position;
                let [x, y, z] = step.position;
                let events = Value::List(step.events.iter().map(|e| e.value()).collect());
                let effects = Value::List(step.effects.iter().map(|e| e.value()).collect());
                Ok((
                    (x, y, z),
                    mob_term::encode(env, &events)?,
                    mob_term::encode(env, &effects)?,
                )
                    .encode(env))
            }
            ("timers", [n]) => {
                for _ in 0..n.as_int().ok_or_else(bad)? {
                    dragon::timers(&mut mob.body);
                }
                Ok(rustler::types::atom::ok().encode(env))
            }
            ("crystal", [crystal, direct, striker]) => {
                let [duuid, did, dpos] = direct.as_tuple_n::<3>().ok_or_else(bad)?;
                let direct = CrystalHit {
                    uuid: uuid_of(duuid)?,
                    entity_id: did.as_int().ok_or_else(bad)? as i32,
                    position: vec_of(dpos)?,
                };
                let striker = match striker.as_tuple() {
                    Some([pid, position, height, eligible, attacker]) => Some(Striker {
                        player: Player {
                            id: pid.as_int().ok_or_else(bad)?,
                            position: vec_of(position)?,
                            height: height.as_number().ok_or_else(bad)?,
                        },
                        eligible: eligible.as_bool().ok_or_else(bad)?,
                        attacker: crate::mob_section::attacker(attacker)?,
                    }),
                    _ => None,
                };
                let events = actor::crystal_destroyed(
                    rules,
                    mob,
                    &uuid_of(crystal)?,
                    &direct,
                    striker.as_ref(),
                    denv,
                );
                let events = Value::List(
                    events
                        .iter()
                        .map(|e| crate::mob_living_parity::event(rules.facts, e))
                        .collect(),
                );
                mob_term::encode(env, &events)
            }
            ("ignites", [hit]) => {
                let hit = crate::mob_section::hit_of(rules, hit)?;
                Ok(dragon::Dragon::ignites(&mob.body, &hit).encode(env))
            }
            _ => Err(bad()),
        })?;
        inner.section.relocate(id);
        Ok(out)
    }
}
