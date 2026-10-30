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
//! The tick itself, over resident state, is `mob_tick`'s.

use crate::mob_section_level::{self, LevelEnv, SectionEnv};
use crate::mob_term;
use crate::mob_tick::{LevelParts, Resident};
use crate::physics::{self as physics_nif, MobTicker, Vec3};
use crate::region::Region;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::cell::Cell;
use std::sync::{Mutex, OnceLock};
use valimc_core::mobs::ai::think::Ctx;
use valimc_core::mobs::ai::Extra;
use valimc_core::mobs::combat::{self, AiMind, Attacker, Event, Hit, Rules, SoundRef};
use valimc_core::mobs::living::mob::{self as living_mob, Type};
use valimc_core::mobs::living::{body as living_body, effects, health};
use valimc_core::mobs::model::{NativeMob, Rung, Slot as EquipSlot};
use valimc_core::mobs::record::{self, RecordError, RecordFacts};
use valimc_core::mobs::section::{chunk_of, MobSection, Slot, Written};
use valimc_core::mobs::sensing::Sensing;
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::tick::{self, Effect, Tick};
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

pub(crate) fn rules() -> NifResult<Rules<'static>> {
    Ok(Rules {
        facts: crate::mob_facts::facts()?,
        living: crate::mob_living::facts()?,
        families: crate::mob_facts::kinds()?,
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

pub(crate) struct Inner {
    pub(crate) section: MobSection,
    pub(crate) running: Option<Running>,
    /// The block view its ticks read (`mob_tick`).
    pub(crate) resident: Resident,
    /// The POI claims its villagers hold, as of its last tick.
    pub(crate) claims: std::collections::HashMap<[i32; 3], i32>,
}

impl Inner {
    fn new(section: MobSection) -> Inner {
        Inner {
            section,
            running: None,
            resident: Resident::default(),
            claims: Default::default(),
        }
    }
}

/// A tick that yielded to an Elixir mob: its turns, the level its mobs read
/// (with the section's store for light and biomes), its AI's sensing
/// between runs, every mob's id by ticker index and the shared travel
/// attributes.
pub(crate) struct Running {
    pub(crate) tick: Tick,
    pub(crate) parts: LevelParts,
    pub(crate) region: Option<ResourceArc<Region>>,
    pub(crate) sensing: Sensing<Extra>,
    pub(crate) ids: Vec<i32>,
    pub(crate) travel: std::collections::HashMap<u16, valimc_core::physics::mob::Attributes>,
}

#[rustler::resource_impl]
impl rustler::Resource for MobSectionRes {}

/// Whole mobs on their way to a sibling section of the same group.
pub struct MobParcel(Mutex<Vec<(i32, Box<Slot>)>>);

#[rustler::resource_impl]
impl rustler::Resource for MobParcel {}

pub(crate) fn read(res: &MobSectionRes) -> NifResult<std::sync::MutexGuard<'_, Inner>> {
    res.inner.lock().map_err(|_| fail(atoms::poisoned()))
}

/// A sibling section read while the caller holds its own: never waits. The
/// group's own sections are free while one of them ticks (one process runs
/// them in turn); a section another group took since the world's list was
/// set may be in its new owner's hands, and is then left out rather than
/// risk two owners waiting on each other.
pub(crate) fn sibling(res: &MobSectionRes) -> Option<std::sync::MutexGuard<'_, Inner>> {
    res.inner.try_lock().ok()
}

pub(crate) fn owned<'a>(
    env: Env,
    res: &'a MobSectionRes,
) -> NifResult<std::sync::MutexGuard<'a, Inner>> {
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
        inner: Mutex::new(Inner::new(MobSection::new((sx, sz)))),
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
            slot.start = None;
            slot.pending = false;
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
                s.ticked = slot.ticked;
                s.aged = slot.aged;
                s.idle = slot.idle;
                s.lived = slot.lived;
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

pub(crate) fn events_value(rules: &Rules, events: &[Event]) -> Value {
    Value::List(events.iter().map(|e| event(rules, e)).collect())
}

