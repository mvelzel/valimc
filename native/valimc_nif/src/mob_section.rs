//! A section's mobs (VMC-081d, `valimc_core::mobs::section`) for Elixir: the
//! `MobSection` resource its group process owns (as the Region resource:
//! only the owner changes it, `mob_section_give` hands it on with the
//! section), its records and rows, and the outside actions on its mobs.
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
use crate::mob_tick::Resident;
use crate::physics::{self as physics_nif, Vec3};
use crate::region::Region;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::cell::Cell;
use std::sync::{Mutex, OnceLock};
use valimc_core::mobs::ai::think::Ctx;
use valimc_core::mobs::combat::{self, AiMind, Attacker, Event, Hit, Rules, SoundRef};
use valimc_core::mobs::living::mob::{self as living_mob, Type};
use valimc_core::mobs::living::{body as living_body, health};
use valimc_core::mobs::model::{NativeMob, Rung, Slot as EquipSlot};
use valimc_core::mobs::record::{self, RecordError, RecordFacts};
use valimc_core::mobs::section::{chunk_of, MobSection, Slot, Written};
use valimc_core::mobs::term::{Map, Value, NIL};
use valimc_core::mobs::tick::{self, Effect};

mod atoms {
    rustler::atoms! {
        ok, error, not_owner, poisoned, invalid, unsupported, duplicate, outside, missing,
        busy, native, fixed, done, dying, ignored,
        add, heal, ignite, hurt, all, record_facts_missing, no_tick, remove, clear,
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
    /// The block view its ticks read (`mob_tick`).
    pub(crate) resident: Resident,
    /// The POI claims its villagers hold, as of its last tick.
    pub(crate) claims: std::collections::HashMap<[i32; 3], i32>,
    /// Structure queries answered that the mob that asked has not taken
    /// yet (one whose goals did not run: NoAI), kept for its next ticks.
    pub(crate) located: std::collections::HashMap<([u8; 16], u64), Option<[i32; 3]>>,
}

impl Inner {
    fn new(section: MobSection) -> Inner {
        Inner {
            section,
            resident: Resident::default(),
            claims: Default::default(),
            located: Default::default(),
        }
    }
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

pub(crate) fn restore(value: &Value) -> NifResult<Result<NativeMob, Atom>> {
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
                let w = written.then(|| Written::of_mob(&mob));
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

/// The body record of a fresh mob of `entity_type` (`Body.new/1`: its
/// family's data, full health, its family's air and motion), without the
/// store entry's uuid and position: `{:ok, record}`, or `{:error,
/// :invalid}` for a type that is not a mob.
#[rustler::nif]
fn mob_section_fresh<'a>(env: Env<'a>, entity_type: String) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let Some(ty) = rules.of(&entity_type).filter(|ty| ty.facts.living()) else {
        return Ok((atoms::error(), atoms::invalid()).encode(env));
    };
    let mob = NativeMob {
        uuid: [0; 16],
        position: [0.0; 3],
        hops: 0,
        body: living_body::fresh(&rules, ty),
    };
    let mut value = record::record(&mob);
    if let Value::Map(map) = &mut value {
        for key in ["kind", "uuid", "x", "y", "z", "hops"] {
            map.remove(&Value::atom(key));
        }
    }
    Ok((atoms::ok(), mob_term::encode(env, &value)?).encode(env))
}

/// The entity properties loot tables read of mob `id` (its family's: a
/// sheep's colour, a variant, a cube's size), as `[{name, value}]`; empty
/// for a missing mob.
#[rustler::nif]
fn mob_section_properties(
    res: ResourceArc<MobSectionRes>,
    id: i32,
) -> NifResult<Vec<(String, String)>> {
    let rules = rules()?;
    let inner = read(&res)?;
    let Some(slot) = inner.section.get(id) else {
        return Ok(Vec::new());
    };
    let body = &slot.mob.body;
    Ok(rules
        .of(&body.entity_type)
        .map(|ty| rules.family(ty).loot_properties(body))
        .unwrap_or_default())
}

/// The living types whose families take a lead (`canBeLeashed`), as
/// names.
#[rustler::nif]
fn mob_section_leashable() -> NifResult<Vec<String>> {
    let rules = rules()?;
    let kinds = crate::mob_facts::kinds()?;
    Ok(rules
        .facts
        .entities
        .types()
        .filter(|t| t.living())
        .filter(|t| kinds.kind(t.id).is_some_and(|k| k.leashable()))
        .map(|t| t.name.clone())
        .collect())
}

/// Nothing to read: a pack finishes from its members and the level's
/// random alone.
struct NoBlocks;

impl valimc_core::physics::source::BlockSource for NoBlocks {
    fn state(&self, _x: i32, _y: i32, _z: i32) -> Option<u16> {
        None
    }
}

/// Mobs that finish their spawn as they are made (`finalizeSpawn`): a
/// natural spawn's aquatic packs, each pack as a group
/// (`mobs::ai::spawn_group`), and a bucket's release, as its family's.
/// `entries` `[{slot, pack, decision, record}]` in spawn order (`slot` the
/// index of its section's level random in `randoms`, `pack` its pack's
/// number or nil, `decision` a tropical fish school's decision or nil,
/// `record` a fresh mob's with its pending reason). `{:ok, {[{record,
/// school}], randoms}}`, `school` a pack's schooling fish's `{leader,
/// size}` (nil for others).
#[rustler::nif]
fn mob_finalize<'a>(
    env: Env<'a>,
    entries: Vec<(usize, Option<i64>, Option<bool>, Term<'a>)>,
    randoms: Vec<u64>,
) -> NifResult<Term<'a>> {
    finalize(env, entries, randoms, false)
}

