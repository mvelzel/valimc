//! Oracle NIFs of the AI stages (VMC-081d), built only with the `parity`
//! feature: a fresh mob's `finalizeSpawn` in a scene and the equipment it
//! drops dying (`check_hostile_spawns`, `check_animals`), a breeding
//! (`check_animals`) and aquatic packs (`check_aquatic_packs`). Each mob is
//! made first and keeps its record's random, as the oracles seed a mob after
//! its constructor ran (a brain's sensors drew on its random before).

use crate::mob_section as ms;
use crate::mob_term;
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use valimc_core::mobs::ai::effect::Effect;
use valimc_core::mobs::ai::think::{self, Ctx};
use valimc_core::mobs::ai::turn::Seen;
use valimc_core::mobs::combat;
use valimc_core::mobs::level::{Difficulty, Environment, Level, Unknown};
use valimc_core::mobs::living::difficulty::LocalDifficulty;
use valimc_core::mobs::living::items;
use valimc_core::mobs::living::mob::Type;
use valimc_core::mobs::model::NativeMob;
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::sensing::{Kind as RefKind, Ref, Sensing};
use valimc_core::mobs::term::{Map, Value};
use valimc_core::physics::source::BlockSource;

fn bad() -> rustler::Error {
    rustler::Error::BadArg
}

fn field<'a>(m: &'a Map, key: &str) -> Option<&'a Value> {
    m.get_atom(key).filter(|v| !v.is_nil())
}

fn get<'a>(m: &'a Map, key: &str) -> NifResult<&'a Value> {
    field(m, key).ok_or_else(bad)
}

fn int(v: &Value) -> NifResult<i64> {
    v.as_int().ok_or_else(bad)
}

fn random(state: i64) -> NifResult<LegacyRandom> {
    LegacyRandom::from_state(state as u64).ok_or_else(bad)
}

/// Mob `record` restored with its mind made, its random the record's.
fn made(ctx: &Ctx, record: Term) -> NifResult<NativeMob> {
    let mut mob = ms::restore(&mob_term::decode(record)?)?.map_err(|_| bad())?;
    let kept = mob.body.mob.ai.as_ref().map(|m| m.random);
    think::ensure(ctx, &mut mob);
    if let (Some(random), Some(mind)) = (kept, mob.body.mob.ai.as_mut()) {
        mind.random = random;
    }
    Ok(mob)
}

/// A scene's blocks, air elsewhere.
struct Scene {
    blocks: HashMap<[i32; 3], u16>,
    air: u16,
}

impl BlockSource for Scene {
    fn state(&self, x: i32, y: i32, z: i32) -> Option<u16> {
        Some(*self.blocks.get(&[x, y, z]).unwrap_or(&self.air))
    }
}

/// One biome everywhere, no light.
struct OneBiome(Option<u16>);

impl Environment for OneBiome {
    fn light(&self, _p: [i32; 3]) -> Option<(u8, u8)> {
        None
    }
    fn biome(&self, _p: [i32; 3]) -> Option<u16> {
        self.0
    }
}

fn difficulty(v: &Value) -> NifResult<Difficulty> {
    Ok(match v.as_atom().ok_or_else(bad)?.as_str() {
        "peaceful" => Difficulty::Peaceful,
        "easy" => Difficulty::Easy,
        "normal" => Difficulty::Normal,
        "hard" => Difficulty::Hard,
        _ => return Err(bad()),
    })
}

