//! A section's native mobs (VMC-081d): every mob of a native type an 8 × 8
//! chunk section holds, whole, in network-id order, with a uuid index and a
//! chunk index, and what its owner's commits need of each: whether its
//! record changed since the last frame wrote it, and of what class.
//!
//! The store (`Valimc.Entity.Store`) keeps for such a mob only what routing
//! and publication need; its state lives here and is never rebuilt per tick.
//! The section is owned by the group process that owns the section (the NIF
//! resource checks it) and moves with it (`region_give`).
//!
//! Records at a cut follow `RegionStorage`'s rules: a record is written when
//! it differs (by Elixir's `==`) from the one the last frame wrote, and may
//! wait for the motion pass (at most a second) when only its travel fields
//! (`RegionStorage.travelled/1`: position, velocity, rotation, ground, the
//! mob's motion and mind) or its tick counters (an age, an egg timer, hurt,
//! fire and effect ticks, without crossing zero) changed, as an item's motion
//! and counters wait (VMC-081h). Instead of keeping the written terms, a slot
//! keeps their hashes: the whole record's, and its settled part's (the record
//! without its travel fields, counters by their sign), numbers hashed as `==`
//! compares them. The settled hash is taken from the mob in place
//! (`record::hash_stationary`), so a mob whose change may wait costs one hash
//! and no term; a record is built only to be written, or on a motion pass.
//! A mob gone since it was written leaves its uuid for the next cut's
//! deletion.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::Hasher;

use super::living::body::Shown;
use super::model::NativeMob;
use super::record;
use super::term::Value;
use crate::spawning::census::{Census, Counted};

/// The hashes of the record a frame last wrote (or a load or checkpoint
/// holds): the whole record's and its settled part's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Written {
    pub full: u64,
    pub settled: u64,
}

impl Written {
    /// The settled hash of `mob` (`record::hash_stationary`).
    pub fn settled_of(mob: &NativeMob) -> u64 {
        let mut h = DefaultHasher::new();
        record::hash_stationary(mob, true, &mut h);
        h.finish()
    }

    /// The hashes of `mob`, whose record is `record` (`record::record/1`).
    pub fn of(mob: &NativeMob, record: &Value) -> Written {
        let mut full = DefaultHasher::new();
        record::hash_value(record, &mut full);
        Written {
            full: full.finish(),
            settled: Written::settled_of(mob),
        }
    }

    /// The hashes of `mob`'s record as it is now.
    pub fn of_mob(mob: &NativeMob) -> Written {
        Written::of(mob, &record::record(mob))
    }
}

/// One native mob of the section.
#[derive(Clone, Debug)]
pub struct Slot {
    pub mob: NativeMob,
    /// The chunk its position is in (the chunk index's key).
    pub chunk: (i32, i32),
    /// What the last frame wrote of it, None while it was never written here.
    pub written: Option<Written>,
    /// Something may have changed its record since the last cut.
    pub touched: bool,
    /// Its record changed only in its travel fields since a frame wrote it:
    /// it waits for the motion pass.
    pub waiting: bool,
    /// What observers were last shown (`Body.shown/1`), None before its
    /// first publication.
    pub shown: Option<Shown>,
    /// It took its turn in the current tick.
    pub stepped: bool,
    /// Its state before this tick's turn: kept for a turn that may leave
    /// the section or meet a chunk it cannot read (`tick::Tick::begin`), and
    /// while its owner decides whether a move out of the section goes ahead,
    /// with what observers were shown then (only once its move out waits:
    /// no turn changes it).
    pub before: Option<Box<(NativeMob, Option<Shown>)>>,
    /// Where it was before a move out of the section whose state before the
    /// tick was not kept: the owner's refusal puts it back there.
    pub start: Option<[f64; 3]>,
    /// Its move out of the section waits for its owner (`tick::settle`).
    pub pending: bool,
    /// The game tick it last took its turn in (here, or in the section it
    /// came from), and the one its timers last ran in (`tick::age`).
    pub ticked: Option<i64>,
    pub aged: Option<i64>,
    /// Its idle time (`noActionTime`: its mind's, or counted while it has
    /// none) and the ticks it lived, which despawning reads.
    pub idle: i64,
    pub lived: i64,
    /// The row its owner's store holds (beside the physical fields), None
    /// before the store was first given one.
    pub row: Option<Box<super::publish::RowKey>>,
    /// What its owner's observers were last sent of it (`crate::tracker`),
    /// None until its owner starts tracking it here.
    pub tracker: Option<crate::tracker::Tracker>,
    /// Noted for the spawn census since its last refresh.
    noted: bool,
    /// Its travel attributes as its attribute overrides last gave them
    /// (`tick::TurnWorld::travel_cached`): kept while those overrides are
    /// the very term they were computed from.
    pub travel: Option<super::tick::TravelCache>,
}

