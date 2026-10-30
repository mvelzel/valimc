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
