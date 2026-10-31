//! What a section's turns read of the world (VMC-081d): the level
//! (`mobs::level::Level`) over the ticker's published snapshots and the
//! section's store, the sensed rows of the group's players and items, and
//! the effects leaving mobs as the effect tuples the owner applies.

use crate::mob_term;
use crate::physics as physics_nif;
use crate::region::Region;
use rustler::{NifResult, Term};
use std::collections::HashMap;
use valimc_core::mobs::ai::effect::{Eaten, Effect};
use valimc_core::mobs::facts::MobFacts;
use valimc_core::mobs::level::{Difficulty, Environment, Level, Rules as LevelRules};
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::sensing::{GameMode, Kind, Ref, SensedItem, SensedPlayer, EQUIPMENT};
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::tick::tagged;
use valimc_core::physics::Aabb;

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

/// The level's scalars a tick reads (`mob_world/3`'s), from the owner's map.
#[derive(Clone, Debug)]
pub struct LevelEnv {
    pub time: i64,
    pub day: i64,
    pub difficulty: Difficulty,
    pub darken: i32,
    pub bright: bool,
    pub monsters_burn: bool,
    pub halloween: bool,
    pub rules: LevelRules,
    pub goals: bool,
    pub min_y: i32,
    pub max_y: i32,
    pub sea_level: i32,
    pub border: Option<[f64; 4]>,
    pub knots: HashMap<[i32; 3], i32>,
    pub wet: bool,
    pub zoom_seed: i64,
    /// An oracle scene's light (no region): full sky light above each
    /// column's top block (`tops`: `{x, z} => y`), none below.
    pub tops: Option<HashMap<(i32, i32), i32>>,
    /// An oracle scene has no chunks (`hasChunk` false), and the AI reads
    /// air beyond its blocks (as its level holds them).
    pub no_chunks: bool,
    /// The dimension (`World.dimension`, a POI memory's `GlobalPos`).
    pub dimension: valimc_core::mobs::term::Atom,
    /// Its time stands still (the Nether, the End).
    pub fixed_time: bool,
    /// An oracle scene's structure queries answered at once (its
    /// `locate`: `{x, y, z}` or nil); None: deferred to the owner's job.
    pub locate: Option<Option<[i32; 3]>>,
}

/// A structure query's answer given at once.
pub struct FixedLocator(pub Option<[i32; 3]>);

impl valimc_core::mobs::level::Locator for FixedLocator {
    fn locate(&self, _query: &valimc_core::mobs::level::Query) -> Option<[i32; 3]> {
        self.0
    }
}

fn map_of(v: &Value) -> NifResult<&Map> {
    v.as_map().ok_or_else(bad)
}

fn get<'a>(m: &'a Map, key: &str) -> NifResult<&'a Value> {
    m.get_atom(key).ok_or_else(bad)
}

fn num(m: &Map, key: &str) -> NifResult<f64> {
    get(m, key)?.as_number().ok_or_else(bad)
}

fn int(m: &Map, key: &str) -> NifResult<i64> {
    get(m, key)?.as_int().ok_or_else(bad)
}

fn flag(m: &Map, key: &str) -> bool {
    m.get_atom(key).and_then(Value::as_bool) == Some(true)
}

fn atom<'a>(m: &'a Map, key: &str) -> NifResult<&'a str> {
    Ok(get(m, key)?.as_atom().ok_or_else(bad)?.as_str())
}

fn vec3(v: &Value) -> Option<[f64; 3]> {
    let [x, y, z] = v.as_tuple_n::<3>()?;
    Some([x.as_number()?, y.as_number()?, z.as_number()?])
}

fn uuid(v: &Value) -> NifResult<[u8; 16]> {
    v.as_binary()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(bad)
}

