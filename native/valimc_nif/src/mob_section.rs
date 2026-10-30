//! A section's native mobs (VMC-081d, `valimc_core::mobs::section`) for
//! Elixir: the `MobSection` resource its group process owns (as the Region
//! resource: only the owner changes it, `mob_section_give` hands it on with
//! the section), its records and rows, its tick over the physics ticker with
//! the Elixir yield, and the outside actions on its mobs.
//!
//! Records are `Store.record/1`'s terms. A mob's row is the
//! `%Valimc.Entity.NativeBody{}` the store keeps for it (what routing,
//! sensing and publication read), its `shown` nil where observers were last
//! shown the same. Events are the terms `Body.event_packet/3` takes (sound
//! seeds drawn here, as the Elixir's `:crypto` ones), effects the Elixir
//! effect tuples.
//!
//! The tick: `mob_section_begin` makes the ticker over every mob of the
//! section in id order (native ones from here, Elixir ones from their kernel
//! maps), `mob_section_run` runs turns from an index until an Elixir mob's
//! (`{:yield, index, ...}`: its owner ticks it with `MobTicks` over the same
//! ticker, then runs again after it) or the end, and `mob_section_finish`
//! ends the ticker and answers the native mobs' steps.

use crate::mob_term;
use crate::physics::{self as physics_nif, BoxT, MobT, MobTicker, TickerState, Vec3};
use crate::region::Region;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::cell::Cell;
use std::sync::{Mutex, OnceLock};
use valimc_core::mobs::combat::{self, AiMind, Attacker, Event, Hit, NoFamilies, Rules, SoundRef};
use valimc_core::mobs::living::mob::{self as living_mob, Type};
use valimc_core::mobs::living::{body as living_body, effects, health};
use valimc_core::mobs::model::{NativeMob, Rung, Slot as EquipSlot};
use valimc_core::mobs::random::LegacyRandom;
use valimc_core::mobs::record::{self, RecordError, RecordFacts};
use valimc_core::mobs::section::{chunk_of, MobSection, Slot, Written};
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::tick::{
    self, Effect, Entrant, NoMotionHooks, NoThought, Ran, Tick, TurnWorld,
};
use valimc_core::mobs::vitals::Sky;
use valimc_core::physics::player::World;

mod atoms {
    rustler::atoms! {
        ok, error, not_owner, poisoned, invalid, unsupported, duplicate, outside, missing,
        busy, native, elixir, fixed, r#yield = "yield", done, dying, ignored,
        add, heal, ignite, hurt, all, record_facts_missing, no_tick,
    }
}

const NATIVE_BODY: &str = "Elixir.Valimc.Entity.NativeBody";

// ------------------------------------------------------------------ facts

static RECORD_FACTS: OnceLock<RecordFacts> = OnceLock::new();

/// Install the record codec's facts once per VM (`Valimc.Entity.NativeMobs`
/// passes `mob_record_facts/1`'s map); a second install keeps the first.
#[rustler::nif]
fn mob_section_install(facts: Term) -> NifResult<(Atom, bool)> {
    if RECORD_FACTS.get().is_some() {
        return Ok((atoms::ok(), false));
    }
    let facts = mob_term::decode(facts)?;
    let parsed = crate::mobs::parse_facts(&facts).ok_or(rustler::Error::BadArg)?;
    Ok((atoms::ok(), RECORD_FACTS.set(parsed).is_ok()))
}

fn record_facts() -> NifResult<&'static RecordFacts> {
    RECORD_FACTS.get().ok_or(rustler::Error::Term(
        Box::new(atoms::record_facts_missing()),
    ))
}

fn rules() -> NifResult<Rules<'static>> {
    Ok(Rules {
        facts: crate::mob_facts::facts()?,
        living: crate::mob_living::facts()?,
        families: &NoFamilies,
        mind: &AiMind,
    })
}

fn fail(reason: Atom) -> rustler::Error {
    rustler::Error::Term(Box::new(reason))
}

// --------------------------------------------------------------- resource

/// A section's native mobs, owned by one process.
pub struct MobSectionRes {
    owner: Mutex<LocalPid>,
    inner: Mutex<Inner>,
}

struct Inner {
    section: MobSection,
    running: Option<Running>,
}

/// A tick in progress: its turns, the light it reads and its sky.
struct Running {
    tick: Tick,
    region: Option<ResourceArc<Region>>,
    env: TickEnv,
}

#[derive(Clone, Copy)]
struct TickEnv {
    monsters_burn: bool,
    darken: i32,
    wet: bool,
    sea_level: i32,
    zoom_seed: i64,
    mob_griefing: bool,
}

#[rustler::resource_impl]
impl rustler::Resource for MobSectionRes {}

/// Whole mobs on their way to a sibling section of the same group.
pub struct MobParcel(Mutex<Vec<(i32, Box<Slot>)>>);

#[rustler::resource_impl]
impl rustler::Resource for MobParcel {}

fn read(res: &MobSectionRes) -> NifResult<std::sync::MutexGuard<'_, Inner>> {
    res.inner.lock().map_err(|_| fail(atoms::poisoned()))
}

fn owned<'a>(env: Env, res: &'a MobSectionRes) -> NifResult<std::sync::MutexGuard<'a, Inner>> {
    if env.pid() != *res.owner.lock().map_err(|_| fail(atoms::poisoned()))? {
        return Err(fail(atoms::not_owner()));
    }
    read(res)
}

/// A new section `{sx, sz}` owned by the caller.
#[rustler::nif]
fn mob_section_new(env: Env, sx: i32, sz: i32) -> ResourceArc<MobSectionRes> {
    ResourceArc::new(MobSectionRes {
        owner: Mutex::new(env.pid()),
        inner: Mutex::new(Inner {
            section: MobSection::new((sx, sz)),
            running: None,
        }),
    })
}

/// Hand the section to `to` with its Region (`region_give`).
#[rustler::nif]
fn mob_section_give(env: Env, res: ResourceArc<MobSectionRes>, to: LocalPid) -> NifResult<Atom> {
    let mut owner = res.owner.lock().map_err(|_| fail(atoms::poisoned()))?;
    if env.pid() != *owner {
        return Err(fail(atoms::not_owner()));
    }
    *owner = to;
    Ok(atoms::ok())
}

/// The section's mob count and revision.
#[rustler::nif]
fn mob_section_info(res: ResourceArc<MobSectionRes>) -> NifResult<(usize, u64)> {
    let inner = read(&res)?;
    Ok((inner.section.len(), inner.section.revision))
}

// ---------------------------------------------------------------- records

fn restore(value: &Value) -> NifResult<Result<NativeMob, Atom>> {
    Ok(match record::restore(value, record_facts()?) {
        Ok(mob) => Ok(mob),
        Err(RecordError::Invalid(_)) => Err(atoms::invalid()),
        Err(RecordError::Unsupported(_)) => Err(atoms::unsupported()),
    })
}