pub(crate) fn effect(rules: &Rules, e: &Effect) -> Option<Value> {
    let cell = |c: &[i32; 3]| Value::ivec3([c[0].into(), c[1].into(), c[2].into()]);
    Some(match e {
        Effect::Trample(c) => Value::tuple([Value::atom("trample"), cell(c)]),
        Effect::CrackEgg(c, s) => {
            Value::tuple([Value::atom("crack_egg"), cell(c), Value::Int(*s as i64)])
        }
        Effect::Ai(e) => return mob_section_level::effect(rules.facts, e),
    })
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

/// A mob's row (`%NativeBody{}`); `shown` nil where observers saw the same
/// (unless `fresh`: a new entry's). The slot remembers it as what its
/// owner's store holds (`publish::RowKey`), so a tick reports it again only
/// once it changes.
pub(crate) fn row(rules: &Rules, slot: &mut Slot, fresh: bool) -> Value {
    let Some(ty) = rules.of(&slot.mob.body.entity_type) else {
        return NIL;
    };
    let shown = living_body::shown(rules, ty, &slot.mob.body);
    let shown_value = if !fresh && slot.shown.as_ref() == Some(&shown) {
        NIL
    } else {
        let v = shown_value(rules, ty, &shown);
        slot.shown = Some(shown);
        v
    };
    let key = valimc_core::mobs::publish::RowKey::of(rules, ty, &slot.mob);
    let mob = &slot.mob;
    let body = &mob.body;
    let m = &body.mob;
    let state = m.ai.as_ref().and_then(|mind| mind.state.as_ref());
    let data = Map::from_pairs(
        key.data
            .fields()
            .iter()
            .map(|(k, v)| (Value::Atom(k.clone()), v.clone()))
            .collect(),
    )
    .unwrap_or_default();
    let mut map = Map::with_capacity(29);
    map.insert_atom("__struct__", Value::atom(NATIVE_BODY));
    map.insert_atom("type", Value::Binary(body.entity_type.as_bytes().to_vec()));
    map.insert_atom("yaw", Value::Float(body.yaw));
    map.insert_atom("pitch", Value::Float(body.pitch));
    map.insert_atom("head_yaw", Value::Float(body.head_yaw));
    map.insert_atom("velocity", Value::vec3(body.velocity));
    map.insert_atom("on_ground", Value::bool(body.on_ground));
    map.insert_atom("no_gravity", Value::bool(body.no_gravity));
    map.insert_atom("alive", Value::bool(key.alive));
    map.insert_atom("dimensions", Value::vec3(key.dimensions));
    map.insert_atom("custom_name", key.custom_name.clone().unwrap_or(NIL));
    map.insert_atom("portal_cooldown", Value::Int(key.portal_cooldown as i64));
    map.insert_atom("persistent", Value::bool(key.persistent));
    map.insert_atom("from_bucket", Value::bool(key.from_bucket));
    map.insert_atom("shown", shown_value);
    map.insert_atom("in_water", Value::bool(key.in_water));
    map.insert_atom(
        "killed_by",
        key.killed_by.map_or(NIL, |u| {
            Value::tuple([Value::atom("player"), uuid_value(&u)])
        }),
    );
    map.insert_atom("recent", Value::bool(key.recent));
    map.insert_atom("data", Value::Map(data));
    map.insert_atom("target", key.target.as_ref().map_or(NIL, reference));
    map.insert_atom("knockback_resistance", Value::Float(key.attributes[0]));
    map.insert_atom("step_height", Value::Float(key.attributes[1]));
    map.insert_atom("gravity", Value::Float(key.attributes[2]));
    map.insert_atom("explosion_resistance", Value::Float(key.attributes[3]));
    map.insert_atom("death", Value::bool(key.death));
    map.insert_atom("no_ai", Value::bool(key.no_ai));
    map.insert_atom("idle", state.map_or(NIL, |s| Value::Int(s.no_action)));
    map.insert_atom(
        "leash",
        Value::or_nil(key.leash.as_ref(), |(holder, id, restored)| {
            use valimc_core::mobs::model::LeashHolder;
            let holder = match holder {
                LeashHolder::Player(u) => Value::tuple([Value::atom("player"), uuid_value(u)]),
                LeashHolder::Knot([x, y, z]) => Value::tuple([
                    Value::atom("knot"),
                    Value::ivec3([(*x).into(), (*y).into(), (*z).into()]),
                ]),
            };
            Map::from_atoms([
                ("holder", holder),
                ("id", Value::or_nil(*id, |i| Value::Int(i as i64))),
                ("restored", Value::bool(*restored)),
            ])
            .into()
        }),
    );
    slot.row = Some(Box::new(key));
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

pub(crate) fn ctx<'a>(rules: &'a Rules<'a>) -> NifResult<Ctx<'a>> {
    Ok(Ctx {
        rules,
        kinds: crate::mob_facts::kinds()?,
        paths: crate::path::path_facts().ok_or(rustler::Error::BadArg)?,
    })
}

pub(crate) fn families<'a>(rules: &Rules<'a>) -> NifResult<tick::Families<'a>> {
    Ok(tick::Families {
        kinds: crate::mob_facts::kinds()?,
        facts: rules.facts,
    })
}