impl LevelEnv {
    /// From `%{time, day, difficulty, darken, bright, monsters_burn,
    /// halloween, mob_griefing, mob_drops, entity_drops, universal_anger,
    /// goals, min_y, max_y, sea_level, border, knots, wet, zoom_seed}`.
    pub fn decode(term: Term) -> NifResult<LevelEnv> {
        let v = mob_term::decode(term)?;
        let m = map_of(&v)?;
        let difficulty = match atom(m, "difficulty")? {
            "peaceful" => Difficulty::Peaceful,
            "easy" => Difficulty::Easy,
            "normal" => Difficulty::Normal,
            "hard" => Difficulty::Hard,
            _ => return Err(bad()),
        };
        let border = match m.get_atom("border").filter(|b| !b.is_nil()) {
            None => None,
            Some(b) => {
                let [a, b2, c, d] = b.as_tuple_n::<4>().ok_or_else(bad)?;
                Some([
                    a.as_number().ok_or_else(bad)?,
                    b2.as_number().ok_or_else(bad)?,
                    c.as_number().ok_or_else(bad)?,
                    d.as_number().ok_or_else(bad)?,
                ])
            }
        };
        let mut knots = HashMap::new();
        for k in get(m, "knots")?.as_list().ok_or_else(bad)? {
            let [p, id] = k.as_tuple_n::<2>().ok_or_else(bad)?;
            let [x, y, z] = p.as_tuple_n::<3>().ok_or_else(bad)?;
            let c = |v: &Value| v.as_int().map(|i| i as i32).ok_or_else(bad);
            knots.insert([c(x)?, c(y)?, c(z)?], c(id)?);
        }
        Ok(LevelEnv {
            time: int(m, "time")?,
            day: int(m, "day")?,
            difficulty,
            darken: int(m, "darken")? as i32,
            bright: flag(m, "bright"),
            monsters_burn: flag(m, "monsters_burn"),
            halloween: flag(m, "halloween"),
            rules: LevelRules {
                mob_griefing: flag(m, "mob_griefing"),
                mob_drops: flag(m, "mob_drops"),
                entity_drops: flag(m, "entity_drops"),
                universal_anger: flag(m, "universal_anger"),
            },
            goals: flag(m, "goals"),
            min_y: int(m, "min_y")? as i32,
            max_y: int(m, "max_y")? as i32,
            sea_level: int(m, "sea_level")? as i32,
            border,
            knots,
            wet: flag(m, "wet"),
            zoom_seed: int(m, "zoom_seed")?,
            tops: match m.get_atom("tops").filter(|t| !t.is_nil()) {
                None => None,
                Some(t) => {
                    let mut tops = HashMap::new();
                    for e in t.as_list().ok_or_else(bad)? {
                        let [x, z, y] = e.as_tuple_n::<3>().ok_or_else(bad)?;
                        let c = |v: &Value| v.as_int().map(|i| i as i32).ok_or_else(bad);
                        tops.insert((c(x)?, c(z)?), c(y)?);
                    }
                    Some(tops)
                }
            },
            no_chunks: flag(m, "no_chunks"),
            dimension: match m.get_atom("dimension").and_then(Value::as_atom) {
                Some(a) => a.clone(),
                None => valimc_core::mobs::term::Atom::new("overworld"),
            },
            fixed_time: flag(m, "fixed_time"),
            locate: match m.get_atom("locate") {
                None => None,
                Some(v) if v.is_nil() => Some(None),
                Some(v) => {
                    let [x, y, z] = v.as_tuple_n::<3>().ok_or_else(bad)?;
                    let c = |v: &Value| v.as_int().map(|i| i as i32).ok_or_else(bad);
                    Some(Some([c(x)?, c(y)?, c(z)?]))
                }
            },
        })
    }