/// Adds the mobs of `entries` (`[{id, record}]`), all or none:
/// `{:ok, [{id, position, row}]}` or `{:error, {id, reason}}`. `written`:
/// a load's records, which its frames already hold.
#[rustler::nif]
fn mob_section_insert<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    entries: Vec<(i32, Term<'a>)>,
    written: bool,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut mobs = Vec::with_capacity(entries.len());
    for (id, term) in entries {
        let value = mob_term::decode(term)?;
        match restore(&value)? {
            Ok(mob) => {
                let w = written.then(|| Written::of(&record::record(&mob)));
                mobs.push((id, mob, w))
            }
            Err(reason) => return Ok((atoms::error(), (id, reason)).encode(env)),
        }
    }
    let mut inner = owned(env, &res)?;
    let section = &mut inner.section;
    for (id, mob, _) in &mobs {
        let reason = if section.contains(*id)
            || mobs.iter().filter(|m| m.0 == *id).count() > 1
            || section.id_of(&mob.uuid).is_some()
        {
            Some(atoms::duplicate())
        } else if !section.holds(mob.position) {
            Some(atoms::outside())
        } else {
            None
        };
        if let Some(reason) = reason {
            return Ok((atoms::error(), (*id, reason)).encode(env));
        }
    }
    let mut rows = Vec::with_capacity(mobs.len());
    for (id, mob, written) in mobs {
        section
            .insert(id, mob, written)
            .map_err(|_| fail(atoms::invalid()))?;
        rows.push(placed(env, &rules, section, id, true)?);
    }
    Ok((atoms::ok(), rows).encode(env))
}

/// The row of `record` (no section changes): `{:ok, {position, row,
/// record}}` (the record as the mob writes it) or `{:error, reason}`, for a
/// plan's worker that adopts a record.
#[rustler::nif]
fn mob_section_row<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let value = mob_term::decode(term)?;
    match restore(&value)? {
        Ok(mob) => {
            let mut slot = Slot::new(mob, None);
            let row = row(&rules, &mut slot, true);
            let p = slot.mob.position;
            let normal = record::record(&slot.mob);
            Ok((
                atoms::ok(),
                (
                    (p[0], p[1], p[2]),
                    mob_term::encode(env, &row)?,
                    mob_term::encode(env, &normal)?,
                ),
            )
                .encode(env))
        }
        Err(reason) => Ok((atoms::error(), reason).encode(env)),
    }
}

/// The records of mobs `ids` as they are now (`:all`: every mob's, one
/// whose move out is pending where it was), by any process (a plan's worker
/// withdrawing them): `[record]` in the order asked, a missing one left
/// out.
#[rustler::nif]
fn mob_section_records<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ids: Term<'a>,
) -> NifResult<Term<'a>> {
    let inner = read(&res)?;
    let section = &inner.section;
    let values: Vec<Value> = if ids.decode::<Atom>().ok() == Some(atoms::all()) {
        section.records()
    } else {
        ids.decode::<Vec<i32>>()?
            .into_iter()
            .filter_map(|id| section.get(id))
            .map(|s| record::record(&s.mob))
            .collect()
    };
    let terms = values
        .iter()
        .map(|v| mob_term::encode(env, v))
        .collect::<NifResult<Vec<_>>>()?;
    Ok(terms.encode(env))
}

/// Takes mobs `ids` out: `{:ok, [record]}` (their records as they leave).
#[rustler::nif]
fn mob_section_withdraw<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ids: Vec<i32>,
) -> NifResult<Term<'a>> {
    let mut inner = owned(env, &res)?;
    let mut out = Vec::new();
    for id in ids {
        if let Some(slot) = inner.section.remove(id) {
            out.push(mob_term::encode(env, &record::record(&slot.mob))?);
        }
    }
    Ok((atoms::ok(), out).encode(env))
}

/// Takes mobs `ids` out whole, for a sibling section of the group
/// (`mob_section_put/2`): `{:ok, parcel}`.
#[rustler::nif]
fn mob_section_take(
    env: Env,
    res: ResourceArc<MobSectionRes>,
    ids: Vec<i32>,
) -> NifResult<(Atom, ResourceArc<MobParcel>)> {
    let mut inner = owned(env, &res)?;
    let mut out = Vec::new();
    for id in ids {
        if let Some(mut slot) = inner.section.remove(id) {
            slot.before = None;
            slot.written = None;
            out.push((id, Box::new(slot)));
        }
    }
    Ok((atoms::ok(), ResourceArc::new(MobParcel(Mutex::new(out)))))
}

/// Puts a parcel's mob in as mob `id` (the id its store gave it): `{:ok,
/// {id, position, row}}`, or `{:error, reason}` with the parcel kept.
#[rustler::nif]
fn mob_section_put<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    parcel: ResourceArc<MobParcel>,
    id: i32,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut inner = owned(env, &res)?;
    let mut mobs = parcel.0.lock().map_err(|_| fail(atoms::poisoned()))?;
    let Some((_, slot)) = mobs.pop() else {
        return Ok((atoms::error(), atoms::missing()).encode(env));
    };
    let shown = slot.shown.clone();
    match inner.section.insert(id, slot.mob.clone(), None) {
        Ok(()) => {
            if let Some(s) = inner.section.peek_mut(id) {
                s.shown = shown;
            }
            let placed = placed(env, &rules, &mut inner.section, id, true)?;
            Ok((atoms::ok(), placed).encode(env))
        }
        Err(e) => {
            mobs.push((id, slot));
            let reason = match e {
                valimc_core::mobs::section::InsertError::Outside => atoms::outside(),
                _ => atoms::duplicate(),
            };
            Ok((atoms::error(), reason).encode(env))
        }
    }
}

/// Removes mobs `ids` (despawned, discarded, done dying).
#[rustler::nif]
fn mob_section_remove(env: Env, res: ResourceArc<MobSectionRes>, ids: Vec<i32>) -> NifResult<Atom> {
    let mut inner = owned(env, &res)?;
    for id in ids {
        inner.section.remove(id);
    }
    Ok(atoms::ok())
}

/// The records a frame writes now: `{[{uuid, record | nil}], waiting}`.
#[rustler::nif]
fn mob_section_cut<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    full: bool,
) -> NifResult<Term<'a>> {
    let mut inner = owned(env, &res)?;
    let cut = inner.section.cut(full);
    let records = cut
        .records
        .iter()
        .map(|(uuid, value)| {
            Ok((
                crate::binary(env, uuid),
                match value {
                    Some(v) => mob_term::encode(env, v)?,
                    None => rustler::types::atom::nil().encode(env),
                },
            ))
        })
        .collect::<NifResult<Vec<_>>>()?;
    Ok((records, cut.waiting).encode(env))
}