/// Mob `record`'s `finalizeSpawn` for its pending reason (its family's
/// `Kind::finalize`, run as a turn does) in `scene` (`%{random, difficulty,
/// local, biome, halloween, blocks, air, mobs}`: the level random's state;
/// the local difficulty's `{time, inhabited, moon}` or nil; a biome name or
/// nil; `[{x, y, z, state}]`; the mobs it senses, `[{id, record}]`), with
/// `loot`'s enchanting; then, where `death` is `{hit, by_player}`, the
/// equipment it drops dying of `hit` (`dropCustomDeathLoot`). `{record,
/// young, hunted_recently ttl | nil, jockey, spawned, level random, death |
/// nil}`: `jockey` `"existing"` (it rides a mob it sensed), `"new"` (it made
/// its mount) or nil, `spawned` the types it made, `death` `{[{item,
/// damage}], its random after}`.
#[rustler::nif]
fn mob_oracle_ai_spawn<'a>(
    env: Env<'a>,
    record: Term<'a>,
    scene: Term<'a>,
    loot: ResourceArc<crate::loot::LootRegistry>,
    death: Term<'a>,
) -> NifResult<Term<'a>> {
    let rules = ms::rules()?;
    let ctx = ms::ctx(&rules)?;
    let facts = rules.facts;
    let physics = crate::facts::PHYSICS.get().ok_or_else(bad)?;
    let states = crate::facts::STATES.get().ok_or_else(bad)?;
    let scene = mob_term::decode(scene)?;
    let m = scene.as_map().ok_or_else(bad)?;
    let mut mob = made(&ctx, record)?;
    let mut blocks = HashMap::new();
    for b in get(m, "blocks")?.as_list().ok_or_else(bad)? {
        let [x, y, z, s] = b.as_tuple_n::<4>().ok_or_else(bad)?;
        blocks.insert(
            [int(x)? as i32, int(y)? as i32, int(z)? as i32],
            int(s)? as u16,
        );
    }
    let blocks = Scene {
        blocks,
        air: int(get(m, "air")?)? as u16,
    };
    let biome = match field(m, "biome") {
        Some(name) => {
            let name = name.as_binary().ok_or_else(bad)?;
            let name = std::str::from_utf8(name).map_err(|_| bad())?;
            let id = facts.registries.id("minecraft:worldgen/biome", name);
            Some(id.ok_or_else(bad)? as u16)
        }
        None => None,
    };
    let environment = OneBiome(biome);
    let difficulty = difficulty(get(m, "difficulty")?)?;
    let mut level = Level::new(
        &blocks,
        &environment,
        facts,
        physics,
        states,
        random(int(get(m, "random")?)?)?,
    );
    level.difficulty = difficulty;
    level.halloween = field(m, "halloween").and_then(Value::as_bool) == Some(true);
    level.loot = Some(&loot.loot);
    if let Some(local) = field(m, "local") {
        let [time, inhabited, moon] = local.as_tuple_n::<3>().ok_or_else(bad)?;
        let moon = moon.as_number().ok_or_else(bad)?;
        let local = LocalDifficulty::new(difficulty, int(time)?, int(inhabited)?, moon);
        level.local = Some(local.effective);
    }
    let mut sensed = Vec::new();
    for e in get(m, "mobs")?.as_list().ok_or_else(bad)? {
        let [id, record] = e.as_tuple_n::<2>().ok_or_else(bad)?;
        let other = ms::restore(record)?.map_err(|_| bad())?;
        sensed.push(think::sensed(&ctx, int(id)? as i32, &other).ok_or_else(bad)?);
    }
    let reason = mob.body.mob.finalize.take().ok_or_else(bad)?;
    let effects = think::on_turn(&ctx, &mut mob, &mut level, |t, kind| {
        *t.sensing = Sensing::new(Vec::new(), Vec::new(), sensed);
        kind.finalize(t, &reason);
        std::mem::take(&mut t.effects)
    })
    .ok_or_else(bad)?;
    let mounts = ["minecraft:chicken", "minecraft:zombie_nautilus"].map(|n| facts.entities.id(n));
    let mut jockey = None;
    let mut spawned = Vec::new();
    for e in &effects {
        match e {
            Effect::Jockey(_) => jockey = jockey.or(Some("existing")),
            Effect::Spawn { type_id, options } => {
                spawned.push(facts.entities.name(*type_id).unwrap_or_default());
                let rides = options
                    .as_map()
                    .and_then(|o| o.get_atom("jockey"))
                    .and_then(Value::as_bool)
                    == Some(true);
                if rides && mounts.contains(&Some(*type_id)) {
                    jockey = jockey.or(Some("new"));
                }
            }
            _ => {}
        }
    }
    let ty = Type::of(facts, &mob.body.entity_type).ok_or_else(bad)?;
    let young = ctx
        .kinds
        .kind(ty.id)
        .and_then(|k| k.young(&mob.body))
        .unwrap_or_else(|| mob.body.data.baby().unwrap_or(false));
    let hunted = mob
        .body
        .mob
        .ai
        .as_ref()
        .and_then(|m| m.state.as_ref())
        .and_then(|s| s.brain.as_deref())
        .and_then(|b| {
            b.memories
                .0
                .iter()
                .find(|(k, _)| k.name() == "hunted_recently")
                .and_then(|(_, (_, ttl))| *ttl)
        });
    let level_random = level.random.seed;
    let record = mob_term::encode(env, &valimc_core::mobs::record::record(&mob))?;
    let death = mob_term::decode(death)?;
    let died = match death.as_tuple_n::<2>() {
        None => None,
        Some([hit, by_player]) => {
            let hit = ms::hit_of(&rules, hit)?;
            mob.body.mob.player_memory = if by_player.as_bool() == Some(true) {
                100
            } else {
                0
            };
            let uuid = mob.uuid;
            let drops: Vec<(&str, i64)> =
                combat::equipment_drops(&rules, &mut mob.body, &uuid, Some(&hit))
                    .iter()
                    .map(|s| {
                        let name = items::item_id(s).and_then(|id| facts.items.name(id));
                        let damage =
                            items::component(s, "minecraft:damage").and_then(Value::as_int);
                        (name.unwrap_or_default(), damage.unwrap_or(0))
                    })
                    .collect();
            let after = mob.body.mob.ai.as_ref().map(|m| m.random.seed);
            Some((drops, after))
        }
    };
    Ok((record, young, hunted, jockey, spawned, level_random, died).encode(env))
}

