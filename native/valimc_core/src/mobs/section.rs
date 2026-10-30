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
//! Records at a cut mirror `RegionStorage`'s diff exactly: a record is
//! written when it differs (by Elixir's `==`) from the one the last frame
//! wrote, and may wait for the motion pass when only its travel fields
//! (`RegionStorage.travelled/1`: position, velocity, rotation, ground, the
//! mob's motion and mind) changed. Instead of keeping the written terms, a
//! slot keeps their hashes: the whole record's and the record without its
//! travel fields, numbers hashed as `==` compares them. A mob gone since it
//! was written leaves its uuid for the next cut's deletion.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::Hasher;

use super::living::body::Shown;
use super::model::NativeMob;
use super::record;
use super::term::Value;

/// The hashes of the record a frame last wrote (or a load or checkpoint
/// holds): the whole record's and its non-travel part's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Written {
    pub full: u64,
    pub travel: u64,
}

impl Written {
    /// The hashes of `record`.
    pub fn of(record: &Value) -> Written {
        let mut full = DefaultHasher::new();
        let mut travel = DefaultHasher::new();
        hash_record(record, &mut full, &mut travel);
        Written {
            full: full.finish(),
            travel: travel.finish(),
        }
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
    /// Its state before this tick's turn, kept while its owner decides
    /// whether a move out of the section goes ahead.
    pub before: Option<Box<(NativeMob, Option<Shown>)>>,
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
        }
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
        let slot = self.slots.get_mut(&id)?;
        slot.touched = true;
        self.revision += 1;
        Some(slot)
    }

    /// Slot `id` without marking a change (bookkeeping only).
    pub fn peek_mut(&mut self, id: i32) -> Option<&mut Slot> {
        self.slots.get_mut(&id)
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
        if section_of(chunk_of(mob.position)) != self.section {
            return Err(InsertError::Outside);
        }
        let written = written.or_else(|| self.removed.remove(&mob.uuid));
        self.removed.remove(&mob.uuid);
        let mut slot = Slot::new(mob, written);
        slot.touched = true;
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
        self.revision += 1;
        Some(slot)
    }

    /// Mob `id`'s chunk after its position changed.
    pub fn relocate(&mut self, id: i32) {
        let Some(slot) = self.slots.get_mut(&id) else {
            return;
        };
        let chunk = chunk_of(slot.mob.position);
        if chunk == slot.chunk {
            return;
        }
        if let Some(ids) = self.chunks.get_mut(&slot.chunk) {
            ids.remove(&id);
            if ids.is_empty() {
                self.chunks.remove(&slot.chunk);
            }
        }
        slot.chunk = chunk;
        self.chunks.entry(chunk).or_default().insert(id);
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
        section_of(chunk_of(position)) == self.section
    }

    /// The records a frame writes now (`RegionStorage.diff_parts/2` of the
    /// native mobs): the changed ones whose change cannot wait, every
    /// changed one on a motion pass (`full`), the deleted ones. A mob whose
    /// move out of the section is pending is left to it.
    pub fn cut(&mut self, full: bool) -> Cut {
        let mut cut = Cut::default();
        for slot in self.slots.values_mut() {
            if slot.before.is_some() {
                continue;
            }
            if !slot.touched && !(full && slot.waiting) {
                cut.waiting |= slot.waiting;
                continue;
            }
            let value = record::record(&slot.mob);
            let now = Written::of(&value);
            slot.touched = false;
            match slot.written {
                Some(w) if w.full == now.full => slot.waiting = false,
                Some(w) if !full && w.travel == now.travel => {
                    slot.waiting = true;
                    cut.waiting = true;
                }
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
            if slot.before.is_some() {
                continue;
            }
            if slot.touched || slot.waiting || slot.written.is_none() {
                slot.written = Some(Written::of(&record::record(&slot.mob)));
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
            .map(|s| match &s.before {
                // A mob whose move out is pending is still where it was.
                Some(before) => record::record(&before.0),
                None => record::record(&s.mob),
            })
            .collect()
    }
}

// Hashing as Elixir's `==` compares: integers and floats by value (`1 ==
// 1.0`, `0.0 == -0.0`), everything else exactly.
fn hash_value(v: &Value, h: &mut DefaultHasher) {
    match v {
        Value::Atom(a) => {
            h.write_u8(1);
            h.write(a.as_str().as_bytes());
            h.write_u8(0xff);
        }
        Value::Int(i) => hash_number(*i as f64, Some(*i), h),
        Value::Float(f) => hash_number(*f, None, h),
        Value::Binary(b) => {
            h.write_u8(3);
            h.write_usize(b.len());
            h.write(b);
        }
        Value::List(items) => {
            h.write_u8(4);
            h.write_usize(items.len());
            items.iter().for_each(|i| hash_value(i, h));
        }
        Value::Tuple(items) => {
            h.write_u8(5);
            h.write_usize(items.len());
            items.iter().for_each(|i| hash_value(i, h));
        }
        Value::Map(m) => {
            h.write_u8(6);
            h.write_usize(m.len());
            for (k, v) in m.iter() {
                hash_value(k, h);
                hash_value(v, h);
            }
        }
        Value::Opaque(b) => {
            h.write_u8(7);
            h.write(b);
        }
    }
}

fn hash_number(f: f64, int: Option<i64>, h: &mut DefaultHasher) {
    h.write_u8(2);
    // An integer too large for a double compares by its own value.
    match int {
        Some(i) if (i as f64) as i64 != i || i.unsigned_abs() > 1 << 53 => {
            h.write_u8(1);
            h.write_i64(i);
        }
        _ => {
            h.write_u8(0);
            let f = if f == 0.0 { 0.0 } else { f };
            h.write_u64(f.to_bits());
        }
    }
}

const TRAVEL: [&str; 6] = ["x", "y", "z", "velocity", "rotation", "on_ground"];
const MOB_TRAVEL: [&str; 2] = ["motion", "ai"];

// The whole record into `full`, its non-travel part into `travel`.
fn hash_record(record: &Value, full: &mut DefaultHasher, travel: &mut DefaultHasher) {
    hash_value(record, full);
    let Some(map) = record.as_map() else {
        hash_value(record, travel);
        return;
    };
    for (k, v) in map.iter() {
        let name = k.as_atom().map(|a| a.as_str());
        if name.is_some_and(|n| TRAVEL.contains(&n)) {
            continue;
        }
        hash_value(k, travel);
        match (name, v.as_map()) {
            (Some("mob"), Some(mob)) => {
                travel.write_u8(6);
                for (mk, mv) in mob.iter() {
                    if mk
                        .as_atom()
                        .is_some_and(|a| MOB_TRAVEL.contains(&a.as_str()))
                    {
                        continue;
                    }
                    hash_value(mk, travel);
                    hash_value(mv, travel);
                }
            }
            _ => hash_value(v, travel),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mobs::term::Map;

    fn record(x: f64, health: f64) -> Value {
        let mob = Map::from_atoms([
            ("living", Value::Float(health)),
            ("motion", Value::Float(x)),
            ("ai", Value::Int(1)),
        ]);
        Map::from_atoms([
            ("x", Value::Float(x)),
            ("y", Value::Float(64.0)),
            ("mob", mob.into()),
        ])
        .into()
    }

    #[test]
    fn written_hashes_as_elixir_compares() {
        let a = Written::of(&record(1.0, 20.0));
        assert_eq!(a, Written::of(&record(1.0, 20.0)));
        // `0.0 == -0.0` and `1 == 1.0` in Elixir.
        assert_eq!(
            Written::of(&Value::Float(0.0)),
            Written::of(&Value::Float(-0.0))
        );
        assert_eq!(Written::of(&Value::Int(1)), Written::of(&Value::Float(1.0)));
        // Moving changes only the full hash; health changes both.
        let moved = Written::of(&record(2.0, 20.0));
        assert_ne!(a.full, moved.full);
        assert_eq!(a.travel, moved.travel);
        let hurt = Written::of(&record(1.0, 19.0));
        assert_ne!(a.travel, hurt.travel);
    }

    fn mob(uuid: u8, position: [f64; 3]) -> NativeMob {
        use crate::mobs::model::*;
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
        assert_eq!(s.cut(false).records.len(), 1);
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
}