/// Every record taken as written (a checkpoint or a load holds them).
#[rustler::nif]
fn mob_section_baseline(env: Env, res: ResourceArc<MobSectionRes>) -> NifResult<Atom> {
    owned(env, &res)?.section.baseline();
    Ok(atoms::ok())
}

/// The mobs in `chunks`, in id order.
#[rustler::nif]
fn mob_section_in_chunks(
    res: ResourceArc<MobSectionRes>,
    chunks: Vec<(i32, i32)>,
) -> NifResult<Vec<i32>> {
    Ok(read(&res)?.section.in_chunks(chunks))
}

// -------------------------------------------------------------------- rows

thread_local! {
    static SEEDS: Cell<u64> = Cell::new({
        use std::hash::{BuildHasher, Hasher};
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(0x5EED);
        h.finish() | 1
    });
}

/// A sound's seed (the client's), as the Elixir's `:crypto` draw.
fn seed() -> i64 {
    SEEDS.with(|s| {
        let mut x = s.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.set(x);
        x as i64
    })
}

fn damage_name(rules: &Rules, id: u16) -> Value {
    let name = &rules.facts.damage_types.types[id as usize].name;
    Value::Atom(valimc_core::mobs::term::Atom::new(
        name.strip_prefix("minecraft:").unwrap_or(name),
    ))
}

/// An event as `Body.event_packet/3` takes it.
fn event(rules: &Rules, e: &Event) -> Value {
    let int = |i: Option<i32>| i.map_or(NIL, |i| Value::Int(i as i64));
    match e {
        Event::Entity(n) => Value::tuple([Value::atom("event"), Value::Int(*n as i64)]),
        Event::Damage {
            source,
            cause,
            direct,
        } => Value::Tuple(vec![
            Value::atom("damage"),
            damage_name(rules, *source),
            int(*cause),
            int(*direct),
            NIL,
        ]),
        Event::Killed => Value::tuple([Value::atom("damage"), Value::atom("generic_kill")]),
        Event::Sound {
            sound,
            source,
            volume,
            pitch,
        } => Value::Tuple(vec![
            Value::atom("sound"),
            match sound {
                SoundRef::Name(n) => Value::Binary(n.as_bytes().to_vec()),
                SoundRef::Id(i) => Value::Int(*i as i64),
            },
            Value::Int(*source as i64),
            Value::Float(*volume),
            Value::Float(*pitch),
            Value::Int(seed()),
        ]),
        Event::Other(v) => v.clone(),
    }
}

fn events_value(rules: &Rules, events: &[Event]) -> Value {
    Value::List(events.iter().map(|e| event(rules, e)).collect())
}

fn effect(e: &Effect) -> Value {
    let cell = |c: &[i32; 3]| Value::ivec3([c[0].into(), c[1].into(), c[2].into()]);
    match e {
        Effect::Trample(c) => Value::tuple([Value::atom("trample"), cell(c)]),
        Effect::CrackEgg(c, s) => {
            Value::tuple([Value::atom("crack_egg"), cell(c), Value::Int(*s as i64)])
        }
    }
}

fn uuid_value(u: &[u8; 16]) -> Value {
    Value::Binary(u.to_vec())
}

fn reference(r: &valimc_core::mobs::sensing::Ref) -> Value {
    use valimc_core::mobs::sensing::Kind;
    let kind = match r.kind {
        Kind::Player => "player",
        Kind::Mob => "mob",
        Kind::Item => "item",
    };
    Value::tuple([Value::atom(kind), Value::Binary(r.uuid.to_vec())])
}

/// `Body.shown/1` as a term: `{values, synced, equipment, link}`.
fn shown_value(rules: &Rules, ty: Type, shown: &living_body::Shown) -> Value {
    let values = shown
        .values
        .iter()
        .map(|(k, v, d)| Value::Tuple(vec![Value::Atom(k.clone()), v.clone(), d.clone()]))
        .collect();
    let synced = living_mob::synced(rules.living, rules.facts, ty, &shown.attributes)
        .into_iter()
        .map(|s| {
            Value::tuple([
                Value::Int(s.id as i64),
                Value::Float(s.base),
                Value::List(
                    s.modifiers
                        .iter()
                        .map(|m| {
                            Value::tuple([
                                Value::Binary(m.id.as_bytes().to_vec()),
                                match m.amount {
                                    valimc_core::mobs::model::Number::Int(i) => Value::Int(i),
                                    valimc_core::mobs::model::Number::Float(f) => Value::Float(f),
                                },
                                Value::Int(m.operation as i64),
                            ])
                        })
                        .collect(),
                ),
            ])
        })
        .collect();
    let equipment = EquipSlot::ALL
        .into_iter()
        .filter_map(|s| Some((Value::atom(s.name()), shown.equipment.get(s)?.clone())))
        .collect();
    Value::tuple([
        Value::List(values),
        Value::List(synced),
        Value::Map(Map::from_pairs(equipment).unwrap_or_default()),
        shown.link.map_or(NIL, |l| Value::Int(l as i64)),
    ])
}

fn attribute(rules: &Rules, ty: Type, mob: &NativeMob, name: &str) -> f64 {
    rules.facts.attributes.id(name).map_or(0.0, |id| {
        living_mob::value(rules.living, rules.facts, ty, &mob.body.mob, id)
    })
}