    /// What the AI reads: the view, or air where it cannot be read (an
    /// oracle scene's).
    pub fn blocks<'a>(
        &self,
        view: &'a dyn valimc_core::physics::source::BlockSource,
        air: &'a valimc_core::physics::source::AirWhereUnreadable<'a>,
    ) -> &'a dyn valimc_core::physics::source::BlockSource {
        if self.no_chunks {
            air
        } else {
            view
        }
    }

    /// The level over `blocks` and `environment` with the level random
    /// `random`.
    pub fn level<'a>(
        &self,
        blocks: &'a dyn valimc_core::physics::source::BlockSource,
        environment: &'a dyn Environment,
        facts: &'a MobFacts,
        random: LegacyRandom,
    ) -> NifResult<Level<'a>> {
        let physics = physics_nif::facts()?;
        let states = crate::facts::STATES.get().ok_or_else(bad)?;
        let mut level = Level::new(blocks, environment, facts, physics, states, random);
        level.time = self.time;
        level.day = self.day;
        level.difficulty = self.difficulty;
        level.darken = self.darken;
        level.bright = self.bright;
        level.monsters_burn = self.monsters_burn;
        level.halloween = self.halloween;
        level.rules = self.rules;
        level.goals = self.goals;
        level.min_y = self.min_y;
        level.max_y = self.max_y;
        level.sea_level = self.sea_level;
        level.border = self.border;
        level.knots = self.knots.clone();
        level.dimension = self.dimension.clone();
        level.fixed_time = self.fixed_time;
        Ok(level)
    }
}

/// Light and biomes from the section's store (`Blocks.light/2`,
/// `Blocks.biome/3`), each read under its lock alone (light updates and
/// encodings hold it elsewhere), and rain over the ticker's snapshots
/// (`RainQuery.sample/3`).
pub struct SectionEnv<'a> {
    pub region: Option<&'a Region>,
    pub view: &'a physics_nif::View<physics_nif::SnapshotArc>,
    pub facts: &'a MobFacts,
    pub zoom_seed: i64,
    pub wet: bool,
    pub sea_level: i32,
    pub plains: u16,
    /// `LevelEnv::tops` and `no_chunks` (oracle scenes).
    pub tops: Option<&'a HashMap<(i32, i32), i32>>,
    pub no_chunks: bool,
}

impl Environment for SectionEnv<'_> {
    fn light(&self, p: [i32; 3]) -> Option<(u8, u8)> {
        if let (None, Some(tops)) = (self.region, self.tops) {
            let top = tops.get(&(p[0], p[2])).copied().unwrap_or(-65);
            return Some((if p[1] > top { 15 } else { 0 }, 0));
        }
        let store = self.region?.store.lock().ok()?;
        store.light_at(p[0], p[1], p[2])
    }

    fn chunk_loaded(&self, _chunk: (i32, i32)) -> Option<bool> {
        self.no_chunks.then_some(false)
    }

    /// `StandUp.bed/4` over the tick's snapshots, or an oracle scene's
    /// supplied blocks (where a villager gets up).
    fn stand_up(&self, _type_id: u16, head: [i32; 3], facing: u8, yaw: f64) -> Option<[f64; 3]> {
        stand_up(self.view, self.facts, head, facing as usize & 3, yaw)
    }

    /// `View.find/3` over the tick's snapshots: a chunk it cannot read
    /// holds none; an oracle scene's supplied states are searched as its
    /// `find` searches its blocks (in no particular order: its searches pick
    /// by distance).
    fn find(&self, chunk: (i32, i32), states: &[u16]) -> Option<Vec<(i32, i32, i32, u16)>> {
        match self.view {
            physics_nif::View::Rows(rows) => Some(
                rows.snapshot(chunk)
                    .map(|s| s.find(states))
                    .unwrap_or_default(),
            ),
            physics_nif::View::States(supplied) => {
                let mut found: Vec<(i32, i32, i32, u16)> = supplied
                    .0
                    .iter()
                    .filter(|(p, s)| (p[0] >> 4, p[2] >> 4) == chunk && states.contains(s))
                    .map(|(p, s)| (p[0], p[1], p[2], *s))
                    .collect();
                found.sort_unstable();
                Some(found)
            }
        }
    }

    fn biome(&self, p: [i32; 3]) -> Option<u16> {
        let quart = valimc_core::worldgen::surface::zoom(self.zoom_seed, p[0], p[1], p[2]);
        let store = self.region?.store.lock().ok()?;
        store.noise_biome(quart, self.plains)
    }

    fn rain(&self, position: [f64; 3], top: f64) -> Option<bool> {
        let physics_nif::View::Rows(rows) = self.view else {
            return Some(false);
        };
        let flags = crate::facts::FLAGS.get()?;
        let light = crate::facts::LIGHT.get()?;
        let column = |x: i32, z: i32| {
            rows.snapshot((x >> 4, z >> 4))
                .map(|s| s.column(x, z, flags, light))
        };
        let biome = |p: [i32; 3]| {
            let (qx, qy, qz) =
                valimc_core::worldgen::surface::zoom(self.zoom_seed, p[0], p[1], p[2]);
            let s = rows.snapshot((qx >> 2, qz >> 2))?;
            Some(s.biome((qx, qy, qz)).unwrap_or(self.plains))
        };
        Some(
            valimc_core::mobs::level::rain_at(
                &self.facts.climates,
                self.wet,
                self.sea_level,
                position,
                top,
                column,
                biome,
            ) == Some(true),
        )
    }
}

