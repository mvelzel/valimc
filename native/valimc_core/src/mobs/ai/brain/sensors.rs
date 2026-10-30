//! Vanilla's brain sensors (`Valimc.AI.Sensors`), each a scan over the mob
//! that sets its memories, run by the brain at its scan rate:
//! `NearestLivingEntitySensor`, `PlayerSensor`, `NearestItemSensor`,
//! `HurtBySensor`, `AdultSensor`, and a family's own (`Sensor::Family`).
//!
//! Visibility is `Sensor.isEntityTargetable`: non-combat targeting within
//! the follow range, in sight, tested once a scan and cached in the
//! `nearest_visible_living_entities` memory.

use super::{BrainFamily, Mem, MemValue, Sensor, Visible};
use crate::mobs::ai::turn::{Seen, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::sensing::{self, Entity, GameMode, Ref, SensedItem};
use crate::physics::Aabb;

/// Runs `sensor` on the mob.
pub fn scan(t: &mut Turn, family: &dyn BrainFamily, sensor: Sensor) {
    match sensor {
        Sensor::NearestLiving => nearest_living(t),
        Sensor::Players => players(t),
        Sensor::Items => items(t, family),
        Sensor::HurtBy => hurt_by(t),
        Sensor::NearestAdult => nearest_adult(t),
        Sensor::Family(tag) => family.scan(t, tag),
    }
}

fn follow(t: &Turn) -> f64 {
    t.attribute("minecraft:follow_range")
}

/// `Sensor.isEntityTargetable(body, target)`.
pub fn targetable(t: &mut Turn, target: &Ref) -> bool {
    let invisible = t.mem_ref(Mem::AttackTarget) != Some(*target);
    let range = follow(t);
    t.test(
        target,
        &Targeting::new(false).range(range).invisible(invisible),
    )
}

/// `Sensor.isEntityAttackable(body, target)`.
pub fn attackable(t: &mut Turn, target: &Ref) -> bool {
    let invisible = t.mem_ref(Mem::AttackTarget) != Some(*target);
    let range = follow(t);
    t.test(
        target,
        &Targeting::new(true).range(range).invisible(invisible),
    )
}

/// `Sensor.isEntityAttackableIgnoringLineOfSight`.
pub fn attackable_ignoring_sight(t: &mut Turn, target: &Ref) -> bool {
    let range = follow(t);
    t.test(
        target,
        &Targeting::new(true)
            .range(range)
            .sight(false)
            .invisible(false),
    )
}

fn visible_refs(t: &Turn) -> Option<Vec<Ref>> {
    match t.memory(Mem::NearestVisibleLivingEntities) {
        Some(MemValue::Visible(v)) => Some(v.entities.clone()),
        _ => None,
    }
}

// The memory's sight cache: tested once a scan.
fn visible(t: &mut Turn, r: &Ref) -> bool {
    let cached = match t.memory(Mem::NearestVisibleLivingEntities) {
        Some(MemValue::Visible(v)) => v.seen.iter().find(|(k, _)| k == r).map(|&(_, s)| s),
        _ => return false,
    };
    if let Some(seen) = cached {
        return seen;
    }
    let seen = targetable(t, r);
    if let Some(MemValue::Visible(v)) = t
        .brain_mut()
        .and_then(|b| b.memories.0.get_mut(&Mem::NearestVisibleLivingEntities))
        .map(|(v, ttl)| {
            *ttl = None;
            v
        })
    {
        v.seen.push((*r, seen));
    }
    seen
}

/// `NearestVisibleLivingEntities.findClosest`: the first of the memory's
/// entities `filter` takes and the mob sees.
pub fn visible_closest(
    t: &mut Turn,
    filter: impl Fn(&Turn, Entity<'_, Extra>) -> bool,
) -> Option<Seen> {
    for r in visible_refs(t)? {
        let taken = match t.sensing.entity(&r) {
            None => continue,
            Some(e) => filter(t, e),
        };
        if taken && visible(t, &r) {
            return t.entity(Some(&r));
        }
    }
    None
}

/// `NearestVisibleLivingEntities.findAll` of every entity.
pub fn visible_all(t: &mut Turn) -> Vec<Ref> {
    let mut seen = Vec::new();
    for r in visible_refs(t).unwrap_or_default() {
        if t.sensing.entity(&r).is_some() && visible(t, &r) {
            seen.push(r);
        }
    }
    seen
}

/// `NearestVisibleLivingEntities.contains(entity)`.
pub fn visible_contains(t: &mut Turn, r: &Ref) -> bool {
    match visible_refs(t) {
        Some(refs) if refs.contains(r) => visible(t, r),
        _ => false,
    }
}

/// `findBlocksInBoxByManhattanDistance(pos, 8, 4)` for a block state in
/// `states`: the first in order of Manhattan depth, then x, then y, then z
/// (positive before its mirror).
pub fn repellent(t: &Turn, states: &[u16]) -> Option<[i32; 3]> {
    let [x, y, z] = t.block();
    t.level
        .find_blocks([x - 8, y - 4, z - 8], [x + 8, y + 4, z + 8], states)
        .into_iter()
        .map(|(p, _)| p)
        .min_by_key(|p| {
            let (dx, dy, dz) = (p[0] - x, p[1] - y, p[2] - z);
            (
                dx.abs() + dy.abs() + dz.abs(),
                dx,
                dy,
                if dz >= 0 { 0 } else { 1 },
            )
        })
}

/// `AdultSensor`: the nearest adult of its own type it sees.
fn nearest_adult(t: &mut Turn) {
    if !t.has(Mem::NearestVisibleLivingEntities) {
        return;
    }
    let own = t.type_id;
    let adult = visible_closest(t, |_, e| match e {
        Entity::Mob(m) => m.type_id == own && !m.baby,
        _ => false,
    });
    t.remember_opt(
        Mem::NearestVisibleAdult,
        adult.map(|a| MemValue::Ref(a.reference)),
    );
}

/// `NearestLivingEntitySensor`: living entities within the follow range,
/// nearest first (players before mobs on a tie), and the visible ones among
/// them, untested.
fn nearest_living(t: &mut Turn) {
    let range = follow(t);
    let b = sensing::inflate(&t.bbox(), range, range, range);
    let mine = t.uuid;
    let pos = t.pos();
    let mut living: Vec<(f64, Ref)> = Vec::new();
    for p in &t.sensing.players {
        let e = Entity::<Extra>::Player(p);
        if p.uuid != mine && p.alive && sensing::intersects(&e.bounding_box(), &b) {
            living.push((sensing::distance_sq(pos, p.position), e.reference()));
        }
    }
    for i in t.sensing.mobs_in(&sensing::Select::Any, &b) {
        let m = t.sensing.mob_at(i);
        if m.uuid != mine && m.alive {
            living.push((
                sensing::distance_sq(pos, m.position),
                Entity::Mob(m).reference(),
            ));
        }
    }
    living.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let refs: Vec<Ref> = living.into_iter().map(|(_, r)| r).collect();
    t.remember(Mem::NearestLivingEntities, MemValue::Refs(refs.clone()));
    t.remember(
        Mem::NearestVisibleLivingEntities,
        MemValue::Visible(Box::new(Visible {
            entities: refs,
            seen: Vec::new(),
        })),
    );
}

/// `PlayerSensor`: players within the follow range, nearest first, the
/// visible ones and of those the attackable ones.
fn players(t: &mut Turn) {
    let range = follow(t);
    let pos = t.pos();
    let mut near: Vec<(f64, Ref)> = t
        .sensing
        .players
        .iter()
        .map(|p| (sensing::distance_sq(pos, p.position), p))
        .filter(|(d, p)| p.mode != GameMode::Spectator && *d < range * range)
        .map(|(d, p)| (d, Entity::<Extra>::Player(p).reference()))
        .collect();
    near.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let near: Vec<Ref> = near.into_iter().map(|(_, r)| r).collect();
    let mut visible = Vec::new();
    for r in &near {
        if targetable(t, r) {
            visible.push(*r);
        }
    }
    let mut attackable_players = Vec::new();
    for r in &visible {
        if attackable(t, r) {
            attackable_players.push(*r);
        }
    }
    t.remember(Mem::NearestPlayers, MemValue::Refs(near));
    t.remember_opt(
        Mem::NearestVisiblePlayer,
        visible.first().map(|r| MemValue::Ref(*r)),
    );
    let first = attackable_players.first().copied();
    t.remember(
        Mem::NearestVisibleAttackablePlayers,
        MemValue::Refs(attackable_players),
    );
    t.remember_opt(
        Mem::NearestVisibleAttackablePlayer,
        first.map(MemValue::Ref),
    );
}

/// The box of a sensed item.
pub fn item_box(i: &SensedItem) -> Aabb {
    Entity::<Extra>::Item(i).bounding_box()
}

/// `NearestItemSensor`: the nearest item it wants, in sight, within 32
/// blocks.
fn items(t: &mut Turn, family: &dyn BrainFamily) {
    let b = sensing::inflate(&t.bbox(), 32.0, 16.0, 32.0);
    let pos = t.pos();
    let mut near: Vec<(f64, usize)> = t
        .sensing
        .items
        .iter()
        .enumerate()
        .filter(|(_, i)| i.count > 0 && sensing::intersects(&item_box(i), &b))
        .map(|(n, i)| (sensing::distance_sq(pos, i.position), n))
        .collect();
    near.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut wanted = None;
    for (d, n) in near {
        let item = &t.sensing.items[n];
        let (uuid, wants) = (item.uuid, family.wants(t, item));
        let r = Ref {
            kind: sensing::Kind::Item,
            uuid,
        };
        if wants && d < 1024.0 && line_of_sight(t, &r) {
            wanted = Some(uuid);
            break;
        }
    }
    t.remember_opt(
        Mem::NearestVisibleWantedItem,
        wanted.map(|uuid| {
            MemValue::Ref(Ref {
                kind: sensing::Kind::Item,
                uuid,
            })
        }),
    );
}

/// `World.line_of_sight?/2` from the mob's eyes (uncached).
pub fn line_of_sight(t: &mut Turn, r: &Ref) -> bool {
    let (level, sensing, eyes) = t.split();
    match sensing.entity(r) {
        Some(e) => sensing::line_of_sight(level, &eyes, e),
        None => false,
    }
}

/// `HurtBySensor`: the last damage within 40 ticks and who dealt it.
fn hurt_by(t: &mut Turn) {
    match t.mind.damage {
        Some(d) if t.mind.tick - d.tick <= 40 => {
            t.remember(Mem::HurtBy, MemValue::Damage(d.source));
            if let Some(a) = d.attacker {
                t.remember(Mem::HurtByEntity, MemValue::Ref(a));
            }
        }
        _ => t.forget(Mem::HurtBy),
    }
    if let Some(r) = t.mem_ref(Mem::HurtByEntity) {
        if !t.entity(Some(&r)).is_some_and(|e| e.alive) {
            t.forget(Mem::HurtByEntity);
        }
    }
}