/// A mob's row (`%NativeBody{}`); `shown` nil where observers saw the same
/// (unless `fresh`: a new entry's).
fn row(rules: &Rules, slot: &mut Slot, fresh: bool) -> Value {
    let mob = &slot.mob;
    let body = &mob.body;
    let m = &body.mob;
    let Some(ty) = rules.of(&body.entity_type) else {
        return NIL;
    };
    let shown = living_body::shown(rules, ty, body);
    let shown_value = if !fresh && slot.shown.as_ref() == Some(&shown) {
        NIL
    } else {
        let v = shown_value(rules, ty, &shown);
        slot.shown = Some(shown);
        v
    };
    let [w, h, eye] = living_body::dimensions(rules, ty, body);
    let mind = m.ai.as_ref();
    let state = mind.and_then(|mind| mind.state.as_ref());
    let recent = match (mind, state) {
        (None, _) => false,
        (Some(_), None) => true,
        (Some(_), Some(s)) => match s.hurt_by {
            Some((_, at)) => at >= s.tick - 2,
            None => s.tick <= 2,
        },
    };
    let data = Map::from_pairs(
        body.data
            .fields()
            .iter()
            .map(|(k, v)| (Value::Atom(k.clone()), v.clone()))
            .collect(),
    )
    .unwrap_or_default();
    let mut map = Map::with_capacity(28);
    map.insert_atom("__struct__", Value::atom(NATIVE_BODY));
    map.insert_atom("type", Value::Binary(body.entity_type.as_bytes().to_vec()));
    map.insert_atom("yaw", Value::Float(body.yaw));
    map.insert_atom("pitch", Value::Float(body.pitch));
    map.insert_atom("head_yaw", Value::Float(body.head_yaw));
    map.insert_atom("velocity", Value::vec3(body.velocity));
    map.insert_atom("on_ground", Value::bool(body.on_ground));
    map.insert_atom("no_gravity", Value::bool(body.no_gravity));
    map.insert_atom("alive", Value::bool(living_mob::alive(m)));
    map.insert_atom("dimensions", Value::vec3([w, h, eye]));
    map.insert_atom("custom_name", body.custom_name.clone().unwrap_or(NIL));
    map.insert_atom("portal_cooldown", Value::Int(body.portal_cooldown as i64));
    map.insert_atom("persistent", Value::bool(m.persistent));
    map.insert_atom(
        "from_bucket",
        Value::bool(body.data.get("from_bucket").and_then(Value::as_bool) == Some(true)),
    );
    map.insert_atom("shown", shown_value);
    map.insert_atom("in_water", Value::bool(m.motion.water > 0.0));
    map.insert_atom(
        "killed_by",
        m.hurt_by_player.map_or(NIL, |u| {
            Value::tuple([Value::atom("player"), uuid_value(&u)])
        }),
    );
    map.insert_atom("recent", Value::bool(recent));
    map.insert_atom("data", Value::Map(data));
    map.insert_atom(
        "target",
        state.and_then(|s| s.target.as_ref()).map_or(NIL, reference),
    );
    map.insert_atom(
        "knockback_resistance",
        Value::Float(attribute(rules, ty, mob, "minecraft:knockback_resistance")),
    );
    map.insert_atom(
        "step_height",
        Value::Float(attribute(rules, ty, mob, "minecraft:step_height")),
    );
    map.insert_atom(
        "gravity",
        Value::Float(attribute(rules, ty, mob, "minecraft:gravity")),
    );
    map.insert_atom(
        "explosion_resistance",
        Value::Float(
            rules
                .facts
                .attributes
                .id("minecraft:explosion_knockback_resistance")
                .map_or(0.0, |id| {
                    living_mob::base(rules.living, rules.facts, ty, &m.attributes, id)
                }),
        ),
    );
    map.insert_atom("death", Value::bool(m.death.is_some()));
    map.insert_atom("no_ai", Value::bool(m.no_ai));
    map.insert_atom("idle", state.map_or(NIL, |s| Value::Int(s.no_action)));
    Value::Map(map)
}

/// `{id, position, row}` of mob `id`.
fn placed<'a>(
    env: Env<'a>,
    rules: &Rules,
    section: &mut MobSection,
    id: i32,
    fresh: bool,
) -> NifResult<Term<'a>> {
    let slot = section.peek_mut(id).ok_or_else(|| fail(atoms::missing()))?;
    let p = slot.mob.position;
    let row = row(rules, slot, fresh);
    Ok((id, (p[0], p[1], p[2]), mob_term::encode(env, &row)?).encode(env))
}

// --------------------------------------------------------------------- tick

fn entrant(term: Term) -> NifResult<(Entrant, Option<MobT>)> {
    let t = get_tuple(term)?;
    let tag: Atom = t.first().ok_or(rustler::Error::BadArg)?.decode()?;
    let arg = *t.get(1).ok_or(rustler::Error::BadArg)?;
    if tag == atoms::native() {
        Ok((Entrant::Native(arg.decode()?), None))
    } else if tag == atoms::elixir() {
        Ok((Entrant::Elixir, Some(arg.decode()?)))
    } else if tag == atoms::fixed() {
        Ok((Entrant::Fixed, Some(arg.decode()?)))
    } else {
        Err(rustler::Error::BadArg)
    }
}

#[derive(rustler::NifMap)]
struct EnvT {
    monsters_burn: bool,
    darken: i32,
    wet: bool,
    sea_level: i32,
    zoom_seed: i64,
    mob_griefing: bool,
    region: Option<ResourceArc<Region>>,
}

/// Begins the section's tick: `order` is every mob in id order, `{:native,
/// id}`, `{:elixir, kernel_map}` or another section's `{:fixed,
/// kernel_map}`; the ticker reads `view` and is pushed by `players`.
/// `{:ok, ticker}`.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn mob_section_begin<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    view: Term<'a>,
    order: Vec<Term<'a>>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
    colliders: Vec<(usize, Option<BoxT>)>,
    tick_env: EnvT,
) -> NifResult<(Atom, ResourceArc<MobTicker>)> {
    begin(env, res, view, order, players, border, colliders, tick_env)
}

/// `mob_section_begin/7` for ticks past the normal scheduler's budget (a
/// supplied view to decode, many mobs).
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn mob_section_begin_dirty<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    view: Term<'a>,
    order: Vec<Term<'a>>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
    colliders: Vec<(usize, Option<BoxT>)>,
    tick_env: EnvT,
) -> NifResult<(Atom, ResourceArc<MobTicker>)> {
    begin(env, res, view, order, players, border, colliders, tick_env)
}

#[allow(clippy::too_many_arguments)]
fn begin<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    view: Term<'a>,
    order: Vec<Term<'a>>,
    players: Vec<(Vec3, BoxT)>,
    border: Option<(f64, f64, f64, f64)>,
    colliders: Vec<(usize, Option<BoxT>)>,
    tick_env: EnvT,
) -> NifResult<(Atom, ResourceArc<MobTicker>)> {
    let rules = rules()?;
    let mut inner = owned(env, &res)?;
    let mut entrants = Vec::with_capacity(order.len());
    let mut bodies = Vec::with_capacity(order.len());
    for term in order {
        let (e, input) = entrant(term)?;
        match (e, input) {
            (Entrant::Native(id), _) => {
                let slot = inner
                    .section
                    .get(id)
                    .ok_or_else(|| fail(atoms::missing()))?;
                let ty = rules
                    .of(&slot.mob.body.entity_type)
                    .ok_or_else(|| fail(atoms::invalid()))?;
                let attributes = tick::travel_attributes(&rules, ty, &slot.mob);
                bodies.push(tick::kernel_input(
                    &rules,
                    &NoMotionHooks,
                    ty,
                    &slot.mob,
                    attributes,
                ));
            }
            (_, Some(input)) => bodies.push(physics_nif::mob(&input)?),
            _ => return Err(rustler::Error::BadArg),
        }
        entrants.push(e);
    }
    let ticker = physics_nif::ticker_of(view, bodies, players, border, colliders)?;
    let tick = Tick::begin(&mut inner.section, entrants);
    inner.running = Some(Running {
        tick,
        region: tick_env.region,
        env: TickEnv {
            monsters_burn: tick_env.monsters_burn,
            darken: tick_env.darken,
            wet: tick_env.wet,
            sea_level: tick_env.sea_level,
            zoom_seed: tick_env.zoom_seed,
            mob_griefing: tick_env.mob_griefing,
        },
    });
    Ok((atoms::ok(), ticker))
}