pub(crate) fn section_env<'a>(
    rules: &Rules<'a>,
    region: Option<&'a Region>,
    view: &'a physics_nif::View<physics_nif::SnapshotArc>,
    level: &'a LevelEnv,
) -> SectionEnv<'a> {
    SectionEnv {
        region,
        view,
        facts: rules.facts,
        zoom_seed: level.zoom_seed,
        wet: level.wet,
        sea_level: level.sea_level,
        plains: rules
            .facts
            .registries
            .id("minecraft:worldgen/biome", "minecraft:plains")
            .unwrap_or(0) as u16,
        tops: level.tops.as_ref(),
        no_chunks: level.no_chunks,
    }
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
    let Inner {
        section, running, ..
    } = &mut *inner;
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
    // During a tick its turn's end reports the row to the owner's store.
    if in_tick.is_some() {
        slot.row = None;
    }
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

/// A player's use of an item on mob `id` (`RegionData`'s `{:interact_entity}`,
/// `kinds::interact`): its lead part, then its family's. `player` is
/// `{uuid, position, entity id, width, height}` (nil: unknown, no lead
/// part), `loot` the stacks each shearing table rolled (the owner rolls its
/// tables). `{:ok, {outcome, events, {position, row}}}`, the outcome
/// `:pass`, `:consume` or `{:done, hand, swing, events, others, drops,
/// convert, free, discard}` in `Valimc.Entity.Animals.Interaction`'s shapes, sounds
/// without their seeds and `convert` the record of the mob it becomes.
#[rustler::nif]
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn mob_section_interact<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    item: Term<'a>,
    player: Option<(rustler::Binary<'a>, Vec3, i32, f64, f64)>,
    infinite: bool,
    loot: Vec<(String, Vec<Term<'a>>)>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::ai::leash::Holder;
    use valimc_core::mobs::kinds::{self, interact as ki, leads};
    let item = if item.is_atom() {
        None
    } else {
        Some(mob_term::decode(item)?)
    };
    let player = match &player {
        None => None,
        Some((who, (x, y, z), pid, width, height)) => Some(leads::Player {
            uuid: who
                .as_slice()
                .try_into()
                .map_err(|_| rustler::Error::BadArg)?,
            holder: Holder {
                position: [*x, *y, *z],
                width: *width,
                height: *height,
                yaw: 0.0,
                movement: [0.0; 3],
                id: Some(*pid),
            },
        }),
    };
    let mut tables = Vec::new();
    for (name, stacks) in &loot {
        let stacks = stacks
            .iter()
            .map(|s| mob_term::decode(*s))
            .collect::<NifResult<Vec<_>>>()?;
        tables.push((name.clone(), stacks));
    }
    let request = ki::Request {
        item,
        infinite,
        player: player.map(|p| p.uuid),
    };
    let registry = crate::mob_facts::kinds()?;
    act(env, &res, None, id, |rules, mob, _| {
        let mut roll = |table: &str, _props: &[(String, String)]| -> Vec<Value> {
            tables
                .iter()
                .find(|(n, _)| n == table)
                .map(|(_, s)| s.clone())
                .unwrap_or_default()
        };
        let kind = rules
            .facts
            .entities
            .id(&mob.body.entity_type)
            .and_then(|t| registry.kind(t));
        let outcome = match kind {
            None => ki::Outcome::Pass,
            Some(kind) => {
                let mut i = ki::Interaction {
                    rules,
                    mob,
                    request: &request,
                    loot: &mut roll,
                };
                kinds::interact(&mut i, kind, player.as_ref())
            }
        };
        let value = interact_outcome(&outcome, mob);
        mob_term::encode(env, &value).unwrap_or_else(|_| atoms::invalid().encode(env))
    })
}

fn interact_outcome(
    outcome: &valimc_core::mobs::kinds::interact::Outcome,
    mob: &NativeMob,
) -> Value {
    use valimc_core::mobs::kinds::interact::{At, Hand, InteractEvent, Outcome, Source};
    let d = match outcome {
        Outcome::Pass => return Value::atom("pass"),
        Outcome::Consume => return Value::atom("consume"),
        Outcome::Done(d) => d,
    };
    let text = |s: &str| Value::Binary(s.as_bytes().to_vec());
    let hand = match d.hand() {
        Hand::Keep => Value::atom("keep"),
        Hand::Use(n) => Value::tuple([Value::atom("use"), Value::Int(*n as i64)]),
        Hand::Fill(stack) => Value::tuple([Value::atom("fill"), stack.clone()]),
        Hand::Wear(n) => Value::tuple([Value::atom("wear"), Value::Int(*n as i64)]),
    };
    let events = d
        .events
        .iter()
        .map(|e| match e {
            InteractEvent::Sound {
                sound,
                source,
                volume,
                pitch,
            } => Value::Tuple(vec![
                Value::atom("sound"),
                Value::Int(*sound as i64),
                text(source),
                Value::Float(*volume),
                Value::Float(*pitch),
            ]),
            InteractEvent::SoundBlock {
                sound,
                source,
                volume,
                pitch,
            } => Value::Tuple(vec![
                Value::atom("sound_block"),
                Value::Int(*sound as i64),
                text(source),
                Value::Float(*volume),
                Value::Float(*pitch),
            ]),
            InteractEvent::Entity(n) => Value::tuple([Value::atom("event"), Value::Int(*n as i64)]),
        })
        .collect();
    let others = Value::or_nil(d.others.as_ref(), |o| {
        Value::Tuple(vec![
            Value::Int(o.sound as i64),
            match o.source {
                Source::Named(name) => text(name),
                Source::Id(id) => Value::Int(id as i64),
            },
            Value::Float(o.volume),
            Value::Float(o.pitch),
            Value::atom(match o.at {
                At::Player => "player",
                At::Animal => "animal",
            }),
        ])
    });
    let drops = d
        .drops
        .iter()
        .map(|x| {
            Value::tuple([
                x.stack.clone(),
                Value::vec3(x.offset),
                Value::or_nil(x.add, |a| {
                    Value::tuple([Value::atom("add"), Value::vec3(a)])
                }),
            ])
        })
        .collect();
    let convert = Value::or_nil(d.convert.as_ref(), |body| {
        record::record(&NativeMob {
            uuid: mob.uuid,
            position: mob.position,
            hops: 0,
            body: (**body).clone(),
        })
    });
    let free = d
        .free
        .iter()
        .map(|c| Value::ivec3([c[0].into(), c[1].into(), c[2].into()]))
        .collect();
    Value::Tuple(vec![
        Value::atom("done"),
        hand,
        Value::bool(d.swing),
        Value::List(events),
        others,
        Value::List(drops),
        convert,
        Value::List(free),
        Value::bool(d.discard),
    ])
}

/// `Combat.mob_hit/3` of native mob `id` (`Mob.doHurtTarget`'s hit on a
/// target of type `target`, a player's for its melee goal): `{:ok, hit}` in
/// `Combat`'s shape, its source the damage type's name, or `{:error,
/// :dead_mob | :missing_entity}`.
#[rustler::nif]
fn mob_section_mob_hit<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    target: String,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let inner = read(&res)?;
    let Some(slot) = inner.section.get(id) else {
        return Ok((atoms::error(), Atom::from_str(env, "missing_entity")?).encode(env));
    };
    let target = rules
        .facts
        .entities
        .id(&target)
        .ok_or(rustler::Error::BadArg)?;
    let Some(hit) = combat::mob_hit(&rules, &slot.mob, id, target) else {
        return Ok((atoms::error(), Atom::from_str(env, "dead_mob")?).encode(env));
    };
    let attacker = |a: &Attacker| -> Value {
        Value::Map(Map::from_atoms([
            ("uuid", Value::Binary(a.uuid.to_vec())),
            ("entity_id", Value::Int(a.entity_id as i64)),
            ("player", Value::bool(a.player)),
            ("type", Value::Binary(a.entity_type.as_bytes().to_vec())),
            ("mainhand", a.mainhand.clone().unwrap_or(NIL)),
        ]))
    };
    let name = &rules.facts.damage_types.types[hit.source as usize].name;
    let mut m = Map::from_atoms([
        (
            "source",
            Value::Atom(valimc_core::mobs::term::Atom::new(
                name.strip_prefix("minecraft:").unwrap_or(name),
            )),
        ),
        ("amount", Value::Float(hit.amount)),
    ]);
    if let Some(a) = &hit.attacker {
        m.insert_atom("attacker", attacker(a));
    }
    if let Some(a) = &hit.direct {
        m.insert_atom("direct", attacker(a));
    }
    if let Some(p) = hit.position {
        m.insert_atom("position", Value::vec3(p));
    }
    if let Some((power, [x, z])) = hit.extra_knockback {
        m.insert_atom(
            "extra_knockback",
            Value::tuple([
                Value::Float(power),
                Value::tuple([Value::Float(x), Value::Float(z)]),
            ]),
        );
    }
    if let Some(k) = &hit.killer {
        m.insert_atom("killer", k.clone());
    }
    Ok((atoms::ok(), mob_term::encode(env, &Value::Map(m))?).encode(env))
}