fn ref_value(r: &Ref) -> Value {
    let kind = match r.kind {
        Kind::Player => "player",
        Kind::Mob => "mob",
        Kind::Item => "item",
    };
    Value::tuple([Value::atom(kind), Value::Binary(r.uuid.to_vec())])
}

/// A sensed player (`Player.Host.sensed/1`'s map, its effects a list).
pub fn player(term: Term) -> NifResult<SensedPlayer> {
    let v = mob_term::decode(term)?;
    let m = map_of(&v)?;
    let mode = match atom(m, "mode")? {
        "survival" => GameMode::Survival,
        "creative" => GameMode::Creative,
        "adventure" => GameMode::Adventure,
        "spectator" => GameMode::Spectator,
        _ => return Err(bad()),
    };
    let mut equipment = [None; 6];
    if let Some(eq) = m.get_atom("equipment").and_then(Value::as_map) {
        for (e, slot) in equipment.iter_mut().zip(EQUIPMENT) {
            let key = match slot {
                valimc_core::mobs::facts::Slot::Chest => "chest",
                valimc_core::mobs::facts::Slot::Feet => "feet",
                valimc_core::mobs::facts::Slot::Head => "head",
                valimc_core::mobs::facts::Slot::Legs => "legs",
                valimc_core::mobs::facts::Slot::MainHand => "mainhand",
                valimc_core::mobs::facts::Slot::OffHand => "offhand",
                _ => continue,
            };
            *e = eq.get_atom(key).and_then(Value::as_int).map(|i| i as i32);
        }
    }
    let mut effects: Vec<u16> = m
        .get_atom("effects")
        .and_then(Value::as_list)
        .map(|l| {
            l.iter()
                .filter_map(|e| e.as_int().map(|i| i as u16))
                .collect()
        })
        .unwrap_or_default();
    effects.sort_unstable();
    Ok(SensedPlayer {
        uuid: uuid(get(m, "uuid")?)?,
        id: int(m, "id")? as i32,
        position: [num(m, "x")?, num(m, "y")?, num(m, "z")?],
        yaw: num(m, "yaw").unwrap_or(0.0),
        pitch: num(m, "pitch").unwrap_or(0.0),
        eye: num(m, "eye")?,
        width: num(m, "width")?,
        height: num(m, "height")?,
        mode,
        invulnerable: flag(m, "invulnerable"),
        alive: flag(m, "alive"),
        crouching: flag(m, "crouching"),
        swimming: flag(m, "swimming"),
        invisible: flag(m, "invisible"),
        armor_cover: num(m, "armor_cover").unwrap_or(0.0),
        equipment,
        movement: m.get_atom("movement").and_then(vec3).unwrap_or([0.0; 3]),
        velocity: m.get_atom("velocity").and_then(vec3).unwrap_or([0.0; 3]),
        health: num(m, "health").unwrap_or(20.0),
        effects,
    })
}