/// Nothing to read.
struct NoBlocks;

impl BlockSource for NoBlocks {
    fn state(&self, _x: i32, _y: i32, _z: i32) -> Option<u16> {
        None
    }
}

/// `Animal.breed/2` of mob `parent` with `partner` (sensed beside it) over
/// the level random's state `random`, in the plains: `{parent record,
/// partner record (`bred`), child data, orb, parent random, level random}`.
#[rustler::nif]
fn mob_oracle_ai_breed<'a>(
    env: Env<'a>,
    parent: Term<'a>,
    partner: Term<'a>,
    random_state: i64,
) -> NifResult<Term<'a>> {
    let rules = ms::rules()?;
    let ctx = ms::ctx(&rules)?;
    let physics = crate::facts::PHYSICS.get().ok_or_else(bad)?;
    let states = crate::facts::STATES.get().ok_or_else(bad)?;
    let mut mob = made(&ctx, parent)?;
    let mut partner = made(&ctx, partner)?;
    let sensed = think::sensed(&ctx, 2, &partner).ok_or_else(bad)?;
    let partner_ref = Ref {
        kind: RefKind::Mob,
        uuid: partner.uuid,
    };
    let mut level = Level::new(
        &NoBlocks,
        &Unknown,
        rules.facts,
        physics,
        states,
        random(random_state)?,
    );
    let effects = think::on_turn(&ctx, &mut mob, &mut level, |t, kind| {
        *t.sensing = Sensing::new(Vec::new(), Vec::new(), vec![sensed]);
        if let Some(seen) = t.sensing.entity(&partner_ref).map(Seen::of) {
            kind.breed(t, None, &seen);
        }
        std::mem::take(&mut t.effects)
    })
    .ok_or_else(bad)?;
    valimc_core::mobs::animals::bred(&mut partner.body.data);
    let child = effects.iter().find_map(|e| match e {
        Effect::Offspring { data, .. } => Some(data.clone()),
        _ => None,
    });
    let orb = effects.iter().find_map(|e| match e {
        Effect::Orb { value, .. } => Some(*value),
        _ => None,
    });
    let after = mob.body.mob.ai.as_ref().map(|m| m.random.seed);
    Ok((
        mob_term::encode(env, &valimc_core::mobs::record::record(&mob))?,
        mob_term::encode(env, &valimc_core::mobs::record::record(&partner))?,
        mob_term::encode(env, &child.ok_or_else(bad)?)?,
        orb,
        after,
        level.random.seed,
    )
        .encode(env))
}

/// `mob_finalize/2` of mobs made before their spawn finishes, each keeping
/// its record's random (an aquatic pack's members as the oracle made them).
#[rustler::nif]
fn mob_oracle_ai_finalize<'a>(
    env: Env<'a>,
    entries: Vec<(usize, Option<i64>, Option<bool>, Term<'a>)>,
    randoms: Vec<u64>,
) -> NifResult<Term<'a>> {
    ms::finalize(env, entries, randoms, true)
}