/// `mob_finalize`'s work; `made`: each mob's mind is made before its spawn
/// finishes and keeps its record's random (an oracle's mob, whose random
/// is as its constructor left it).
pub(crate) fn finalize<'a>(
    env: Env<'a>,
    entries: Vec<(usize, Option<i64>, Option<bool>, Term<'a>)>,
    randoms: Vec<u64>,
    made: bool,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::ai::{spawn_group, think};
    use valimc_core::mobs::level::{Level, Unknown};
    use valimc_core::mobs::random::LegacyRandom;
    let rules = rules()?;
    let ctx = ctx(&rules)?;
    let physics = crate::facts::PHYSICS.get().ok_or(rustler::Error::BadArg)?;
    let states = crate::facts::STATES.get().ok_or(rustler::Error::BadArg)?;
    let mut randoms: Vec<LegacyRandom> = randoms
        .into_iter()
        .map(|seed| LegacyRandom { seed })
        .collect();
    let mut groups: std::collections::HashMap<i64, Option<spawn_group::Group>> = Default::default();
    let mut packed = std::collections::HashSet::new();
    let mut schools = spawn_group::Schools::new();
    let mut mobs = Vec::with_capacity(entries.len());
    for (slot, pack, decision, term) in entries {
        let mut mob = match restore(&mob_term::decode(term)?)? {
            Ok(mob) => mob,
            Err(reason) => return Ok((atoms::error(), reason).encode(env)),
        };
        if made {
            let kept = mob.body.mob.ai.as_ref().map(|m| m.random);
            think::ensure(&ctx, &mut mob);
            if let (Some(random), Some(mind)) = (kept, mob.body.mob.ai.as_mut()) {
                mind.random = random;
            }
        }
        let random = randoms.get_mut(slot).ok_or(rustler::Error::BadArg)?;
        if let Some(reason) = mob.body.mob.finalize.take() {
            let mut level = Level::new(&NoBlocks, &Unknown, rules.facts, physics, states, *random);
            match pack {
                Some(pack) => {
                    packed.insert(mob.uuid);
                    let group = groups.entry(pack).or_default();
                    think::on_turn(&ctx, &mut mob, &mut level, |t, _| {
                        spawn_group::finalize(t, &reason, group, decision, &mut schools)
                    });
                }
                None => {
                    think::on_turn(&ctx, &mut mob, &mut level, |t, kind| {
                        kind.finalize(t, &reason)
                    });
                }
            }
            *random = level.random;
        }
        mobs.push(mob);
    }
    let mut out = Vec::with_capacity(mobs.len());
    for mob in &mobs {
        let schooling = packed.contains(&mob.uuid)
            && matches!(
                mob.body.entity_type.as_str(),
                "minecraft:cod" | "minecraft:salmon" | "minecraft:tropical_fish"
            );
        let school = schooling.then(|| {
            let s = schools.get(&mob.uuid).copied().unwrap_or_default();
            (s.leader.map(|l| l.to_vec()), s.school)
        });
        let school = match school {
            Some((leader, size)) => {
                let leader = match leader {
                    Some(bytes) => {
                        let mut b =
                            rustler::OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
                        b.as_mut_slice().copy_from_slice(&bytes);
                        b.release(env).encode(env)
                    }
                    None => rustler::types::atom::nil().encode(env),
                };
                (leader, size).encode(env)
            }
            None => rustler::types::atom::nil().encode(env),
        };
        out.push((mob_term::encode(env, &record::record(mob))?, school));
    }
    let randoms: Vec<u64> = randoms.iter().map(|r| r.seed).collect();
    Ok((atoms::ok(), (out, randoms)).encode(env))
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
            out.push((id, slot));
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
pub(crate) fn seed() -> i64 {
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
        Effect::Raw(v) => v.clone(),
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
    // A dragon's boss bar reads its health (`Arena.sync_bar/2`); its row
    // changes every tick its actor runs.
    let mut data = data;
    if tick::dragon(mob) {
        let h = &m.living.health;
        data.insert_atom(
            "health",
            Value::tuple([Value::Float(h.value), Value::Float(h.maximum)]),
        );
    }
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

pub(crate) fn attacker(v: &Value) -> NifResult<Attacker> {
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
        luck: field(m, "luck").and_then(Value::as_number).unwrap_or(0.0),
    })
}