/// A sensed item (`mob_world/3`'s item rows).
pub fn item(term: Term) -> NifResult<SensedItem> {
    if term.is_tuple() {
        return compact_item(term);
    }
    let v = mob_term::decode(term)?;
    let m = map_of(&v)?;
    let components = m
        .get_atom("components")
        .filter(|c| c.as_map().is_some_and(|m| !m.is_empty()))
        .cloned();
    Ok(SensedItem {
        uuid: uuid(get(m, "uuid")?)?,
        position: [num(m, "x")?, num(m, "y")?, num(m, "z")?],
        item: int(m, "item")? as i32,
        count: int(m, "count")? as i32,
        pickup_delay: int(m, "pickup_delay").unwrap_or(0) as i32,
        in_water: flag(m, "in_water"),
        components,
    })
}

/// A sensed item as the owner packs it each tick (`RegionData.sensed_items/1`):
/// `{uuid, x, y, z, item, count, pickup_delay, in_water, components | nil}`.
fn compact_item(term: Term) -> NifResult<SensedItem> {
    let t = rustler::types::tuple::get_tuple(term)?;
    if t.len() != 9 {
        return Err(bad());
    }
    let b: rustler::Binary = t[0].decode()?;
    let components = if t[8].is_atom() {
        None
    } else {
        Some(mob_term::decode(t[8])?).filter(|c| c.as_map().is_some_and(|m| !m.is_empty()))
    };
    Ok(SensedItem {
        uuid: b.as_slice().try_into().map_err(|_| bad())?,
        position: [t[1].decode()?, t[2].decode()?, t[3].decode()?],
        item: t[4].decode()?,
        count: t[5].decode()?,
        pickup_delay: t[6].decode()?,
        in_water: t[7].decode()?,
        components,
    })
}

fn ivec(c: &[i32; 3]) -> Value {
    Value::ivec3([c[0].into(), c[1].into(), c[2].into()])
}

