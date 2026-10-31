//! A villager's gossip (VMC-044c1): vanilla's `GossipContainer` and
//! `GossipType`. Per target (an entity's uuid) its entries by type, each a
//! value from 2 up to its type's cap; the weighted sum is the target's
//! reputation. Gossip decays by a day's amount (`decay`), spreads to a
//! villager it meets less its type's transfer decay (`transfer_from`, up to
//! ten entries drawn by weight) and grows with reputation events (`add`).
//!
//! Which entries a transfer draws depends on the order vanilla walks its
//! `HashMap<UUID, …>`: by bucket (`UUID.hashCode`, spread, masked by the
//! table's capacity, which grows with the most targets it ever held and
//! never shrinks), then by insertion within a bucket. The targets are kept
//! in insertion order with that peak, so the walk is vanilla's. Within a
//! target vanilla orders types by an identity hash that differs between
//! runs; here they go in declaration order.
//!
//! In family data it is `{targets, peak}`: `targets` a list of `{uuid,
//! [{type, value}]}` in insertion order.

use crate::mobs::random::LegacyRandom;
use crate::mobs::sensing::Uuid;
use crate::mobs::term::{Atom, Value};

/// `GossipType`, in declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum GossipType {
    MajorNegative,
    MinorNegative,
    MinorPositive,
    MajorPositive,
    Trading,
}

impl GossipType {
    pub const ALL: [GossipType; 5] = [
        GossipType::MajorNegative,
        GossipType::MinorNegative,
        GossipType::MinorPositive,
        GossipType::MajorPositive,
        GossipType::Trading,
    ];

    pub fn name(self) -> &'static str {
        match self {
            GossipType::MajorNegative => "major_negative",
            GossipType::MinorNegative => "minor_negative",
            GossipType::MinorPositive => "minor_positive",
            GossipType::MajorPositive => "major_positive",
            GossipType::Trading => "trading",
        }
    }

    pub fn of(name: &str) -> Option<GossipType> {
        GossipType::ALL.into_iter().find(|t| t.name() == name)
    }

    /// `(weight, max, decayPerDay, decayPerTransfer)`.
    fn facts(self) -> (i32, i32, i32, i32) {
        match self {
            GossipType::MajorNegative => (-5, 100, 10, 10),
            GossipType::MinorNegative => (-1, 200, 20, 20),
            GossipType::MinorPositive => (1, 25, 1, 5),
            GossipType::MajorPositive => (5, 20, 0, 20),
            GossipType::Trading => (1, 25, 2, 20),
        }
    }

    pub fn weight(self) -> i32 {
        self.facts().0
    }

    pub fn max(self) -> i32 {
        self.facts().1
    }
}

/// A villager's gossip.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Gossips {
    /// Targets in insertion order, each its entries by type.
    targets: Vec<(Uuid, Vec<(GossipType, i32)>)>,
    /// The most targets it ever held (its table's capacity follows).
    peak: usize,
}

/// `UUID.hashCode`, spread as `HashMap.hash`.
fn spread(uuid: &Uuid) -> u32 {
    let most = u64::from_be_bytes(uuid[..8].try_into().unwrap());
    let least = u64::from_be_bytes(uuid[8..].try_into().unwrap());
    let hilo = most ^ least;
    let h = ((hilo >> 32) as u32) ^ (hilo as u32);
    h ^ (h >> 16)
}

impl Gossips {
    /// The gossip family data holds (none: empty).
    pub fn of(value: Option<&Value>) -> Gossips {
        let Some(t) = value.and_then(Value::as_tuple_n::<2>) else {
            return Gossips::default();
        };
        let targets = t[0]
            .as_list()
            .unwrap_or(&[])
            .iter()
            .filter_map(|row| {
                let [uuid, entries] = row.as_tuple_n::<2>()?;
                let uuid: Uuid = uuid.as_binary()?.try_into().ok()?;
                let entries = entries
                    .as_list()?
                    .iter()
                    .filter_map(|e| {
                        let [k, v] = e.as_tuple_n::<2>()?;
                        Some((GossipType::of(k.as_atom()?.as_str())?, v.as_int()? as i32))
                    })
                    .collect();
                Some((uuid, entries))
            })
            .collect::<Vec<_>>();
        let peak = (t[1].as_int().unwrap_or(0) as usize).max(targets.len());
        Gossips { targets, peak }
    }

    /// Its family data term.
    pub fn value(&self) -> Value {
        let targets = self
            .targets
            .iter()
            .map(|(uuid, entries)| {
                Value::tuple([
                    Value::Binary(uuid.to_vec()),
                    Value::List(
                        entries
                            .iter()
                            .map(|(t, v)| {
                                Value::tuple([
                                    Value::Atom(Atom::new(t.name())),
                                    Value::Int(*v as i64),
                                ])
                            })
                            .collect(),
                    ),
                ])
            })
            .collect();
        Value::tuple([Value::List(targets), Value::Int(self.peak as i64)])
    }

    /// As vanilla reads it back (`new GossipContainer(entries)`): the
    /// targets in the order it walked them, its table fresh.
    pub fn reloaded(&self) -> Gossips {
        let targets = self
            .walk()
            .into_iter()
            .map(|i| self.targets[i].clone())
            .collect::<Vec<_>>();
        Gossips {
            peak: targets.len(),
            targets,
        }
    }

    fn capacity(&self) -> u32 {
        let mut capacity = 16usize;
        while self.peak > capacity * 3 / 4 {
            capacity *= 2;
        }
        capacity as u32
    }

    /// Its targets' indices in vanilla's walk.
    fn walk(&self) -> Vec<usize> {
        let mask = self.capacity() - 1;
        let mut order: Vec<usize> = (0..self.targets.len()).collect();
        order.sort_by_key(|&i| (spread(&self.targets[i].0) & mask, i));
        order
    }