/// A hit as the Elixir's (`%{source, amount, attacker, direct, position,
/// direction, extra_knockback, lift, bypass_immunity, killer}`).
fn hit(rules: &Rules, term: Term) -> NifResult<Hit> {
    hit_of(rules, &mob_term::decode(term)?)
}

/// `hit/2` of a decoded term.
pub(crate) fn hit_of(rules: &Rules, v: &Value) -> NifResult<Hit> {
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
    hit.dragon_part = field(m, "dragon_part")
        .and_then(Value::as_int)
        .map(|p| p as u8);
    hit.post_attack = field(m, "post_attack").and_then(Value::as_bool) == Some(true);
    hit.punch = match field(m, "punch") {
        Some(v) => {
            let [power, along] = v.as_tuple_n::<2>().ok_or(rustler::Error::BadArg)?;
            Some((number(power)?, vec2(along)?))
        }
        None => None,
    };
    hit.effect = field(m, "effect").and_then(combat::Hit::effect_of);
    Ok(hit)
}

/// Runs `f` on mob `id` (its living rules, `rules`), then reports its row:
/// `{:ok, {result, events, {position, row}}}`.
fn act<'a, R: Encoder>(
    env: Env<'a>,
    res: &MobSectionRes,
    id: i32,
    f: impl FnOnce(&Rules, &mut NativeMob, &mut Vec<Event>) -> R,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let mut inner = owned(env, res)?;
    let section = &mut inner.section;
    let slot = section.get_mut(id).ok_or_else(|| fail(atoms::missing()))?;
    let mut events = Vec::new();
    let result = f(&rules, &mut slot.mob, &mut events);
    let row = row(&rules, slot, false);
    let p = slot.mob.position;
    section.relocate(id);
    let events = events_value(&rules, &events);
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
/// health, post-attack actions on the attacker}`.
#[rustler::nif]
fn mob_section_hurt<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    hit_term: Term<'a>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let hit = hit(&rules, hit_term)?;
    act(env, &res, id, |rules, mob, events| {
        let (more, r) = combat::resolve(rules, mob, &hit);
        events.extend(more);
        (
            r.hurt,
            r.full,
            r.died,
            r.previous,
            r.health,
            crate::enchant::Actions(r.post),
        )
    })
}