/// The sky a tick's turns read: the section's light, rain over the
/// ticker's snapshots, the sun and the level random.
struct TickSky<'a> {
    env: TickEnv,
    /// The section's Region: its store is locked for each light read only,
    /// as its light updates and encodings hold it elsewhere.
    region: Option<&'a Region>,
    view: &'a physics_nif::View<physics_nif::SnapshotArc>,
    climates: &'a [valimc_core::mobs::facts::Climate],
    plains: u16,
    random: LegacyRandom,
}

impl TickSky<'_> {
    fn light_at(&self, p: [i32; 3]) -> Option<(u8, u8)> {
        let region = self.region?;
        let store = region.store.lock().ok()?;
        store.light_at(p[0], p[1], p[2])
    }
}

impl Sky for TickSky<'_> {
    fn monsters_burn(&self) -> bool {
        self.env.monsters_burn
    }

    fn light(&self, p: [i32; 3]) -> f64 {
        match self.light_at(p) {
            None => 0.0,
            Some((sky, block)) => {
                let level = (sky as i32 - self.env.darken).max(block as i32);
                let v = (level as f64 / 15.0) as f32;
                (v / (4.0 - 3.0 * v)) as f64
            }
        }
    }

    fn sees_sky(&self, p: [i32; 3]) -> bool {
        matches!(self.light_at(p), Some((15, _)))
    }

    fn rain(&self, position: [f64; 3], top: f64) -> bool {
        let physics_nif::View::Rows(rows) = self.view else {
            return false;
        };
        let (Some(flags), Some(light)) = (crate::facts::FLAGS.get(), crate::facts::LIGHT.get())
        else {
            return false;
        };
        let column = |x: i32, z: i32| {
            rows.snapshot((x >> 4, z >> 4))
                .map(|s| s.column(x, z, flags, light))
        };
        let biome = |p: [i32; 3]| {
            let (qx, qy, qz) =
                valimc_core::worldgen::surface::zoom(self.env.zoom_seed, p[0], p[1], p[2]);
            let s = rows.snapshot((qx >> 2, qz >> 2))?;
            Some(s.biome((qx, qy, qz)).unwrap_or(self.plains))
        };
        valimc_core::mobs::level::rain_at(
            self.climates,
            self.env.wet,
            self.env.sea_level,
            position,
            top,
            column,
            biome,
        ) == Some(true)
    }

    fn random(&mut self) -> &mut LegacyRandom {
        &mut self.random
    }
}

/// A sensed refresh for the Elixir AI: `{id, {x, y, z}, yaw, pitch, alive}`.
fn moved_rows(section: &MobSection, ids: &[i32]) -> Vec<(i32, Vec3, f64, f64, bool)> {
    ids.iter()
        .filter_map(|&id| {
            let s = section.get(id)?;
            let p = s.mob.position;
            Some((
                id,
                (p[0], p[1], p[2]),
                s.mob.body.yaw,
                s.mob.body.pitch,
                living_mob::alive(&s.mob.body.mob),
            ))
        })
        .collect()
}

type Pushed = Vec<(usize, Vec3)>;

/// Where a run stopped, the level random after it, the native mobs that
/// moved and the Elixir mobs they pushed.
type Run = (Ran, i64, Vec<(i32, Vec3, f64, f64, bool)>, Pushed);

fn run(
    env: Env,
    res: &MobSectionRes,
    ticker: &MobTicker,
    from: usize,
    random: i64,
) -> NifResult<Run> {
    let rules = rules()?;
    let physics = physics_nif::facts()?;
    let mut inner = owned(env, res)?;
    let Inner { section, running } = &mut *inner;
    let running = running.as_mut().ok_or_else(|| fail(atoms::no_tick()))?;
    let mut guard = ticker.state()?;
    let TickerState {
        view,
        border,
        players,
        ticker,
    } = guard.as_mut().ok_or_else(|| fail(atoms::no_tick()))?;
    let view: &physics_nif::View<physics_nif::SnapshotArc> = view;
    let world = World {
        source: view,
        facts: physics,
        border: crate::player::border(*border),
        entities: &[],
    };
    let tw = TurnWorld {
        rules: &rules,
        motion: &NoMotionHooks,
        thinker: &NoThought,
        world: &world,
        players: &players[..],
        mob_griefing: running.env.mob_griefing,
        travel: Default::default(),
    };
    let plains = rules
        .facts
        .registries
        .id("minecraft:worldgen/biome", "minecraft:plains")
        .unwrap_or(0) as u16;
    let mut sky = TickSky {
        env: running.env,
        region: running.region.as_deref(),
        view,
        climates: &rules.facts.climates,
        plains,
        random: LegacyRandom::from_state(random as u64).ok_or(rustler::Error::BadArg)?,
    };
    let ran = running.tick.run(section, &tw, &mut sky, ticker, from);
    let moved = std::mem::take(&mut running.tick.moved);
    let pushed = std::mem::take(&mut running.tick.pushed)
        .into_iter()
        .map(|(i, v)| (i, (v[0], v[1], v[2])))
        .collect();
    let rows = moved_rows(section, &moved);
    Ok((ran, sky.random.seed as i64, rows, pushed))
}

fn ran_term<'a>(env: Env<'a>, (ran, random, moved, pushed): Run) -> Term<'a> {
    match ran {
        Ran::Yield(i) => (atoms::r#yield(), i, random, moved, pushed).encode(env),
        Ran::Done => (atoms::done(), random, moved, pushed).encode(env),
    }
}

/// Runs turns from index `from` with the level random `random` (its
/// state): `{:yield, index, random, moved, pushed}` at an Elixir mob's
/// index, `{:done, random, moved, pushed}` at the end; `moved` refreshes the
/// Elixir AI's sensing of the native mobs that moved, `pushed` the Elixir
/// mobs' velocities their steps pushed.
#[rustler::nif]
fn mob_section_run<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
    from: usize,
    random: i64,
) -> NifResult<Term<'a>> {
    Ok(ran_term(env, run(env, &res, &ticker, from, random)?))
}

/// `mob_section_run/4` for runs past the normal scheduler's budget.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_section_run_dirty<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
    from: usize,
    random: i64,
) -> NifResult<Term<'a>> {
    Ok(ran_term(env, run(env, &res, &ticker, from, random)?))
}

/// Ends the tick: the players push, every mob's motion settles.
/// `{elixir, stepped, steps}`: the Elixir mobs' velocities `[{index,
/// velocity}]`, the native mobs whose step went through, and each changed
/// one's `{id, position, row, events, effects, outside}`.
#[rustler::nif]
fn mob_section_finish<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
) -> NifResult<Term<'a>> {
    finish(env, res, ticker)
}

/// `mob_section_finish/2` for many changed mobs.
#[rustler::nif(schedule = "DirtyCpu")]
fn mob_section_finish_dirty<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
) -> NifResult<Term<'a>> {
    finish(env, res, ticker)
}