    fn index(&self, uuid: &Uuid) -> Option<usize> {
        self.targets.iter().position(|(u, _)| u == uuid)
    }

    /// `getOrCreate`.
    fn target(&mut self, uuid: &Uuid) -> usize {
        match self.index(uuid) {
            Some(i) => i,
            None => {
                self.targets.push((*uuid, Vec::new()));
                self.peak = self.peak.max(self.targets.len());
                self.targets.len() - 1
            }
        }
    }

    fn put(entries: &mut Vec<(GossipType, i32)>, ty: GossipType, value: i32) {
        match entries.iter_mut().find(|(t, _)| *t == ty) {
            Some(e) => e.1 = value,
            None => {
                entries.push((ty, value));
                entries.sort_by_key(|(t, _)| *t);
            }
        }
    }

    /// `getReputation(uuid, all)`: the weighted sum of its entries.
    pub fn reputation(&self, uuid: &Uuid) -> i32 {
        self.index(uuid).map_or(0, |i| {
            self.targets[i]
                .1
                .iter()
                .map(|(t, v)| v.wrapping_mul(t.weight()))
                .fold(0i32, i32::wrapping_add)
        })
    }

    /// `add(target, type, amount)`: summed (up to the cap, never below an
    /// old value past it), then within 2 and the cap; an empty target goes.
    pub fn add(&mut self, uuid: &Uuid, ty: GossipType, amount: i32) {
        let i = self.target(uuid);
        let entries = &mut self.targets[i].1;
        let value = match entries.iter().find(|(t, _)| *t == ty) {
            Some(&(_, old)) => {
                let sum = old + amount;
                if sum > ty.max() {
                    ty.max().max(old)
                } else {
                    sum
                }
            }
            None => amount,
        };
        if value < 2 {
            entries.retain(|(t, _)| *t != ty);
        } else {
            Gossips::put(entries, ty, value.min(ty.max()));
        }
        if self.targets[i].1.is_empty() {
            self.targets.remove(i);
        }
    }

    /// `decay`: every entry less its day's decay; below 2 it goes.
    pub fn decay(&mut self) {
        for (_, entries) in self.targets.iter_mut() {
            entries.retain_mut(|(t, v)| {
                *v -= t.facts().2;
                *v >= 2
            });
        }
        self.targets.retain(|(_, e)| !e.is_empty());
    }

    /// `transferFrom(source, random, max)`: up to `max` of the source's
    /// entries drawn by their weighted values (each once), each kept less
    /// its transfer decay when that leaves 2 or more, merged by the greater
    /// value. How many entries it drew.
    pub fn transfer_from(
        &mut self,
        source: &Gossips,
        random: &mut LegacyRandom,
        max: i32,
    ) -> usize {
        let entries: Vec<(Uuid, GossipType, i32)> = source
            .walk()
            .into_iter()
            .flat_map(|i| {
                let (uuid, entries) = &source.targets[i];
                entries.iter().map(move |&(t, v)| (*uuid, t, v))
            })
            .collect();
        if entries.is_empty() {
            return 0;
        }
        let mut ranges = Vec::with_capacity(entries.len());
        let mut end = 0i32;
        for (_, t, v) in &entries {
            end += v.wrapping_mul(t.weight()).abs();
            ranges.push(end - 1);
        }
        let mut chosen = vec![false; entries.len()];
        for _ in 0..max {
            let choice = random.int(end);
            let i = ranges.partition_point(|&r| r < choice);
            chosen[i] = true;
        }
        let mut count = 0;
        for (i, &(uuid, ty, value)) in entries.iter().enumerate() {
            if !chosen[i] {
                continue;
            }
            count += 1;
            let decayed = value - ty.facts().3;
            if decayed >= 2 {
                let at = self.target(&uuid);
                let entries = &mut self.targets[at].1;
                let merged = entries
                    .iter()
                    .find(|(t, _)| *t == ty)
                    .map_or(decayed, |&(_, old)| old.max(decayed));
                Gossips::put(entries, ty, merged);
            }
        }
        count
    }

    pub fn is_empty(&self) -> bool {
        self.targets.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(n: u8) -> Uuid {
        let mut u = [0u8; 16];
        u[15] = n;
        u[3] = n.wrapping_mul(37);
        u
    }

    #[test]
    fn adds_cap_and_decay() {
        let mut g = Gossips::default();
        let a = uuid(1);
        g.add(&a, GossipType::MinorNegative, 25);
        g.add(&a, GossipType::MinorNegative, 190);
        assert_eq!(g.reputation(&a), -200);
        g.add(&a, GossipType::Trading, 2);
        assert_eq!(g.reputation(&a), -198);
        g.decay();
        assert_eq!(g.reputation(&a), -180);
        g.add(&a, GossipType::Trading, -5);
        assert_eq!(g.reputation(&a), -180);
        // A value under 2 goes, with an empty target.
        let b = uuid(2);
        g.add(&b, GossipType::MajorPositive, 1);
        assert_eq!(g.index(&b), None);
        assert_eq!(Gossips::of(Some(&g.value())), g);
    }

    #[test]
    fn transfers_by_weight() {
        let mut source = Gossips::default();
        source.add(&uuid(3), GossipType::MajorNegative, 25);
        source.add(&uuid(4), GossipType::Trading, 2);
        let mut me = Gossips::default();
        let mut random = LegacyRandom::new(7);
        let n = me.transfer_from(&source, &mut random, 10);
        assert!(n >= 1);
        // Major negative decays 10 on the way; trading's 2 falls below 2.
        assert_eq!(me.reputation(&uuid(3)), -75);
        assert_eq!(me.reputation(&uuid(4)), 0);
    }
}