/// An owner's change of a family field of mob `id` (`data[key] = value`:
/// a chicken that became a jockey's, a block an enderman could not put
/// down back in its arms). `{:ok, {true | false, events, {position, row}}}`,
/// false where its family has no such field.
#[rustler::nif]
fn mob_section_data<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    key: Atom,
    value: Term<'a>,
) -> NifResult<Term<'a>> {
    let key = key.to_term(env).atom_to_string()?;
    let value = mob_term::decode(value)?;
    act(env, &res, None, id, |_, mob, _| {
        mob.body.data.set(&key, value)
    })
}

/// `Conversion.convert/4` of mob `id` (`{:convert, type}` of its step, a
/// zombie drowning): the record of the mob of type `to` with `uuid` it
/// becomes where it stands, at the local difficulty's `special` multiplier
/// (`kinds::convert`); the owner removes this one. `{:ok, record}` or
/// `{:error, :missing | :invalid}`.
#[rustler::nif]
fn mob_section_convert<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    uuid: rustler::Binary<'a>,
    to: String,
    special: f64,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let inner = owned(env, &res)?;
    let uuid: [u8; 16] = uuid
        .as_slice()
        .try_into()
        .map_err(|_| rustler::Error::BadArg)?;
    let Some(slot) = inner.section.get(id) else {
        return Ok((atoms::error(), atoms::missing()).encode(env));
    };
    let converted = rules.facts.entities.id(&to).and_then(|to| {
        valimc_core::mobs::kinds::convert(
            &rules,
            crate::mob_facts::kinds().ok()?,
            &slot.mob.body,
            &uuid,
            to,
            special,
        )
    });
    match converted {
        None => Ok((atoms::error(), atoms::invalid()).encode(env)),
        Some(body) => {
            let record = record::record(&NativeMob {
                uuid,
                position: slot.mob.position,
                hops: 0,
                body,
            });
            Ok((atoms::ok(), mob_term::encode(env, &record)?).encode(env))
        }
    }
}