fn finish<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut inner = owned(env, &res)?;
    let running = inner.running.take().ok_or_else(|| fail(atoms::no_tick()))?;
    let state = ticker
        .state()?
        .take()
        .ok_or_else(|| fail(atoms::no_tick()))?;
    let velocities = state.ticker.finish(&state.players);
    let elixir: Vec<(usize, Vec3)> = running
        .tick
        .order
        .iter()
        .enumerate()
        .filter(|(_, e)| **e == Entrant::Elixir)
        .filter_map(|(i, _)| velocities.get(i).map(|v| (i, (v[0], v[1], v[2]))))
        .collect();
    let stepped: Vec<i32> = running
        .tick
        .turns
        .iter()
        .filter(|(_, t)| t.stepped)
        .map(|(id, _)| *id)
        .collect();
    let steps = tick::finish(&mut inner.section, running.tick, &velocities);
    let mut out = Vec::with_capacity(steps.len());
    for step in steps.iter().filter(|s| s.changed) {
        let slot = inner
            .section
            .peek_mut(step.id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let p = slot.mob.position;
        let row = row(&rules, slot, false);
        let effects = Value::List(step.effects.iter().map(effect).collect());
        out.push(
            (
                step.id,
                (p[0], p[1], p[2]),
                mob_term::encode(env, &row)?,
                mob_term::encode(env, &events_value(&rules, &step.events))?,
                mob_term::encode(env, &effects)?,
                step.outside,
            )
                .encode(env),
        );
    }
    Ok((elixir, stepped, out).encode(env))
}

/// The pending moves out of the section: those of `kept` went ahead, the
/// others go back to their state before the tick.
#[rustler::nif]
fn mob_section_settle(
    env: Env,
    res: ResourceArc<MobSectionRes>,
    kept: Vec<i32>,
) -> NifResult<Atom> {
    let mut inner = owned(env, &res)?;
    tick::settle(&mut inner.section, &kept);
    Ok(atoms::ok())
}

// ------------------------------------------------------- outside actions

fn number(v: &Value) -> NifResult<f64> {
    v.as_number().ok_or(rustler::Error::BadArg)
}

fn vec2(v: &Value) -> NifResult<[f64; 2]> {
    let [x, z] = v.as_tuple_n::<2>().ok_or(rustler::Error::BadArg)?;
    Ok([number(x)?, number(z)?])
}

fn vec3(v: &Value) -> NifResult<[f64; 3]> {
    v.as_tuple_n::<3>()
        .ok_or(rustler::Error::BadArg)
        .and_then(|[x, y, z]| Ok([number(x)?, number(y)?, number(z)?]))
}

fn field<'a>(map: &'a Map, key: &str) -> Option<&'a Value> {
    map.get_atom(key).filter(|v| !v.is_nil())
}

fn damage_type(rules: &Rules, v: &Value) -> NifResult<u16> {
    let name = match v.as_map() {
        Some(m) => m.get_atom("type").and_then(|t| t.as_atom()),
        None => v.as_atom(),
    }
    .ok_or(rustler::Error::BadArg)?;
    rules
        .facts
        .damage_types
        .id(name.as_str())
        .ok_or(rustler::Error::BadArg)
}

fn attacker(v: &Value) -> NifResult<Attacker> {
    let m = v.as_map().ok_or(rustler::Error::BadArg)?;
    Ok(Attacker {
        uuid: m
            .get_atom("uuid")
            .and_then(Value::as_binary)
            .and_then(|b| b.try_into().ok())
            .ok_or(rustler::Error::BadArg)?,
        entity_id: m
            .get_atom("entity_id")
            .and_then(Value::as_int)
            .ok_or(rustler::Error::BadArg)? as i32,
        player: m
            .get_atom("player")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        entity_type: m
            .get_atom("type")
            .and_then(Value::as_binary)
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default(),
        mainhand: field(m, "mainhand").cloned(),
    })
}

/// A hit as the Elixir's (`%{source, amount, attacker, direct, position,
/// direction, extra_knockback, lift, bypass_immunity, killer}`).
fn hit(rules: &Rules, term: Term) -> NifResult<Hit> {
    let v = mob_term::decode(term)?;
    let m = v.as_map().ok_or(rustler::Error::BadArg)?;
    let mut hit = Hit::new(
        damage_type(rules, m.get_atom("source").ok_or(rustler::Error::BadArg)?)?,
        field(m, "amount").map(number).transpose()?.unwrap_or(0.0),
    );
    hit.attacker = field(m, "attacker").map(attacker).transpose()?;
    hit.direct = field(m, "direct").map(attacker).transpose()?;
    hit.position = field(m, "position").map(vec3).transpose()?;
    hit.direction = field(m, "direction").map(vec2).transpose()?;
    hit.extra_knockback = match field(m, "extra_knockback") {
        Some(v) => {
            let [power, direction] = v.as_tuple_n::<2>().ok_or(rustler::Error::BadArg)?;
            Some((number(power)?, vec2(direction)?))
        }
        None => None,
    };
    hit.lift = field(m, "lift").map(number).transpose()?;
    hit.bypass_immunity = field(m, "bypass_immunity").and_then(Value::as_bool) == Some(true);
    hit.killer = field(m, "killer").cloned();
    Ok(hit)
}

/// Runs `f` on mob `id` (an outside action): during a tick its velocity is
/// the ticker's first and goes back to it after, and its events join its
/// turn's. `{:ok, {result, events, row}}`, events empty during a tick.
fn act<'a, R: Encoder>(
    env: Env<'a>,
    res: &MobSectionRes,
    ticker: Option<&MobTicker>,
    id: i32,
    f: impl FnOnce(&Rules, &mut NativeMob, &mut Vec<Event>) -> R,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut inner = owned(env, res)?;
    let Inner { section, running } = &mut *inner;
    let in_tick = running
        .as_ref()
        .and_then(|r| r.tick.turns.get(&id).map(|t| t.index));
    let mut guard = match (ticker, in_tick) {
        (Some(t), Some(_)) => Some(t.state()?),
        _ => None,
    };
    let slot = section.get_mut(id).ok_or_else(|| fail(atoms::missing()))?;
    let index = in_tick.filter(|_| guard.as_ref().is_some_and(|g| g.is_some()));
    if let (Some(i), Some(g)) = (index, guard.as_mut()) {
        if let Some(state) = g.as_mut() {
            slot.mob.body.velocity = state.ticker.current[i].velocity;
        }
    }
    let mut events = Vec::new();
    let result = f(&rules, &mut slot.mob, &mut events);
    if let (Some(i), Some(g)) = (index, guard.as_mut()) {
        if let Some(state) = g.as_mut() {
            state.ticker.current[i].velocity = slot.mob.body.velocity;
            state.ticker.current[i].position = slot.mob.position;
        }
    }
    let row = row(&rules, slot, false);
    let p = slot.mob.position;
    section.relocate(id);
    let events = match running.as_mut().and_then(|r| r.tick.turns.get_mut(&id)) {
        Some(turn) => {
            turn.out.events.extend(events);
            Value::List(Vec::new())
        }
        None => events_value(&rules, &events),
    };
    Ok((
        atoms::ok(),
        (
            result,
            mob_term::encode(env, &events)?,
            ((p[0], p[1], p[2]), mob_term::encode(env, &row)?),
        ),
    )
        .encode(env))
}