/// An effect leaving a native mob as the Elixir effect tuple
/// (`RegionData.move_mobs/1` applies it); None for one the section applied
/// (another mob's change) or that has no tuple.
pub fn effect(facts: &MobFacts, e: &Effect) -> Option<Value> {
    let name = |id: u16| Value::Binary(facts.entities.name(id).unwrap_or("").as_bytes().to_vec());
    Some(match e {
        Effect::Attack(r) => Value::tuple([Value::atom("attack"), ref_value(r)]),
        Effect::AttackExtra(r, v) => {
            Value::tuple([Value::atom("attack_extra"), ref_value(r), v.clone()])
        }
        Effect::Hurt {
            target,
            kind,
            amount,
            actions,
        } => Value::Tuple(vec![
            Value::atom("hurt"),
            ref_value(target),
            kind.clone(),
            Value::Float(*amount),
            actions.clone(),
        ]),
        Effect::Touch {
            target,
            amount,
            sound,
        } => Value::tuple([
            Value::atom("touch"),
            ref_value(target),
            Value::Float(*amount),
            sound.clone(),
        ]),
        Effect::GiveEffect { target, actions } => {
            Value::tuple([Value::atom("effect"), ref_value(target), actions.clone()])
        }
        Effect::Offspring { type_id, data, at } => Value::tuple([
            Value::atom("offspring"),
            name(*type_id),
            data.clone(),
            Value::vec3(*at),
        ]),
        Effect::Orb { value, at } => Value::tuple([
            Value::atom("orb"),
            Value::Int(*value as i64),
            Value::vec3(*at),
        ]),
        Effect::EatBlock { cell, how } => Value::tuple([
            Value::atom("eat_block"),
            ivec(cell),
            Value::atom(match how {
                Eaten::Dirt => "dirt",
                Eaten::Destroy => "destroy",
            }),
        ]),
        Effect::RemoveBlock(c) => Value::tuple([Value::atom("remove_block"), ivec(c)]),
        Effect::TakeBlock(v) => tagged("take_block", v.clone()),
        Effect::PlaceCarried { cell, state } => Value::tuple([
            Value::atom("place_carried"),
            ivec(cell),
            Value::Int(*state as i64),
        ]),
        Effect::Trample(c) => Value::tuple([Value::atom("trample"), ivec(c)]),
        Effect::CrushEgg { cell, odds } => Value::tuple([
            Value::atom("crush_egg"),
            ivec(cell),
            Value::Int(*odds as i64),
        ]),
        Effect::RaidCarrot(c) => Value::tuple([Value::atom("raid_carrot"), ivec(c)]),
        Effect::LayEggs(v) => tagged("lay_eggs", v.clone()),
        Effect::Infest { cell, state } => {
            Value::tuple([Value::atom("infest"), ivec(cell), Value::Int(*state as i64)])
        }
        Effect::WakeInfested(v) => tagged("wake_infested", v.clone()),
        Effect::Door { cell, open } => {
            Value::tuple([Value::atom("door"), ivec(cell), Value::bool(*open)])
        }
        Effect::Bed { cell, occupied } => {
            Value::tuple([Value::atom("bed"), ivec(cell), Value::bool(*occupied)])
        }
        Effect::Shoot(shot) => {
            let mut m = Map::new();
            m.insert_atom("target", ref_value(&shot.target));
            m.insert_atom(
                "at",
                Value::Tuple(shot.at.iter().map(|&v| Value::Float(v)).collect()),
            );
            m.insert_atom("from", Value::vec3(shot.from));
            m.insert_atom("power", Value::Float(shot.power));
            m.insert_atom("pitch", Value::Float(shot.pitch));
            Value::tuple([Value::atom("shoot"), Value::Map(m)])
        }
        Effect::Projectile(v) => tagged("projectile", v.clone()),
        Effect::ThrowPotion(v) => Value::tuple([Value::atom("throw_potion"), v.clone()]),
        Effect::ThrowTrident(v) => Value::tuple([Value::atom("throw_trident"), v.clone()]),
        Effect::Throw(v) => tagged("throw", v.clone()),
        Effect::ShootBullet(v) => tagged("shoot_bullet", v.clone()),
        Effect::Explode(v) => Value::tuple([Value::atom("explode"), v.clone()]),
        Effect::Pickup { item, count } => Value::tuple([
            Value::atom("pickup"),
            Value::tuple([Value::atom("item"), Value::Binary(item.to_vec())]),
            Value::Int(*count as i64),
        ]),
        Effect::Drop(stack) => Value::tuple([Value::atom("drop"), stack.clone()]),
        // A piglin's barter: the owner rolls the bartering table with the
        // seed and throws each item.
        Effect::Barter {
            seed,
            from,
            velocity,
        } => Value::tuple([
            Value::atom("barter"),
            Value::Int(*seed),
            Value::vec3(*from),
            Value::vec3(*velocity),
        ]),
        Effect::Lay(v) => Value::tuple([Value::atom("lay"), Value::vec3(*v)]),
        Effect::Gift { table, velocity } => Value::tuple([
            Value::atom("gift"),
            Value::Binary(table.as_bytes().to_vec()),
            Value::vec3(*velocity),
        ]),
        Effect::Lead(at) => Value::tuple([Value::atom("lead"), Value::vec3(*at)]),
        Effect::KnotFree(c) => Value::tuple([Value::atom("knot_free"), ivec(c)]),
        Effect::MakeKnot(c) => Value::tuple([Value::atom("make_knot"), ivec(c)]),
        Effect::Spawn { type_id, options } => {
            Value::tuple([Value::atom("spawn"), name(*type_id), options.clone()])
        }
        // A companion made whole (a spider jockey's skeleton): its record,
        // which the owner adopts where this mob stands.
        Effect::SpawnBody(mob) => Value::tuple([
            Value::atom("spawn_body"),
            valimc_core::mobs::record::record(mob),
            Value::Binary(mob.uuid.to_vec()),
        ]),
        Effect::SpawnMob(v) => tagged("spawn_mob", v.clone()),
        Effect::Jockey(u) => Value::tuple([Value::atom("jockey"), Value::Binary(u.to_vec())]),
        Effect::Convert(to) => Value::tuple([Value::atom("convert"), name(*to)]),
        Effect::Discard => Value::atom("discard"),
        Effect::ElderCurse(at) => Value::tuple([Value::atom("elder_curse"), Value::vec3(*at)]),
        Effect::ShulkerPush(v) => tagged("shulker_push", v.clone()),
        Effect::Locate(v) => tagged("locate", v.clone()),
        Effect::Merchant(v) => tagged("merchant", v.clone()),
        // The section applied these to its own mobs, or they are events.
        Effect::Alert { .. }
        | Effect::Bred(_)
        | Effect::Own { .. }
        | Effect::Remote { .. }
        | Effect::Brain { .. }
        | Effect::Sound { .. }
        | Effect::SoundAt { .. }
        | Effect::SoundBlock(_)
        | Effect::Swing(_)
        | Effect::Event(_)
        | Effect::LevelEvent { .. }
        | Effect::Living(_) => {
            if let Effect::LevelEvent { cell, kind, data } = e {
                return Some(Value::Tuple(vec![
                    Value::atom("level_event"),
                    ivec(cell),
                    Value::Int(*kind as i64),
                    Value::Int(*data as i64),
                ]));
            }
            let _ = NIL;
            return None;
        }
    })
}