impl Slot {
    pub fn new(mob: NativeMob, written: Option<Written>) -> Slot {
        Slot {
            chunk: chunk_of(mob.position),
            mob,
            written,
            touched: written.is_none(),
            waiting: false,
            shown: None,
            stepped: false,
            before: None,
            start: None,
            pending: false,
            ticked: None,
            aged: None,
            idle: 0,
            lived: 0,
            row: None,
            tracker: None,
            noted: false,
            travel: None,
        }
    }
}

/// The chunk of a position (`Grid.chunk_key/2`).
pub fn chunk_of(position: [f64; 3]) -> (i32, i32) {
    (
        (position[0].floor() as i64 >> 4) as i32,
        (position[2].floor() as i64 >> 4) as i32,
    )
}

/// The section of a chunk (`Grid.region_key/1`).
pub fn section_of(chunk: (i32, i32)) -> (i32, i32) {
    (chunk.0 >> 3, chunk.1 >> 3)
}

/// Notes slot `id` for the census once until its next refresh.
fn note(census: &mut Census, id: i32, slot: &mut Slot, limit: usize) {
    if !slot.noted && !census.stale {
        slot.noted = true;
        census.note(id, limit);
    }
}

/// Why a mob cannot join the section.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertError {
    /// Its network id is taken.
    Id,
    /// Its uuid is here already.
    Uuid,
    /// Its position is in another section.
    Outside,
}

/// What a cut writes: each changed record by uuid (None: deleted), and
/// whether a record still waits for the motion pass.
#[derive(Debug, Default)]
pub struct Cut {
    pub records: Vec<([u8; 16], Option<Value>)>,
    pub waiting: bool,
}

/// A section's native mobs.
#[derive(Debug)]
pub struct MobSection {
    /// The section's key `{sx, sz}`.
    pub section: (i32, i32),
    slots: BTreeMap<i32, Slot>,
    uuids: HashMap<[u8; 16], i32>,
    chunks: BTreeMap<(i32, i32), BTreeSet<i32>>,
    /// Mobs gone since a frame wrote them, with what it wrote.
    removed: HashMap<[u8; 16], Written>,
    /// Changes so far (any change to any mob).
    pub revision: u64,
    /// Holds mobs anywhere (an oracle's scene around the origin).
    pub anywhere: bool,
    /// How many of its mobs are of a solid type (`SOLID`).
    solids: usize,
    /// What its mobs count as toward natural spawning's caps (VMC-081g2).
    census: Census,
}

/// The types whose family gives them a collider other bodies meet
/// (`Kind::collider`: a shulker's box).
pub const SOLID: [&str; 1] = ["minecraft:shulker"];

fn solid(mob: &NativeMob) -> bool {
    SOLID.contains(&mob.body.entity_type.as_str())
}

impl MobSection {
    pub fn new(section: (i32, i32)) -> MobSection {
        MobSection {
            section,
            slots: BTreeMap::new(),
            uuids: HashMap::new(),
            chunks: BTreeMap::new(),
            removed: HashMap::new(),
            revision: 0,
            anywhere: false,
            solids: 0,
            census: Census::default(),
        }
    }

    /// How many of its mobs are of a solid type (a tick leaves a section
    /// without any out of its colliders' search).
    pub fn solids(&self) -> usize {
        self.solids
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// The network ids in order.
    pub fn ids(&self) -> impl Iterator<Item = i32> + '_ {
        self.slots.keys().copied()
    }

    pub fn slots(&self) -> impl Iterator<Item = (i32, &Slot)> {
        self.slots.iter().map(|(&id, s)| (id, s))
    }