/// `Combat.resolve/2` of `hit` on mob `id`: `{:ok, {outcome, events,
/// {position, row}}}` with `outcome` `{hurt, full, died, previous,
/// health}`.
#[rustler::nif]
fn mob_section_hurt<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: Option<ResourceArc<MobTicker>>,
    id: i32,
    hit_term: Term<'a>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let hit = hit(&rules, hit_term)?;
    act(env, &res, ticker.as_deref(), id, |rules, mob, events| {
        let (more, r) = combat::resolve(rules, mob, &hit);
        events.extend(more);
        (r.hurt, r.full, r.died, r.previous, r.health)
    })
}

/// `Combat.hit_body/3` (a mob's melee landing mid-tick): `{:ok, {hurt,
/// events, {position, row}}}`; `timers`: it has not ticked yet, so its hurt
/// timers run now.
#[rustler::nif]
fn mob_section_hit<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: Option<ResourceArc<MobTicker>>,
    id: i32,
    hit_term: Term<'a>,
    push: Option<Vec3>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let hit = hit(&rules, hit_term)?;
    // A mob still to take its turn this tick runs its hurt timers now
    // (`baseTick`), as the owner's ageing ran them for the rest.
    let waiting = read(&res)?
        .running
        .as_ref()
        .and_then(|r| r.tick.turns.get(&id))
        .is_some_and(|t| !t.stepped && !t.refused);
    act(env, &res, ticker.as_deref(), id, |rules, mob, events| {
        if let Some((x, y, z)) = push {
            living_body::push(&mut mob.body, [x, y, z]);
        }
        let (more, hurt) = if hit.amount > 0.0 {
            combat::hit_body(rules, mob, &hit)
        } else {
            (Vec::new(), false)
        };
        events.extend(more);
        if hurt && waiting {
            health::tick(&mut mob.body.mob.living.health);
        }
        (hurt, living_mob::alive(&mob.body.mob))
    })
}

/// Whether `hit` would kill mob `id` (`MobTicks.kills?`): nothing changes.
#[rustler::nif]
fn mob_section_kills(res: ResourceArc<MobSectionRes>, id: i32, hit_term: Term) -> NifResult<bool> {
    let rules = rules()?;
    let hit = hit(&rules, hit_term)?;
    let inner = read(&res)?;
    let Some(slot) = inner.section.get(id) else {
        return Ok(false);
    };
    let mut mob = slot.mob.clone();
    let (_, hurt) = combat::hit_body(&rules, &mut mob, &hit);
    Ok(hurt && !living_mob::alive(&mob.body.mob))
}

/// `/kill` (`Store.kill/2`): `{:ok, {dying, events, {position, row}}}`,
/// `dying` false for one already dying.
#[rustler::nif]
fn mob_section_kill<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
) -> NifResult<Term<'a>> {
    act(env, &res, None, id, |rules, mob, events| {
        living_body::kill(rules, mob, events)
    })
}

/// `Body.push/2`: `{:ok, {nil, [], {position, row}}}`.
#[rustler::nif]
fn mob_section_push<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: Option<ResourceArc<MobTicker>>,
    id: i32,
    impulse: Vec3,
) -> NifResult<Term<'a>> {
    act(env, &res, ticker.as_deref(), id, |_, mob, _| {
        living_body::push(&mut mob.body, [impulse.0, impulse.1, impulse.2]);
    })
}

/// `Body.hurt/3` of damage type `source` without an attacker (an
/// explosion, a falling anvil), then the explosion's push when given
/// (`Explosion.change/2`).
#[rustler::nif]
fn mob_section_blast<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    source: Atom,
    amount: f64,
    impulse: Option<Vec3>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let source_name = source.encode(env).atom_to_string()?;
    let source = rules
        .facts
        .damage_types
        .id(&source_name)
        .ok_or(rustler::Error::BadArg)?;
    act(env, &res, None, id, |rules, mob, events| {
        if let Some((more, _)) = combat::hurt_body(rules, mob, None, &Hit::new(source, amount)) {
            events.extend(more);
        }
        if let Some((x, y, z)) = impulse {
            living_body::push(&mut mob.body, [x, y, z]);
        }
    })
}

/// `Body.name/2`: a name tag's name and persistence.
#[rustler::nif]
fn mob_section_name<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    name: Term<'a>,
) -> NifResult<Term<'a>> {
    let name = mob_term::decode(name)?;
    act(env, &res, None, id, |_, mob, _| {
        living_body::name(&mut mob.body, name)
    })
}

/// A displacement or a portal's change of motion: the velocity and, when
/// given, the position, ground and rotation.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn mob_section_motion<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: Option<ResourceArc<MobTicker>>,
    id: i32,
    position: Option<Vec3>,
    velocity: Vec3,
    on_ground: Option<bool>,
    rotation: Option<(f64, f64)>,
) -> NifResult<Term<'a>> {
    act(env, &res, ticker.as_deref(), id, |_, mob, _| {
        if let Some((x, y, z)) = position {
            mob.position = [x, y, z];
        }
        mob.body.velocity = [velocity.0, velocity.1, velocity.2];
        if let Some(g) = on_ground {
            mob.body.on_ground = g;
        }
        if let Some((yaw, pitch)) = rotation {
            mob.body.yaw = yaw;
            mob.body.pitch = pitch;
        }
    })
}

/// The fields its store's entry holds of mob `id` where an outside step
/// set them (a teleport, a portal, a piston): its position (in another
/// section for one its owner moves on at once), rotation `{yaw, pitch,
/// head_yaw}`, velocity, ground and portal cooldown.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn mob_section_sync<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    position: Vec3,
    rotation: Vec3,
    velocity: Vec3,
    on_ground: bool,
    cooldown: i32,
) -> NifResult<Term<'a>> {
    act(env, &res, None, id, |_, mob, _| {
        mob.position = [position.0, position.1, position.2];
        mob.body.yaw = rotation.0;
        mob.body.pitch = rotation.1;
        mob.body.head_yaw = rotation.2;
        mob.body.velocity = [velocity.0, velocity.1, velocity.2];
        mob.body.on_ground = on_ground;
        mob.body.portal_cooldown = cooldown.clamp(0, 32767);
    })
}

/// The portal cooldown (`EntityPortals.renew/1`).
#[rustler::nif]
fn mob_section_cooldown<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    ticks: i32,
) -> NifResult<Term<'a>> {
    act(env, &res, None, id, |_, mob, _| {
        mob.body.portal_cooldown = ticks
    })
}