// ---------------------------------------------------------------- stand up

/// What standing up from a bed reads of a state (`Valimc.Data.SleepFacts`):
/// its flags (2 dangerous, 4 not to be inside), its floor height, and which
/// blocks are beds.
pub struct SleepFacts {
    flags: Vec<u8>,
    floor_states: Vec<u8>,
    floors: Vec<Option<f64>>,
    beds: std::collections::HashSet<u16>,
}

static SLEEP: std::sync::OnceLock<SleepFacts> = std::sync::OnceLock::new();

/// Installs the sleep facts once per VM (`NativeMobs.install!/0`): the
/// per-state flag and floor-index binaries, the floors and the bed blocks'
/// names. A second install keeps the first.
#[rustler::nif]
fn mob_sleep_install(
    flags: rustler::Binary,
    floor_states: rustler::Binary,
    floors: Vec<Option<f64>>,
    beds: Vec<String>,
) -> NifResult<bool> {
    let facts = crate::mob_facts::facts()?;
    let beds = beds
        .iter()
        .filter_map(|name| facts.blocks.id(name))
        .collect();
    Ok(SLEEP
        .set(SleepFacts {
            flags: flags.as_slice().to_vec(),
            floor_states: floor_states.as_slice().to_vec(),
            floors,
            beds,
        })
        .is_ok())
}

impl SleepFacts {
    fn dangerous(&self, state: u16) -> bool {
        self.flags.get(state as usize).is_some_and(|f| f & 2 != 0)
    }

    fn invalid_inside(&self, state: u16) -> bool {
        self.flags.get(state as usize).is_some_and(|f| f & 4 != 0)
    }

    fn floor(&self, state: u16) -> Option<f64> {
        let i = *self.floor_states.get(state as usize)?;
        self.floors.get(i as usize).copied().flatten()
    }
}

/// North, south, west, east (the villager's facing index).
const STEPS: [(i32, i32); 4] = [(0, -1), (0, 1), (-1, 0), (1, 0)];
const CLOCKWISE: [usize; 4] = [3, 2, 0, 1];
const OPPOSITE: [usize; 4] = [1, 0, 3, 2];