    /// The mobs in id order that `keep` admits, to change.
    pub fn mobs_mut<'s>(
        &'s mut self,
        keep: impl Fn(i32) -> bool + 's,
    ) -> impl Iterator<Item = (i32, &'s mut NativeMob)> + 's {
        let limit = self.note_limit();
        let census = &mut self.census;
        self.slots
            .iter_mut()
            .filter(move |(&id, _)| keep(id))
            .map(move |(&id, s)| {
                note(census, id, s, limit);
                (id, &mut s.mob)
            })
    }

    pub fn contains(&self, id: i32) -> bool {
        self.slots.contains_key(&id)
    }

    pub fn id_of(&self, uuid: &[u8; 16]) -> Option<i32> {
        self.uuids.get(uuid).copied()
    }

    pub fn get(&self, id: i32) -> Option<&Slot> {
        self.slots.get(&id)
    }

    /// Slot `id` for a change: it is touched.
    pub fn get_mut(&mut self, id: i32) -> Option<&mut Slot> {
        let limit = self.note_limit();
        let slot = self.slots.get_mut(&id)?;
        slot.touched = true;
        note(&mut self.census, id, slot, limit);
        self.revision += 1;
        Some(slot)
    }

    /// Slot `id` without marking a change (bookkeeping only).
    pub fn peek_mut(&mut self, id: i32) -> Option<&mut Slot> {
        let limit = self.note_limit();
        let slot = self.slots.get_mut(&id)?;
        note(&mut self.census, id, slot, limit);
        Some(slot)
    }

    /// Adds mob `id`. `written`: the record a load or checkpoint holds of it
    /// (None: new here, written at the next cut). A mob that left since the
    /// last cut and comes back keeps what was written of it.
    pub fn insert(
        &mut self,
        id: i32,
        mob: NativeMob,
        written: Option<Written>,
    ) -> Result<(), InsertError> {
        if self.slots.contains_key(&id) {
            return Err(InsertError::Id);
        }
        if self.uuids.contains_key(&mob.uuid) {
            return Err(InsertError::Uuid);
        }
        if !self.holds(mob.position) {
            return Err(InsertError::Outside);
        }
        let written = written.or_else(|| self.removed.remove(&mob.uuid));
        self.removed.remove(&mob.uuid);
        let mut slot = Slot::new(mob, written);
        slot.touched = true;
        let limit = self.note_limit();
        note(&mut self.census, id, &mut slot, limit);
        self.solids += usize::from(solid(&slot.mob));
        self.uuids.insert(slot.mob.uuid, id);
        self.chunks.entry(slot.chunk).or_default().insert(id);
        self.slots.insert(id, slot);
        self.revision += 1;
        Ok(())
    }

    /// Takes mob `id` out: its record is deleted at the next cut if a frame
    /// wrote it.
    pub fn remove(&mut self, id: i32) -> Option<Slot> {
        let slot = self.slots.remove(&id)?;
        self.solids -= usize::from(solid(&slot.mob));
        self.uuids.remove(&slot.mob.uuid);
        if let Some(ids) = self.chunks.get_mut(&slot.chunk) {
            ids.remove(&id);
            if ids.is_empty() {
                self.chunks.remove(&slot.chunk);
            }
        }
        if let Some(written) = slot.written {
            self.removed.insert(slot.mob.uuid, written);
        }
        let limit = self.note_limit();
        self.census.note(id, limit);
        self.revision += 1;
        Some(slot)
    }

    /// Mob `id` out of the section for its turn (its indexes kept), so its
    /// AI reads the others while it changes; `put` brings it back.
    pub fn take(&mut self, id: i32) -> Option<Slot> {
        self.slots.remove(&id)
    }

    pub fn put(&mut self, id: i32, mut slot: Slot) {
        self.revision += 1;
        let limit = self.note_limit();
        note(&mut self.census, id, &mut slot, limit);
        self.slots.insert(id, slot);
    }

    /// Mob `id`'s chunk after its position changed.
    pub fn relocate(&mut self, id: i32) {
        let limit = self.note_limit();
        let Some(slot) = self.slots.get_mut(&id) else {
            return;
        };
        let chunk = chunk_of(slot.mob.position);
        if chunk == slot.chunk {
            return;
        }
        note(&mut self.census, id, slot, limit);
        if let Some(ids) = self.chunks.get_mut(&slot.chunk) {
            ids.remove(&id);
            if ids.is_empty() {
                self.chunks.remove(&slot.chunk);
            }
        }
        slot.chunk = chunk;
        self.chunks.entry(chunk).or_default().insert(id);
    }

    /// The spawn census (VMC-081g2) after refreshing the mobs noted since the
    /// last refresh (every mob when it is to be rebuilt): `count` says what
    /// a mob counts as, given what it counted as before.
    pub fn census(
        &mut self,
        count: impl Fn(i32, &Slot, Option<&Counted>) -> Option<Counted>,
    ) -> &Census {
        let census = &mut self.census;
        if census.stale {
            census.clear();
            for (&id, slot) in self.slots.iter_mut() {
                slot.noted = false;
                let now = count(id, slot, None);
                census.set(id, now);
            }
        } else {
            for id in std::mem::take(&mut census.dirty) {
                let now = match self.slots.get_mut(&id) {
                    Some(slot) => {
                        slot.noted = false;
                        count(id, slot, census.get(id))
                    }
                    None => None,
                };
                census.set(id, now);
            }
        }
        census
    }

    /// The census as of its last refresh.
    pub fn census_read(&self) -> &Census {
        &self.census
    }

    /// The most noted ids the census keeps before it forgets them for a
    /// rebuild (a section whose spawning does not run keeps none).
    fn note_limit(&self) -> usize {
        2 * self.slots.len() + 256
    }

    /// The ids of the mobs in `chunks`, in order.
    pub fn in_chunks(&self, chunks: impl IntoIterator<Item = (i32, i32)>) -> Vec<i32> {
        let mut out: Vec<i32> = chunks
            .into_iter()
            .filter_map(|c| self.chunks.get(&c))
            .flatten()
            .copied()
            .collect();
        out.sort_unstable();
        out.dedup();
        out
    }

    /// Whether its position is in this section.
    pub fn holds(&self, position: [f64; 3]) -> bool {
        self.anywhere || section_of(chunk_of(position)) == self.section
    }

    /// The records a frame writes now (`RegionStorage.diff_parts/2` of the
    /// native mobs): the changed ones whose change cannot wait, every
    /// changed one on a motion pass (`full`), the deleted ones. A mob whose
    /// move out of the section is pending is left to it.
    pub fn cut(&mut self, full: bool) -> Cut {
        let mut cut = Cut::default();
        for slot in self.slots.values_mut() {
            if slot.pending {
                continue;
            }
            if !slot.touched && !(full && slot.waiting) {
                cut.waiting |= slot.waiting;
                continue;
            }
            slot.touched = false;
            // A change of travel fields and counters alone waits for the
            // motion pass: the settled hash tells, without building its
            // record.
            let settled = Written::settled_of(&slot.mob);
            if !full {
                if let Some(w) = slot.written {
                    if w.settled == settled {
                        slot.waiting = true;
                        cut.waiting = true;
                        continue;
                    }
                }
            }
            let value = record::record(&slot.mob);
            let mut h = DefaultHasher::new();
            record::hash_value(&value, &mut h);
            let now = Written {
                full: h.finish(),
                settled,
            };
            match slot.written {
                Some(w) if w.full == now.full => slot.waiting = false,
                _ => {
                    slot.written = Some(now);
                    slot.waiting = false;
                    cut.records.push((slot.mob.uuid, Some(value)));
                }
            }
        }
        let mut removed: Vec<[u8; 16]> = self.removed.drain().map(|(uuid, _)| uuid).collect();
        removed.sort_unstable();
        cut.records
            .extend(removed.into_iter().map(|uuid| (uuid, None)));
        cut
    }

    /// Takes every record as written (a load or a checkpoint holds them).
    pub fn baseline(&mut self) {
        for slot in self.slots.values_mut() {
            if slot.pending {
                continue;
            }
            if slot.touched || slot.waiting || slot.written.is_none() {
                slot.written = Some(Written::of_mob(&slot.mob));
                slot.touched = false;
                slot.waiting = false;
            }
        }
        self.removed.clear();
    }

    /// Every mob's record, in id order.
    pub fn records(&self) -> Vec<Value> {
        self.slots
            .values()
            .map(|s| match (&s.before, s.start) {
                // A mob whose move out is pending is still where it was.
                (Some(before), _) if s.pending => record::record(&before.0),
                (_, Some(start)) if s.pending => {
                    let mut mob = s.mob.clone();
                    mob.position = start;
                    record::record(&mob)
                }
                _ => record::record(&s.mob),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mobs::model::Slot as EquipmentSlot;
    use crate::mobs::model::{
        AttributeOverride, Attributes, Body, DropChances, Effects, Equipment, FamilyData, Freezing,
        Hand, Health, Home, Leash, LeashHolder, Living, Mind, Mob, MobMotion, Rung, Using,
    };
    use crate::mobs::term::Atom;

    fn value_hash(v: &Value) -> u64 {
        let mut h = DefaultHasher::new();
        record::hash_value(v, &mut h);
        h.finish()
    }

    #[test]
    fn values_hash_as_elixir_compares() {
        // `0.0 == -0.0` and `1 == 1.0` in Elixir.
        assert_eq!(
            value_hash(&Value::Float(0.0)),
            value_hash(&Value::Float(-0.0))
        );
        assert_eq!(value_hash(&Value::Int(1)), value_hash(&Value::Float(1.0)));
        assert_ne!(value_hash(&Value::Int(1)), value_hash(&Value::Int(2)));
    }

    type Change = (&'static str, bool, fn(&mut NativeMob));

    /// Changes of a mob, and whether each changes its stationary record.
    fn changes() -> Vec<Change> {
        vec![
            // Travel fields: the stationary record stays.
            ("x", false, |m| m.position[0] += 1.0),
            ("yaw", false, |m| m.body.yaw += 1.0),
            ("pitch", false, |m| m.body.pitch += 1.0),
            ("head yaw", false, |m| m.body.head_yaw += 1.0),
            ("velocity", false, |m| m.body.velocity[1] -= 0.08),
            ("ground", false, |m| m.body.on_ground = false),
            ("motion", false, |m| m.body.mob.motion.fall_distance = 2.0),
            ("mind", false, |m| {
                m.body.mob.ai = Some(Mind {
                    random: crate::mobs::random::LegacyRandom::new(5),
                    memories: None,
                    state: None,
                })
            }),
            // Fields the record leaves out, or writes alike.
            ("maximum", false, |m| m.body.mob.living.health.maximum = 9.0),
            ("cooldown", false, |m| m.body.mob.living.health.cooldown = 3),
            ("last hurt", false, |m| {
                m.body.mob.living.health.last_hurt = 2.0
            }),
            ("last mob hurt", false, |m| {
                m.body.mob.living.last_mob_hurt = Some(4)
            }),
            ("hurt by", false, |m| m.body.mob.hurt_by = Some([7; 16])),
            ("powder snow", false, |m| {
                m.body.mob.living.freezing.powder_snow = true
            }),
            ("portal cooldown below 1", false, |m| {
                m.body.portal_cooldown = -3
            }),
            ("false name", false, |m| {
                m.body.custom_name = Some(Value::atom("false"))
            }),
            ("health below a float's precision", false, |m| {
                m.body.mob.living.health.value = 8.0 + 1e-9
            }),
            ("negative zero absorption", false, |m| {
                m.body.mob.living.absorption = -0.0
            }),
            ("leash bookkeeping", false, |m| {
                m.body.mob.leash = None;
            }),
            // Stationary fields.
            ("type", true, |m| {
                m.body.entity_type = "minecraft:fox".into()
            }),
            ("no gravity", true, |m| m.body.no_gravity = true),
            ("data", true, |m| {
                m.body.data = FamilyData::new(vec![(Atom::new("age"), Value::Int(-5))]).unwrap()
            }),
            ("name", true, |m| {
                m.body.custom_name = Some(Value::Binary(b"Rex".to_vec()))
            }),
            ("preserved", true, |m| m.body.preserved = Some(vec![1, 2])),
            ("portal cooldown", true, |m| m.body.portal_cooldown = 300),
            ("hops", true, |m| m.hops = 1),
            ("health", true, |m| m.body.mob.living.health.value = 7.0),
            ("hurt ticks", true, |m| {
                m.body.mob.living.health.hurt_ticks = 10
            }),
            ("death ticks", true, |m| {
                m.body.mob.living.health.death_ticks = 1
            }),
            ("absorption", true, |m| m.body.mob.living.absorption = 4.0),
            ("effects", true, |m| {
                m.body.mob.living.effects.0 = vec![(
                    1,
                    vec![Rung {
                        ticks: 20,
                        amplifier: 0,
                        ambient: false,
                        particles: true,
                        icon: true,
                    }],
                )]
            }),
            ("fire", true, |m| m.body.mob.living.fire_ticks = 5),
            ("air", true, |m| m.body.mob.living.air_supply = 299),
            ("frozen", true, |m| {
                m.body.mob.living.freezing.frozen_ticks = 1
            }),
            ("equipment", true, |m| {
                m.body
                    .mob
                    .equipment
                    .set(EquipmentSlot::Head, Some(Value::atom("helmet")))
            }),
            ("attributes", true, |m| {
                m.body.mob.attributes.0 = std::sync::Arc::new(vec![(
                    "minecraft:max_health".into(),
                    AttributeOverride {
                        base: Some(10.0),
                        modifiers: vec![],
                    },
                )])
            }),
            ("no ai", true, |m| m.body.mob.no_ai = true),
            ("hurt by player", true, |m| {
                m.body.mob.hurt_by_player = Some([3; 16])
            }),
            ("player memory", true, |m| m.body.mob.player_memory = 99),
            ("persistent", true, |m| m.body.mob.persistent = true),
            ("left handed", true, |m| m.body.mob.left_handed = true),
            ("loot", true, |m| m.body.mob.can_pick_up_loot = true),
            ("drop chances", true, |m| {
                m.body.mob.drop_chances.0[EquipmentSlot::Head as usize] = Some(0.085)
            }),
            ("finalize", true, |m| {
                m.body.mob.finalize = Some(Atom::new("spawner"))
            }),
            ("leash holder", true, |m| {
                m.body.mob.leash.as_mut().unwrap().holder = LeashHolder::Player([2; 16])
            }),
            ("home", true, |m| {
                m.body.mob.home = Some(Home {
                    center: [1, 2, 3],
                    radius: 4,
                })
            }),
            ("using", true, |m| {
                m.body.mob.using = Some(Using {
                    hand: Hand::MainHand,
                    ticks: 3,
                })
            }),
        ]
    }

    #[test]
    fn stationary_hash_follows_the_record() {
        let mut base = mob(1, [8.5, 64.0, 8.5]);
        base.body.mob.leash = Some(Leash {
            holder: LeashHolder::Knot([1, 2, 3]),
            id: None,
            momentum: 0.0,
            restored: false,
        });
        let stationary = value_hash(&record::stationary(&base));
        let travel = exact(&base);
        for (name, changes, change) in changes() {
            let mut m = base.clone();
            change(&mut m);
            // Leaving the leash's unsaved fields is no change.
            if name == "leash bookkeeping" {
                m = base.clone();
                let leash = m.body.mob.leash.as_mut().unwrap();
                leash.id = Some(4);
                leash.momentum = 1.0;
                leash.restored = true;
            }
            let record_changed = value_hash(&record::stationary(&m)) != stationary;
            assert_eq!(record_changed, changes, "{name}: the stationary record");
            assert_eq!(exact(&m) != travel, changes, "{name}: the stationary hash");
        }
    }

    fn exact(m: &NativeMob) -> u64 {
        let mut h = DefaultHasher::new();
        record::hash_stationary(m, false, &mut h);
        h.finish()
    }

    #[test]
    fn the_settled_hash_keeps_only_the_sign_of_counters() {
        let mut base = mob(1, [8.5, 64.0, 8.5]);
        base.body.data = FamilyData::new(vec![
            (Atom::new("egg_time"), Value::Int(100)),
            (Atom::new("variant"), Value::Int(2)),
        ])
        .unwrap();
        base.body.mob.living.health.hurt_ticks = 5;
        base.body.mob.living.fire_ticks = 5;
        let settled = Written::settled_of(&base);
        let cases: Vec<Change> = vec![
            // Counters counting on: settled, though the record changed.
            ("egg timer", false, |m| {
                m.body.data.set("egg_time", Value::Int(99));
            }),
            ("hurt ticks", false, |m| {
                m.body.mob.living.health.hurt_ticks = 4
            }),
            ("fire", false, |m| m.body.mob.living.fire_ticks = 4),
            ("air", false, |m| m.body.mob.living.air_supply = 290),
            // Crossing zero, or a field that is no counter: not settled.
            ("egg laid", true, |m| {
                m.body.data.set("egg_time", Value::Int(0));
            }),
            ("hurt over", true, |m| {
                m.body.mob.living.health.hurt_ticks = 0
            }),
            ("fire out", true, |m| m.body.mob.living.fire_ticks = 0),
            ("variant", true, |m| {
                m.body.data.set("variant", Value::Int(3));
            }),
            ("health", true, |m| m.body.mob.living.health.value = 7.0),
        ];
        for (name, changes, change) in cases {
            let mut m = base.clone();
            change(&mut m);
            assert_ne!(exact(&m), exact(&base), "{name}: the record changed");
            assert_eq!(Written::settled_of(&m) != settled, changes, "{name}");
        }
    }

    fn mob(uuid: u8, position: [f64; 3]) -> NativeMob {
        NativeMob {
            uuid: [uuid; 16],
            position,
            hops: 0,
            body: Body {
                entity_type: "minecraft:wolf".into(),
                yaw: 0.0,
                pitch: 0.0,
                head_yaw: 0.0,
                velocity: [0.0; 3],
                on_ground: true,
                no_gravity: false,
                data: FamilyData::empty(),
                mob: Mob {
                    living: Living {
                        health: Health {
                            value: 8.0,
                            maximum: 8.0,
                            hurt_ticks: 0,
                            death_ticks: 0,
                            cooldown: 0,
                            last_hurt: 0.0,
                        },
                        last_mob_hurt: None,
                        absorption: 0.0,
                        effects: Effects::default(),
                        fire_ticks: 0,
                        air_supply: 300,
                        freezing: Freezing::default(),
                    },
                    equipment: Equipment::default(),
                    attributes: Attributes::default(),
                    ai: None,
                    no_ai: false,
                    motion: MobMotion::default(),
                    hurt_by_player: None,
                    player_memory: 0,
                    hurt_by: None,
                    death: None,
                    persistent: false,
                    left_handed: false,
                    can_pick_up_loot: false,
                    drop_chances: DropChances::default(),
                    finalize: None,
                    leash: None,
                    home: None,
                    using: None,
                },
                custom_name: None,
                preserved: None,
                portal_cooldown: 0,
            },
        }
    }

    #[test]
    fn cuts_write_what_changed_as_region_storage_settles() {
        let mut s = MobSection::new((0, 0));
        s.insert(5, mob(1, [8.5, 64.0, 8.5]), None).unwrap();
        // New: written at the next cut, then nothing.
        let cut = s.cut(false);
        assert_eq!(cut.records.len(), 1);
        assert!(s.cut(false).records.is_empty());
        // Only moved: waits for the motion pass.
        s.get_mut(5).unwrap().mob.position[0] = 9.5;
        let cut = s.cut(false);
        assert!(cut.records.is_empty() && cut.waiting);
        assert_eq!(s.cut(true).records.len(), 1);
        // Moved back to what was written: nothing to write.
        s.get_mut(5).unwrap().mob.position[0] = 9.5;
        assert!(s.cut(true).records.is_empty());
        // Hurt: written now.
        s.get_mut(5).unwrap().mob.body.mob.living.health.value = 6.0;
        s.get_mut(5).unwrap().mob.body.mob.living.health.hurt_ticks = 10;
        assert_eq!(s.cut(false).records.len(), 1);
        // Its hurt time counting down waits for the motion pass.
        s.get_mut(5).unwrap().mob.body.mob.living.health.hurt_ticks = 9;
        let cut = s.cut(false);
        assert!(cut.records.is_empty() && cut.waiting);
        assert_eq!(s.cut(true).records.len(), 1);
        // Gone: deleted once; one never written leaves nothing.
        s.insert(6, mob(2, [10.5, 64.0, 8.5]), None).unwrap();
        s.remove(5).unwrap();
        s.remove(6).unwrap();
        let cut = s.cut(false);
        assert_eq!(cut.records, vec![([1; 16], None)]);
        // Back before a cut: it keeps what was written.
        s.insert(7, mob(3, [8.5, 64.0, 8.5]), None).unwrap();
        s.cut(false);
        let slot = s.remove(7).unwrap();
        s.insert(8, slot.mob, None).unwrap();
        assert!(s.cut(false).records.is_empty());
    }

    #[test]
    fn indexes_by_uuid_and_chunk() {
        let mut s = MobSection::new((0, 0));
        s.insert(3, mob(1, [8.5, 64.0, 8.5]), None).unwrap();
        s.insert(1, mob(2, [20.5, 64.0, 8.5]), None).unwrap();
        assert_eq!(
            s.insert(2, mob(1, [8.5, 64.0, 8.5]), None),
            Err(InsertError::Uuid)
        );
        assert_eq!(
            s.insert(1, mob(9, [8.5, 64.0, 8.5]), None),
            Err(InsertError::Id)
        );
        assert_eq!(
            s.insert(4, mob(4, [130.0, 64.0, 8.5]), None),
            Err(InsertError::Outside)
        );
        assert_eq!(s.ids().collect::<Vec<_>>(), vec![1, 3]);
        assert_eq!(s.id_of(&[2; 16]), Some(1));
        assert_eq!(s.in_chunks([(0, 0), (1, 0)]), vec![1, 3]);
        s.get_mut(3).unwrap().mob.position[0] = 40.0;
        s.relocate(3);
        assert_eq!(s.in_chunks([(0, 0)]), Vec::<i32>::new());
        assert_eq!(s.in_chunks([(2, 0)]), vec![3]);
    }

    #[test]
    fn chunks_and_sections() {
        assert_eq!(chunk_of([-0.5, 0.0, 15.9]), (-1, 0));
        assert_eq!(section_of((-1, 8)), (-1, 1));
    }

    /// The census as a refresh over every mob would give it.
    fn census(s: &mut MobSection) -> Vec<((i32, i32), [u32; 8])> {
        let count = |_: i32, slot: &Slot, _: Option<&Counted>| {
            Some(Counted {
                kind: 1,
                category: (!slot.mob.body.mob.persistent).then_some(2),
                chunk: chunk_of(slot.mob.position),
                persistent: slot.mob.body.mob.persistent,
                bucketable: false,
            })
        };
        let refreshed: Vec<_> = s.census(count).by_chunk().map(|(c, n)| (c, *n)).collect();
        let mut whole = MobSection::new(s.section);
        for (id, slot) in s.slots() {
            whole.insert(id, slot.mob.clone(), None).unwrap();
        }
        let rebuilt: Vec<_> = whole
            .census(count)
            .by_chunk()
            .map(|(c, n)| (c, *n))
            .collect();
        assert_eq!(refreshed, rebuilt);
        refreshed
    }

    #[test]
    fn the_census_follows_every_change_since_its_last_refresh() {
        let mut s = MobSection::new((0, 0));
        s.insert(1, mob(1, [8.5, 64.0, 8.5]), None).unwrap();
        s.insert(2, mob(2, [24.5, 64.0, 8.5]), None).unwrap();
        s.insert(3, mob(3, [24.5, 64.0, 9.5]), None).unwrap();
        let mut two = [0; 8];
        two[2] = 2;
        let mut one = [0; 8];
        one[2] = 1;
        assert_eq!(census(&mut s), [((0, 0), one), ((1, 0), two)]);
        // A turn's move (take, put, relocate), a persistence change, a
        // bookkeeping change and a removal.
        let mut slot = s.take(1).unwrap();
        slot.mob.position = [40.5, 64.0, 8.5];
        s.put(1, slot);
        s.relocate(1);
        s.get_mut(2).unwrap().mob.body.mob.persistent = true;
        s.peek_mut(3).unwrap().mob.position = [56.5, 64.0, 8.5];
        assert_eq!(census(&mut s), [((2, 0), one), ((3, 0), one)]);
        s.remove(1);
        assert_eq!(census(&mut s), [((3, 0), one)]);
        // Changes past the noted limit rebuild it whole.
        for n in 0..400 {
            s.insert(10 + n, mob(20 + (n % 200) as u8, [8.5, 64.0, 8.5]), None)
                .unwrap();
            s.remove(10 + n);
        }
        let mine = s.take(3).unwrap();
        s.put(3, mine);
        assert!(s.census_read().stale);
        assert_eq!(census(&mut s), [((3, 0), one)]);
        assert!(!s.census_read().stale);
    }
}