/// A status effect action (`RegionData.mob_effect/5`): `{:add, id, {ticks,
/// amplifier, ambient, particles, icon}}` (`Effects.add/3`), `{:heal,
/// amount}`.
#[rustler::nif]
fn mob_section_effect<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    action: Term<'a>,
) -> NifResult<Term<'a>> {
    let t = get_tuple(action)?;
    let tag: Atom = t.first().ok_or(rustler::Error::BadArg)?.decode()?;
    if tag == atoms::add() {
        let effect: i32 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        let (ticks, amplifier, ambient, particles, icon): (i32, u8, bool, bool, bool) =
            t.get(2).ok_or(rustler::Error::BadArg)?.decode()?;
        let rung = Rung {
            ticks,
            amplifier,
            ambient,
            particles,
            icon,
        };
        act(env, &res, None, id, |_, mob, _| {
            effects::add(&mut mob.body.mob.living.effects, effect, rung)
        })
    } else if tag == atoms::heal() {
        let amount: f64 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        act(env, &res, None, id, |_, mob, _| {
            health::heal(&mut mob.body.mob.living.health, amount)
        })
    } else if tag == atoms::ignite() {
        let ticks: i32 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        act(env, &res, None, id, |_, mob, _| {
            let fire = &mut mob.body.mob.living.fire_ticks;
            *fire = (*fire).max(ticks);
        })
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// The deaths of mobs `ids` its owner has not dropped yet, taken: `[{id,
/// death, {x, y, z}}]`.
#[rustler::nif]
fn mob_section_deaths<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ids: Vec<i32>,
) -> NifResult<Term<'a>> {
    let mut inner = owned(env, &res)?;
    let mut out = Vec::new();
    for id in ids {
        if let Some(slot) = inner.section.get_mut(id) {
            if let Some(death) = slot.mob.body.mob.death.take() {
                let p = slot.mob.position;
                out.push((id, mob_term::encode(env, &death)?, (p[0], p[1], p[2])).encode(env));
            }
        }
    }
    Ok(out.encode(env))
}

/// Each mob's timers for `ticks` ticks (`Store.age/4`'s `Body.tick/1`, at
/// most 40, stopping when its death animation ends): `[{id, changed, row,
/// events, done}]` (`row` nil when unchanged). `commit` false only
/// foresees which would be done, changing nothing.
#[rustler::nif]
fn mob_section_age<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ages: Vec<(i32, u32)>,
    commit: bool,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut inner = if commit {
        owned(env, &res)?
    } else {
        read(&res)?
    };
    let mut out = Vec::with_capacity(ages.len());
    for (id, ticks) in ages {
        let Some(slot) = inner.section.peek_mut(id) else {
            continue;
        };
        let mut mob = if commit { None } else { Some(slot.mob.clone()) };
        let target = mob.as_mut().unwrap_or(&mut slot.mob);
        let before = (
            target.body.portal_cooldown,
            target.body.mob.living.health.clone(),
            target.body.mob.player_memory,
            target.body.mob.hurt_by_player,
        );
        let mut events = Vec::new();
        let mut done = false;
        for _ in 0..ticks.clamp(1, 40) {
            done = living_body::tick(&mut target.body, &mut events);
            if done {
                break;
            }
        }
        let changed = before
            != (
                target.body.portal_cooldown,
                target.body.mob.living.health.clone(),
                target.body.mob.player_memory,
                target.body.mob.hurt_by_player,
            );
        if !commit {
            out.push(
                (
                    id,
                    changed,
                    rustler::types::atom::nil(),
                    Vec::<Term>::new(),
                    done,
                )
                    .encode(env),
            );
            continue;
        }
        let row_term = if changed || !events.is_empty() {
            slot.touched = true;
            mob_term::encode(env, &row(&rules, slot, false))?
        } else {
            rustler::types::atom::nil().encode(env)
        };
        let events = mob_term::encode(env, &events_value(&rules, &events))?;
        out.push((id, changed, row_term, events, done).encode(env));
    }
    if commit {
        inner.section.revision += 1;
    }
    Ok(out.encode(env))
}

/// The ids of the mobs whose spawn rules read them, with what they read:
/// `[{id, type, {x, y, z}, persistent, alive}]`.
#[rustler::nif]
fn mob_section_mobs<'a>(env: Env<'a>, res: ResourceArc<MobSectionRes>) -> NifResult<Term<'a>> {
    let inner = read(&res)?;
    let rows: Vec<Term> = inner
        .section
        .slots()
        .map(|(id, s)| {
            let p = s.mob.position;
            (
                id,
                crate::binary(env, s.mob.body.entity_type.as_bytes()),
                (p[0], p[1], p[2]),
                s.mob.body.mob.persistent,
                living_mob::alive(&s.mob.body.mob),
            )
                .encode(env)
        })
        .collect();
    Ok(rows.encode(env))
}

/// Chunk of a position, for tests of the index.
#[allow(dead_code)]
fn chunk(p: [f64; 3]) -> (i32, i32) {
    chunk_of(p)
}

/// A lid's push of mob `id` during the tick (`MobTicks.lid_pushes/3`): its
/// move by `delta` over the ticker without its own turn. `{:ok, {nil, [],
/// {position, row}}}`, or `{:error, reason}` where the kernel refuses it.
#[rustler::nif]
fn mob_section_displace<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    ticker: ResourceArc<MobTicker>,
    id: i32,
    delta: Vec3,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let physics = physics_nif::facts()?;
    let (index, input) = {
        let inner = read(&res)?;
        let index = inner
            .running
            .as_ref()
            .and_then(|r| r.tick.turns.get(&id).map(|t| t.index))
            .ok_or_else(|| fail(atoms::no_tick()))?;
        let slot = inner
            .section
            .get(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let ty = rules
            .of(&slot.mob.body.entity_type)
            .ok_or_else(|| fail(atoms::invalid()))?;
        let attributes = tick::travel_attributes(&rules, ty, &slot.mob);
        (
            index,
            tick::kernel_input(&rules, &NoMotionHooks, ty, &slot.mob, attributes),
        )
    };
    let moved = {
        let mut guard = ticker.state()?;
        let state = guard.as_mut().ok_or_else(|| fail(atoms::no_tick()))?;
        let view: &physics_nif::View<physics_nif::SnapshotArc> = &state.view;
        let world = World {
            source: view,
            facts: physics,
            border: crate::player::border(state.border),
            entities: &[],
        };
        match state
            .ticker
            .displace(&world, index, input, [delta.0, delta.1, delta.2])
        {
            Ok(m) => m,
            Err(_) => return Ok((atoms::error(), atoms::invalid()).encode(env)),
        }
    };
    act(env, &res, None, id, |_, mob, _| {
        mob.position = moved.position;
        mob.body.velocity = moved.velocity;
        mob.body.on_ground = moved.on_ground;
    })
}