/// `Combat.hit_body/3` (a mob's melee landing mid-tick): `{:ok, {hurt,
/// events, {position, row}}}`; `timers`: it has not ticked yet, so its hurt
/// timers run now.
#[rustler::nif]
fn mob_section_hit<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    hit_term: Term<'a>,
    push: Option<Vec3>,
) -> NifResult<Term<'a>> {
    let rules = rules()?;
    let hit = hit(&rules, hit_term)?;
    act(env, &res, id, |rules, mob, events| {
        if let Some((x, y, z)) = push {
            living_body::push(&mut mob.body, [x, y, z]);
        }
        let (more, hurt) = if hit.amount > 0.0 {
            combat::hit_body(rules, mob, &hit)
        } else {
            (Vec::new(), false)
        };
        events.extend(more);
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
    act(env, &res, id, |rules, mob, events| {
        living_body::kill(rules, mob, events)
    })
}

/// `Body.push/2`: `{:ok, {nil, [], {position, row}}}`.
#[rustler::nif]
fn mob_section_push<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    impulse: Vec3,
) -> NifResult<Term<'a>> {
    act(env, &res, id, |_, mob, _| {
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
    act(env, &res, id, |rules, mob, events| {
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
    act(env, &res, id, |_, mob, _| {
        living_body::name(&mut mob.body, name)
    })
}

/// A dispenser's equipment on mob `id` (`dispenseEquipment`): a living mob
/// that picks up loot and has nothing in `slot` wears `stack`, which it then
/// always drops unworn, and it never despawns. `{:ok, {worn, events,
/// {position, row}}}`.
#[rustler::nif]
fn mob_section_equip<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    slot: &str,
    stack: Term<'a>,
) -> NifResult<Term<'a>> {
    let slot = EquipSlot::from_name(slot).ok_or(rustler::Error::BadArg)?;
    let stack = mob_term::decode(stack)?;
    act(env, &res, id, |_, mob, _| {
        let m = &mut mob.body.mob;
        if !living_mob::alive(m) || !m.can_pick_up_loot || m.equipment.get(slot).is_some() {
            return false;
        }
        m.equipment.set(slot, Some(stack));
        m.drop_chances.0[slot as usize] = Some(2.0);
        m.persistent = true;
        true
    })
}

/// `/item replace` on mob `id` (`Mob.setItemSlot` through its slot access):
/// a living mob's `slot` holds `stack` (nil empties it), its drop chance as
/// it was. `{:ok, {set, events, {position, row}}}`.
#[rustler::nif]
fn mob_section_set_slot<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    slot: &str,
    stack: Term<'a>,
) -> NifResult<Term<'a>> {
    let slot = EquipSlot::from_name(slot).ok_or(rustler::Error::BadArg)?;
    let stack = mob_term::decode(stack)?;
    let stack = (!stack.is_nil()).then_some(stack);
    act(env, &res, id, |_, mob, _| {
        if !living_mob::alive(&mob.body.mob) {
            return false;
        }
        mob.body.mob.equipment.set(slot, stack);
        true
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
    act(env, &res, id, |rules, mob, _| {
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
    if hit.post_attack {
        m.insert_atom("post_attack", Value::bool(true));
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
    act(env, &res, id, |_, mob, _| mob.body.data.set(&key, value))
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
    act(env, &res, id, |_, mob, _| match to {
        Some((holder, holder_id)) => leads::attach(mob, holder, Some(holder_id)),
        None => {
            leads::remove(mob);
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
    act(env, &res, id, |_, mob, _| {
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
    act(env, &res, id, |_, mob, _| mob.body.portal_cooldown = ticks)
}

/// A status effect action (`RegionData.mob_effect/5`): `{:add, id, {ticks,
/// amplifier, ambient, particles, icon}}` (`addEffect`), `{:remove, id}`,
/// `{:clear}` (`removeAllEffects`), `{:heal, amount}`, `{:ignite, ticks}`.
/// The result is whether anything changed.
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
        // The dragon refuses every effect; the rest refuse their immunities.
        let kinds = crate::mob_facts::kinds()?;
        act(env, &res, id, |rules, mob, _| {
            let Some(ty) = rules.of(&mob.body.entity_type) else {
                return false;
            };
            let added = kinds.kind(ty.id).is_none_or(|kind| kind.affected(effect))
                && living_mob::add_effect(rules.facts, ty.id, &mut mob.body.mob, effect, rung);
            reconcile(rules, mob);
            added
        })
    } else if tag == atoms::remove() {
        let effect: i32 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        act(env, &res, id, |rules, mob, _| {
            let removed = living_mob::remove_effect(rules.facts, &mut mob.body.mob, effect);
            reconcile(rules, mob);
            removed
        })
    } else if tag == atoms::clear() {
        act(env, &res, id, |rules, mob, _| {
            let cleared = living_mob::clear_effects(rules.facts, &mut mob.body.mob);
            reconcile(rules, mob);
            cleared
        })
    } else if tag == atoms::heal() {
        let amount: f64 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        act(env, &res, id, |_, mob, _| {
            health::heal(&mut mob.body.mob.living.health, amount)
        })
    } else if tag == atoms::ignite() {
        let ticks: i32 = t.get(1).ok_or(rustler::Error::BadArg)?.decode()?;
        act(env, &res, id, |_, mob, _| {
            let fire = &mut mob.body.mob.living.fire_ticks;
            *fire = (*fire).max(ticks);
        })
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Health Boost's maximum follows its modifiers at once.
fn reconcile(rules: &Rules, mob: &mut NativeMob) {
    if let Some(ty) = rules.of(&mob.body.entity_type) {
        living_mob::reconcile_max_health(rules.living, rules.facts, ty, &mut mob.body.mob);
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

    /// Mob `id` as `record` restores it (a test's change of what its record
    /// holds), with its health's `{cooldown, last_hurt}` beside the record;
    /// the rest of its slot stays. `{position, row}`.
    #[rustler::nif]
    fn mob_section_oracle_put<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        record: Term<'a>,
        health: (i32, f64),
    ) -> NifResult<Term<'a>> {
        let rules = rules()?;
        let mut mob = restore(&mob_term::decode(record)?)?.map_err(fail)?;
        mob.body.mob.living.health.cooldown = health.0;
        mob.body.mob.living.health.last_hurt = health.1;
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        slot.mob = mob;
        slot.touched = true;
        let p = slot.mob.position;
        let row = row(&rules, slot, false);
        inner.section.relocate(id);
        Ok(((p[0], p[1], p[2]), mob_term::encode(env, &row)?).encode(env))
    }

    /// A brain mob `id` as an oracle seeded it after making its mind
    /// (`mob_section_oracle_prepare`): its mind's random the state `random`,
    /// its gates' (`RunOne`'s) randoms the states `gates` in their order, its
    /// sensors' countdowns `sensors` in theirs.
    #[rustler::nif]
    fn mob_section_oracle_brain(
        env: Env,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        random: u64,
        gates: Vec<u64>,
        sensors: Vec<i32>,
    ) -> NifResult<Atom> {
        use valimc_core::mobs::ai::brain::behavior::Gate;
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let mind = slot
            .mob
            .body
            .mob
            .ai
            .as_mut()
            .ok_or_else(|| fail(atoms::missing()))?;
        mind.random = valimc_core::mobs::random::LegacyRandom::from_state(random)
            .ok_or(rustler::Error::BadArg)?;
        let brain = mind
            .state
            .as_mut()
            .and_then(|s| s.brain.as_deref_mut())
            .ok_or_else(|| fail(atoms::missing()))?;
        let mut seeds = gates.into_iter();
        for entry in &mut brain.behaviors {
            let Some(b) = entry.behavior.as_mut() else {
                continue;
            };
            if let Some(gate) = b.as_any_mut().downcast_mut::<Gate>() {
                match seeds.next() {
                    Some(seed) => {
                        gate.random = valimc_core::mobs::random::LegacyRandom::from_state(seed)
                            .ok_or(rustler::Error::BadArg)?
                    }
                    None => break,
                }
            }
        }
        for (slot, time) in brain.sensors.iter_mut().zip(sensors) {
            slot.time = time;
        }
        Ok(atoms::ok())
    }

    /// A villager `id` as the village oracle made it (after
    /// `mob_section_oracle_prepare`): its brain built with the oracle's
    /// gates (`[{key, random state}]`) and activity order (`[{priority,
    /// [activity]}]`), its sensors' countdowns, the gates each remade brain
    /// takes, started by its schedule at day time `day` and game time
    /// `time`; then its mind's random the state `random` and, where given,
    /// when it last slept.
    #[rustler::nif]
    #[allow(clippy::too_many_arguments, clippy::type_complexity)]
    fn mob_section_oracle_villager(
        env: Env,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        gates: Vec<(String, u64)>,
        order: Vec<(i32, Vec<String>)>,
        sensors: Vec<i32>,
        refresh: Vec<Vec<(String, u64)>>,
        timing: (i64, i64, u64, Option<i64>),
    ) -> NifResult<Atom> {
        use valimc_core::mobs::ai::brain::{Activity, Mem, MemValue};
        use valimc_core::mobs::brains::villager::Villager;
        use valimc_core::mobs::random::LegacyRandom;
        let (day, time, random, slept) = timing;
        let rules = rules()?;
        let kinds = crate::mob_facts::kinds()?;
        let state = |s: u64| LegacyRandom::from_state(s).ok_or(rustler::Error::BadArg);
        let keyed = |rows: Vec<(String, u64)>| -> NifResult<Vec<(String, LegacyRandom)>> {
            rows.into_iter().map(|(k, s)| Ok((k, state(s)?))).collect()
        };
        let gates = keyed(gates)?;
        let refresh = refresh
            .into_iter()
            .map(keyed)
            .collect::<NifResult<Vec<_>>>()?;
        let order: Vec<(i32, Vec<Activity>)> = order
            .into_iter()
            .map(|(p, acts)| (p, acts.iter().filter_map(|a| Activity::of(a)).collect()))
            .collect();
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let ty = rules
            .facts
            .entities
            .id(&slot.mob.body.entity_type)
            .ok_or(rustler::Error::BadArg)?;
        let villager = kinds
            .kind(ty)
            .and_then(|k| k.brain())
            .and_then(|b| b.as_any().downcast_ref::<Villager>())
            .ok_or(rustler::Error::BadArg)?;
        let data = slot.mob.body.data.clone();
        let mut brain = villager.build(&data, &mut LegacyRandom::new(0), &gates, &order);
        for (s, t) in brain.sensors.iter_mut().zip(sensors) {
            s.time = t;
        }
        brain.refresh = refresh;
        Villager::start(rules.facts, &mut brain, &data, day, time);
        if let Some(slept) = slept {
            brain
                .memories
                .set(Mem::LastSlept, MemValue::Int(slept), None);
        }
        let mind = slot
            .mob
            .body
            .mob
            .ai
            .as_mut()
            .ok_or_else(|| fail(atoms::missing()))?;
        mind.random = state(random)?;
        let s = mind.state.as_mut().ok_or_else(|| fail(atoms::missing()))?;
        s.brain = Some(Box::new(brain));
        Ok(atoms::ok())
    }

    /// What the AI stages compare of brain mob `id`'s brain: `{running,
    /// activity | nil, gate seeds, memories}` (`Brain.running/1`'s
    /// `"priority:activity"`, the first active activity not core, each
    /// gate's random state, `[{name, value, ttl | :never}]`), nil without a
    /// brain.
    #[rustler::nif]
    fn mob_section_oracle_brain_view<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        id: i32,
    ) -> NifResult<Term<'a>> {
        use valimc_core::mobs::ai::brain::behavior::Gate;
        let inner = read(&res)?;
        let slot = inner
            .section
            .get(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let Some(brain) = slot
            .mob
            .body
            .mob
            .ai
            .as_ref()
            .and_then(|m| m.state.as_ref())
            .and_then(|s| s.brain.as_deref())
        else {
            return Ok(rustler::types::atom::nil().encode(env));
        };
        let gates: Vec<u64> = brain
            .behaviors
            .iter()
            .filter_map(|e| e.behavior.as_ref())
            .filter_map(|b| b.as_any().downcast_ref::<Gate>())
            .map(|g| g.random.seed)
            .collect();
        let activity = brain
            .activity()
            .map(|a| rustler::Atom::from_str(env, a.name()))
            .transpose()?;
        let view = crate::mob_oracle::brain(env, Some(brain))?;
        let memories = rustler::types::tuple::get_tuple(view)?[0];
        Ok((brain.running(), activity, gates, memories).encode(env))
    }

    /// A test's change of mob `id` beside its record: `{:no_ai, flag}`,
    /// `{:cooldown, ticks}` (its hurt cooldown) or
    /// `{:move_to, {x, y, z}, speed}` (`MobMotion.move_to/3`: its move
    /// control's wanted position). `{position, row}`.
    #[rustler::nif]
    fn mob_section_oracle_set<'a>(
        env: Env<'a>,
        res: ResourceArc<MobSectionRes>,
        id: i32,
        change: Term<'a>,
    ) -> NifResult<Term<'a>> {
        use valimc_core::mobs::model::Control;
        let rules = rules()?;
        let change = mob_term::decode(change)?;
        let items = change.as_tuple().ok_or(rustler::Error::BadArg)?;
        let tag = items
            .first()
            .and_then(Value::as_atom)
            .ok_or(rustler::Error::BadArg)?;
        let mut inner = owned(env, &res)?;
        let slot = inner
            .section
            .get_mut(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        let motion = &mut slot.mob.body.mob.motion;
        match (tag.as_str(), &items[1..]) {
            ("no_ai", [flag]) => {
                slot.mob.body.mob.no_ai = flag.as_bool().ok_or(rustler::Error::BadArg)?;
            }
            ("cooldown", [ticks]) => {
                slot.mob.body.mob.living.health.cooldown =
                    ticks.as_int().ok_or(rustler::Error::BadArg)? as i32;
            }
            ("move_to", [target, speed]) => {
                let speed = number(speed)?;
                motion.control = match motion.control {
                    Control::Jumping { .. } => Control::Jumping { speed },
                    _ => Control::MoveTo {
                        target: vec3(target)?,
                        speed,
                    },
                };
            }
            _ => return Err(rustler::Error::BadArg),
        }
        slot.touched = true;
        let p = slot.mob.position;
        let row = row(&rules, slot, false);
        Ok(((p[0], p[1], p[2]), mob_term::encode(env, &row)?).encode(env))
    }

    /// The nodes of mob `id`'s navigation path (`[{x, y, z}]`), nil without
    /// one.
    #[rustler::nif]
    fn mob_section_oracle_path(
        res: ResourceArc<MobSectionRes>,
        id: i32,
    ) -> NifResult<Option<Vec<(i32, i32, i32)>>> {
        let inner = read(&res)?;
        let slot = inner
            .section
            .get(id)
            .ok_or_else(|| fail(atoms::missing()))?;
        Ok(slot
            .mob
            .body
            .mob
            .ai
            .as_ref()
            .and_then(|m| m.state.as_ref())
            .and_then(|s| s.navigation.path.as_ref())
            .map(|p| p.nodes.iter().map(|n| (n[0], n[1], n[2])).collect()))
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
    /// states), for its test against the players' `StandUp.bed/4`: `{x,
    /// y, z}` or nil.
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
            let own = crate::mob_oracle::mind_own(env, s)?;
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

mod merchant_atoms {
    rustler::atoms! { view, start, stop, unhappy, updated, trade, offers }
}

/// A merchant's trading, for its owner (VMC-044b2, `village::merchant`):
/// `:view` (its trading state), `{:start, uuid, hero amplifier | nil}`
/// and `:stop` (its trading player), `:unhappy`, `{:updated,
/// valid}` (`notifyTradeUpdated`'s sound; whether it played), `{:trade,
/// index, uuid}` (the result map, or `{:error, reason}`) and `{:offers,
/// list}` (its offers made). `{:ok, {result, events, {position, row}}}`.
#[rustler::nif]
fn mob_section_merchant<'a>(
    env: Env<'a>,
    res: ResourceArc<MobSectionRes>,
    id: i32,
    action: Term<'a>,
) -> NifResult<Term<'a>> {
    use valimc_core::mobs::village::merchant;
    let encode =
        |v: &Value| mob_term::encode(env, v).unwrap_or_else(|_| atoms::invalid().encode(env));
    if let Ok(tag) = action.decode::<Atom>() {
        return if tag == merchant_atoms::view() {
            act(env, &res, id, |_, mob, _| encode(&merchant::view(mob)))
        } else if tag == merchant_atoms::stop() {
            act(env, &res, id, |_, mob, _| merchant::set_trading(mob, None))
        } else if tag == merchant_atoms::unhappy() {
            act(env, &res, id, |rules, mob, events| {
                merchant::unhappy(rules, mob, events)
            })
        } else {
            Err(rustler::Error::BadArg)
        };
    }
    let t = get_tuple(action)?;
    let tag: Atom = t.first().ok_or(rustler::Error::BadArg)?.decode()?;
    let arg = |i: usize| t.get(i).copied().ok_or(rustler::Error::BadArg);
    let uuid = |term: Term| -> NifResult<[u8; 16]> {
        let b: rustler::Binary = term.decode()?;
        b.as_slice().try_into().map_err(|_| rustler::Error::BadArg)
    };
    if tag == merchant_atoms::start() {
        let player = uuid(arg(1)?)?;
        let hero: Option<i64> = arg(2)?.decode()?;
        act(env, &res, id, |_, mob, _| {
            merchant::start(mob, player, hero)
        })
    } else if tag == merchant_atoms::updated() {
        let valid: bool = arg(1)?.decode()?;
        act(env, &res, id, |rules, mob, events| {
            merchant::updated(rules, mob, valid, events)
        })
    } else if tag == merchant_atoms::trade() {
        let index: usize = arg(1)?.decode()?;
        let player = uuid(arg(2)?)?;
        act(env, &res, id, |rules, mob, _| {
            match merchant::trade(rules, mob, index, player) {
                Ok(v) => encode(&v),
                Err(reason) => (
                    atoms::error(),
                    rustler::types::atom::Atom::from_str(env, reason).unwrap_or(atoms::invalid()),
                )
                    .encode(env),
            }
        })
    } else if tag == merchant_atoms::offers() {
        let offers = mob_term::decode(arg(1)?)?;
        act(env, &res, id, |_, mob, _| merchant::set_offers(mob, offers))
    } else {
        Err(rustler::Error::BadArg)
    }
}