/// `StandUp.bed/4`: where a standing player gets up from the bed whose
/// head is at `head` facing `facing` when it looks at `yaw`, over `view`.
pub fn stand_up(
    view: &dyn valimc_core::physics::source::BlockSource,
    facts: &MobFacts,
    head: [i32; 3],
    facing: usize,
    yaw: f64,
) -> Option<[f64; 3]> {
    let sleep = SLEEP.get()?;
    let physics = physics_nif::facts().ok()?;
    let state = |p: [i32; 3]| view.state(p[0], p[1], p[2]).unwrap_or(0);
    let is_bed = |s: u16| {
        facts
            .blocks
            .block_id(s)
            .is_some_and(|id| sleep.beds.contains(&id))
    };
    let right = CLOCKWISE[facing];
    let side = if facing_angle(right, yaw) {
        OPPOSITE[right]
    } else {
        right
    };
    let (fx, fz) = STEPS[facing];
    let (sx, sz) = STEPS[side];
    let surround = [
        (sx, sz),
        (sx - fx, sz - fz),
        (sx - fx * 2, sz - fz * 2),
        (-fx * 2, -fz * 2),
        (-sx - fx * 2, -sz - fz * 2),
        (-sx - fx, -sz - fz),
        (-sx, -sz),
        (-sx + fx, -sz + fz),
        (fx, fz),
        (sx + fx, sz + fz),
    ];
    let above = [(0, 0), (-fx, -fz)];
    let safe = |[x, y, z]: [i32; 3], check: bool| -> Option<[f64; 3]> {
        let here = state([x, y, z]);
        let below = state([x, y - 1, z]);
        if check && sleep.dangerous(here) {
            return None;
        }
        let floor = match sleep.floor(here) {
            Some(h) => h,
            None => match sleep.floor(below) {
                Some(h) if h >= 1.0 => h - 1.0,
                _ => return None,
            },
        };
        if floor >= 1.0 || (check && floor <= 0.0 && sleep.dangerous(below)) {
            return None;
        }
        let position = [x as f64 + 0.5, y as f64 + floor, z as f64 + 0.5];
        const HALF: f64 = 0.30000001192092896;
        const HEIGHT: f64 = 1.7999999523162842;
        let [px, py, pz] = position;
        let body = Aabb::new(
            [px - HALF, py, pz - HALF],
            [px + HALF, py + HEIGHT, pz + HALF],
        );
        let ctx = valimc_core::physics::Context {
            entity: false,
            bottom: 0.0,
            descending: false,
            placement: false,
            entity_present: false,
            fall_distance: 0.0,
            falling_block: false,
            powder_snow_walkable: false,
            lava_walker: false,
            noclip: None,
        };
        let extra = valimc_core::physics::collide::Extra {
            entities: Vec::new(),
            border: None,
            subject: [px, pz],
        };
        match valimc_core::physics::collide::no_collision(
            view,
            &physics.shapes,
            &body,
            &ctx,
            &extra,
        ) {
            Ok(true) => {}
            _ => return None,
        }
        if sleep.invalid_inside(here) || sleep.invalid_inside(state([x, y + 1, z])) {
            return None;
        }
        Some(position)
    };
    let at = |[x, y, z]: [i32; 3], offsets: &[(i32, i32)], check: bool| {
        offsets
            .iter()
            .find_map(|&(dx, dz)| safe([x + dx, y, z + dz], check))
    };
    let [x, y, z] = head;
    if is_bed(state([x, y - 1, z])) {
        let below = [x, y - 1, z];
        [
            (head, &surround[..], true),
            (below, &surround[..], true),
            (head, &above[..], true),
            (head, &surround[..], false),
            (below, &surround[..], false),
            (head, &above[..], false),
        ]
        .into_iter()
        .find_map(|(cell, offsets, check)| at(cell, offsets, check))
    } else {
        let offsets: Vec<(i32, i32)> = surround.iter().chain(above.iter()).copied().collect();
        at(head, &offsets, true).or_else(|| at(head, &offsets, false))
    }
}

/// `Direction.isFacingAngle` over `Mth`'s sine table.
fn facing_angle(direction: usize, yaw: f64) -> bool {
    use valimc_core::mobs::living::f;
    let (nx, nz) = STEPS[direction];
    let radians = f(yaw * f(std::f64::consts::PI / 180.0));
    let dx = -(valimc_core::mobs::mth::sin(radians) as f64);
    let dz = valimc_core::mobs::mth::cos(radians) as f64;
    f(f(nx as f64 * dx) + f(nz as f64 * dz)) > 0.0
}