/// `AbstractCubeMob.remove` of a dead mob `id` (`Kind::split`): the mobs it
/// becomes as it goes, `[{record, {x, y, z}}]` (each record's uuid for the
/// owner to give), from its own random; none for a family that does not
/// split or a mob that is alive.
#[rustler::nif]
fn mob_section_split<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let inner = owned(env, &res)?;
    let mut out = Vec::new();
    if let Some(slot) = inner.section.get(id) {
        let mob = &slot.mob;
        let kind = rules
            .facts
            .entities
            .id(&mob.body.entity_type)
            .and_then(|t| crate::mob_facts::kinds().ok()?.kind(t));
        if let Some(kind) = kind.filter(|_| !living_mob::alive(&mob.body.mob)) {
            for (body, at) in kind.split(&rules, &mob.body, mob.position) {
                let record = record::record(&NativeMob {
                    uuid: [0; 16],
                    position: at,
                    hops: 0,
                    body,
                });
                out.push((mob_term::encode(env, &record)?, (at[0], at[1], at[2])).encode(env));
            }
        }
    }
    Ok(out.encode(env))
}

/// A lead's change by the owner (`Valimc.Entity.Leashes`' `bind`, `knot`
/// and `snip` of native mobs): `{holder, id}` leashes mob `id` to `holder`
/// (`{:player, uuid}` or `{:knot, {x, y, z}}`, network id `id`) keeping its
/// momentum; nil takes its lead and home away.
#[rustler::nif]
fn mob_section_leash<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    leash: Term<'a>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::kinds::leads;
    use valimc_core::mobs::model::LeashHolder;
    let leash = mob_term::decode(leash)?;
    let to = match leash.as_tuple_n::<2>() {
        None => None,
        Some([holder, holder_id]) => {
            let holder = match holder.as_tuple_n::<2>() {
                Some([kind, uuid]) if kind.is_atom("player") => LeashHolder::Player(
                    uuid.as_binary()
                        .and_then(|b| b.try_into().ok())
                        .ok_or(rustler::Error::BadArg)?,
                ),
                Some([kind, pos]) if kind.is_atom("knot") => {
                    let [x, y, z] = pos.as_ivec3().ok_or(rustler::Error::BadArg)?;
                    let c = |v: i64| i32::try_from(v).map_err(|_| rustler::Error::BadArg);
                    LeashHolder::Knot([c(x)?, c(y)?, c(z)?])
                }
                _ => return Err(rustler::Error::BadArg),
            };
            let holder_id = holder_id
                .as_int()
                .and_then(|i| i32::try_from(i).ok())
                .ok_or(rustler::Error::BadArg)?;
            Some((holder, holder_id))
        }
    };
    act(env, &res, None, id, |_, mob, _| match to {
        Some((holder, holder_id)) => leads::attach(mob, holder, Some(holder_id)),
        None => {
            leads::remove(mob);
        }
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
        // A rung, or `Effects.add/3`'s one-rung list.
        let term = *t.get(2).ok_or(rustler::Error::BadArg)?;
        let term = match term.decode::<Vec<Term>>() {
            Ok(list) => *list.first().ok_or(rustler::Error::BadArg)?,
            Err(_) => term,
        };
        let (ticks, amplifier, ambient, particles, icon): (i32, u8, bool, bool, bool) =
            term.decode()?;
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

/// A schooling fish's school as its spawn pack made it (`AI.spawn_groups`
/// in the Elixir): the leader it follows (nil) and the size it leads. Its
/// mind is made first where it has none yet.
#[rustler::nif]
fn mob_section_school(
    env: Env,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    leader: Option<rustler::Binary>,
    school: i64,
) -> NifResult<Atom> {
    use valimc_core::mobs::water::fish::School;
    let rules = rules()?;
    let ctx = ctx(&rules)?;
    let mut inner = owned(env, &res)?;
    let slot = inner
        .section
        .get_mut(id)
        .ok_or_else(|| fail(atoms::missing()))?;
    valimc_core::mobs::ai::think::ensure(&ctx, &mut slot.mob);
    let leader = match leader {
        Some(b) => Some(
            b.as_slice()
                .try_into()
                .map_err(|_| rustler::Error::BadArg)?,
        ),
        None => None,
    };
    if let Some(s) = slot.mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
        match s.own.family_mut::<School>() {
            Some(o) => *o = School { leader, school },
            None => s.own.family = Some(Box::new(School { leader, school })),
        }
    }
    Ok(atoms::ok())
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
            tick::kernel_input(&rules, &families(&rules)?, ty, &slot.mob, attributes),
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

/// Oracle entry points (the vanilla stages' native modes), built only with
/// the `parity` feature.
#[cfg(feature = "parity")]
mod oracle {
    use super::*;
    use valimc_core::mobs::ai::think;
    use valimc_core::mobs::kinds::interact::InteractEvent;

    mod oracle_atoms {
        rustler::atoms! { love, feed, event }
    }

    /// A section holding mobs anywhere (a scene around the origin), owned by
    /// the caller.
    #[rustler::nif]
    fn mob_section_oracle_new(env: Env) -> ResourceArc<MobSectionRes> {
        let mut section = MobSection::new((0, 0));
        section.anywhere = true;
        ResourceArc::new(MobSectionRes {
            owner: Mutex::new(env.pid()),
            inner: Mutex::new(Inner::new(section)),
        })
    }

    /// Mob `id` thinks with a mind now (`AI.ensure/2`), its body (and a
    /// cube's move control) facing `body_yaw`, and holds its lead's holder `leash_id` as it does once it
    /// found it.
    #[rustler::nif]
    fn mob_section_oracle_prepare(
        env: Env,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        body_yaw: f64,
        leash_id: Option<i32>,
    ) -> NifResult<Atom> {
        let rules = rules()?;
        let ctx = ctx(&rules)?;
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        think::ensure(&ctx, &mut slot.mob);
        let cube = matches!(
            slot.mob.body.entity_type.as_str(),
            "minecraft:slime" | "minecraft:magma_cube"
        );
        if let Some(s) = slot.mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
            s.body_yaw = body_yaw;
            // A cube's move control faces its spawn yaw, as the oracle sets it.
            if cube && s.own.family.is_none() {
                s.own.family = Some(Box::new(valimc_core::mobs::monsters::cube::CubeOwn {
                    y_rot: body_yaw,
                    ..Default::default()
                }));
            }
        }
        if let (Some(leash), Some(lid)) = (slot.mob.body.mob.leash.as_mut(), leash_id) {
            leash.restored = false;
            leash.id = Some(lid);
        }
        Ok(atoms::ok())
    }

    /// `StandUp.bed/4` natively over a view (`{:rows, ...}` or supplied
    /// states), for its parity test: `{x, y, z}` or nil.
    #[rustler::nif]
    fn mob_stand_up_parity(
        view: Term,
        head: (i32, i32, i32),
        facing: usize,
        yaw: f64,
    ) -> NifResult<Option<(f64, f64, f64)>> {
        let physics = physics_nif::facts()?;
        let (x, y, z) = head;
        let region = valimc_core::physics::Aabb::new(
            [x as f64 - 6.0, y as f64 - 4.0, z as f64 - 6.0],
            [x as f64 + 6.0, y as f64 + 4.0, z as f64 + 6.0],
        );
        let view = physics_nif::owned_view(view, physics, &region)?;
        let facts = crate::mob_facts::facts()?;
        Ok(
            mob_section_level::stand_up(&view, facts, [x, y, z], facing & 3, yaw)
                .map(|p| (p[0], p[1], p[2])),
        )
    }

    /// A squid's tentacle speed as the oracle's scene drew it (vanilla
    /// seeds it from its own entity id).
    #[rustler::nif]
    fn mob_section_oracle_tentacle(
        env: Env,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        speed: f64,
    ) -> NifResult<Atom> {
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        use valimc_core::mobs::water::squid::SquidOwn;
        if let Some(s) = slot.mob.body.mob.ai.as_mut().and_then(|m| m.state.as_mut()) {
            match s.own.family_mut::<SquidOwn>() {
                Some(o) => o.tentacle_speed = speed,
                None => {
                    let mut o = SquidOwn::fresh(id);
                    o.tentacle_speed = speed;
                    s.own.family = Some(Box::new(o));
                }
            }
        }
        Ok(atoms::ok())
    }

    /// What a scene does to mob `id` before a tick: `:love` (`fall_in_love`,
    /// its events) or `:feed` (a baby fed).
    #[rustler::nif]
    fn mob_section_oracle_act<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        what: Atom,
    ) -> NifResult<Term<'a>> {
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let mut events = Vec::new();
        if what == oracle_atoms::love() {
            for e in valimc_core::mobs::animals::feed_love(&mut slot.mob, None) {
                if let InteractEvent::Entity(n) = e {
                    events.push((oracle_atoms::event(), n).encode(env));
                }
            }
        } else if what == oracle_atoms::feed() {
            valimc_core::mobs::animals::feed_baby(&mut slot.mob);
        } else {
            return Err(rustler::Error::BadArg);
        }
        Ok(events.encode(env))
    }

    /// The mind of mob `id` as the AI stage compares it (nil without one):
    /// `%{body_yaw, goals, targets, target, aggressive, path, ambient,
    /// no_action, own}`, goals `[{index, name}]`, `own` a cube's move
    /// control (nil for others), `target` a `{kind, uuid}` and `path` `{x, y, z, speed}` of
    /// its next node.
    #[rustler::nif]
    fn mob_section_oracle_mind<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        id: i32,
    ) -> NifResult<Term<'a>> {
        let inner = read(&res)?;
        let slot = inner
            .section
            .get(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let Some(s) = slot
            .mob
            .body
            .mob
            .ai
            .as_ref()
            .and_then(|m| m.state.as_deref())
        else {
            return mob_term::encode(env, &NIL);
        };
        // The running goals by their index in the type's registration; a
        // skeleton's weapon goal by the vanilla goal it stands for.
        let names = |sel: &valimc_core::mobs::ai::selector::Selector| {
            use valimc_core::mobs::monsters::skeleton::Weapon;
            Value::List(
                sel.entries
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| e.running)
                    .filter_map(|(i, e)| Some((i, e.goal.as_deref()?)))
                    .map(|(i, g)| {
                        let name = match g.as_any().downcast_ref::<Weapon>() {
                            Some(w) if format!("{w:?}").contains("mode: Bow") => {
                                "RangedBowAttackGoal"
                            }
                            Some(_) => "MeleeAttackGoal",
                            None => g.name(),
                        };
                        Value::tuple([
                            Value::Int(i as i64),
                            Value::Binary(name.as_bytes().to_vec()),
                        ])
                    })
                    .collect(),
            )
        };
        let path = s.navigation.path.as_ref().and_then(|p| {
            p.nodes.get(p.index).map(|n| {
                Value::Tuple(vec![
                    Value::Int(n[0].into()),
                    Value::Int(n[1].into()),
                    Value::Int(n[2].into()),
                    Value::Float(s.navigation.speed),
                ])
            })
        });
        let map = Map::from_atoms([
            ("body_yaw", Value::Float(s.body_yaw)),
            ("goals", names(&s.goals)),
            ("targets", names(&s.targets)),
            ("target", Value::or_nil(s.target.as_ref(), reference)),
            ("aggressive", Value::bool(s.aggressive)),
            ("path", path.unwrap_or(NIL)),
            ("ambient", Value::Int(s.ambient)),
            ("no_action", Value::Int(s.no_action)),
            (
                "own",
                Value::or_nil(
                    s.own.family::<valimc_core::mobs::monsters::cube::CubeOwn>(),
                    |o| {
                        Map::from_atoms([
                            ("y_rot", Value::Float(o.y_rot)),
                            ("jump_delay", Value::Int(o.jump_delay)),
                            ("aggressive", Value::bool(o.aggressive)),
                        ])
                        .into()
                    },
                ),
            ),
        ]);
        let term = mob_term::encode(env, &Value::Map(map))?;
        // Another family's own state as the Elixir keeps it (a squid's
        // tentacle, a bat's spot, a turtle's travel, a school).
        if s.own
            .family::<valimc_core::mobs::monsters::cube::CubeOwn>()
            .is_none()
        {
            let own = crate::mob_think_parity::mind_own(env, s)?;
            return term.map_put(rustler::Atom::from_str(env, "own")?, own);
        }
        Ok(term)
    }

    /// Mob `id`'s health with what a record leaves out (its hurt cooldown
    /// and last hurt): `{value, maximum, hurt_ticks, death_ticks, cooldown,
    /// last_hurt}`.
    #[rustler::nif]
    fn mob_section_oracle_health(
        res: ResourceArc<MobSectionRes>,
        id: i32,
    ) -> NifResult<(f64, f64, i32, i32, i32, f64)> {
        let inner = read(&res)?;
        let slot = inner
            .section
            .get(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let h = &slot.mob.body.mob.living.health;
        Ok((
            h.value,
            h.maximum,
            h.hurt_ticks,
            h.death_ticks,
            h.cooldown,
            h.last_hurt,
        ))
    }

    /// What a record leaves out of mobs `ids`: `[{body_yaw, running goals,
    /// leash, home, move disabled}]`, `leash` nil or `{holder id,
    /// momentum}`.
    #[rustler::nif]
    fn mob_section_oracle_minds<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        ids: Vec<i32>,
    ) -> NifResult<Vec<Term<'a>>> {
        let inner = read(&res)?;
        ids.iter()
            .map(|&id| {
                let slot = inner
                    .section
                    .get(id)
                    .ok_or_else(|| fail(atoms::missing()))?;
                let state = slot
                    .mob
                    .body
                    .mob
                    .ai
                    .as_ref()
                    .and_then(|m| m.state.as_deref());
                let goals: Vec<&str> = state
                    .map(|s| s.goals.running().map(|g| g.name()).collect())
                    .unwrap_or_default();
                let leash = slot
                    .mob
                    .body
                    .mob
                    .leash
                    .as_ref()
                    .map(|l| (l.id.unwrap_or(-1), l.momentum));
                let home = slot
                    .mob
                    .body
                    .mob
                    .home
                    .as_ref()
                    .map(|h| (h.center[0], h.center[1], h.center[2], h.radius));
                Ok((
                    state.map_or(0.0, |s| s.body_yaw),
                    goals,
                    leash,
                    home,
                    state.is_some_and(|s| s.disabled & valimc_core::mobs::ai::goal::MOVE != 0),
                )
                    .encode(env))
            })
            .collect()
    }
}
