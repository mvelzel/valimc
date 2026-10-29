//! What a native mob senses of other entities (VMC-081d), mirroring
//! `Valimc.AI.World`'s sensing half: the group's players, the section's
//! items and mobs as sensed rows, `TargetingConditions.test` (`test/4`),
//! `getVisibilityPercent`, `getNearestPlayer` and `getNearestEntity`,
//! `getEntitiesOfClass` over the section's mobs in section order (with the
//! tick's grid from 32 mobs on), and `hasLineOfSight` cached per tick in the
//! mind (`sees?/2`).
//!
//! A mob is sensed again as it changes mid-tick (`World.resense`: after it
//! moved, its own state changed or another mob changed it), so mobs later in
//! order read it as it is now; its place in the section's order stays.

pub mod grid;
pub mod sight;

use super::facts::Slot;
use super::level::{Difficulty, Level};
use crate::physics::Aabb;
use grid::Grid;
use std::collections::HashMap;

pub type Uuid = [u8; 16];

/// An entity kind a mind refers to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Player,
    Mob,
    Item,
}

/// What a mind keeps of a sensed entity (`World.ref/1`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Ref {
    pub kind: Kind,
    pub uuid: Uuid,
}

/// A player's game mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GameMode {
    Survival,
    Creative,
    Adventure,
    Spectator,
}

/// Equipment slots in the order a sensed player's equipment map iterates
/// (its keys sorted): chest, feet, head, legs, main hand, off hand.
pub const EQUIPMENT: [Slot; 6] = [
    Slot::Chest,
    Slot::Feet,
    Slot::Head,
    Slot::Legs,
    Slot::MainHand,
    Slot::OffHand,
];

/// A sensed player (`Player.Host.sensed/1`).
#[derive(Clone, Debug, PartialEq)]
pub struct SensedPlayer {
    pub uuid: Uuid,
    pub id: i32,
    pub position: [f64; 3],
    pub yaw: f64,
    pub pitch: f64,
    pub eye: f64,
    pub width: f64,
    pub height: f64,
    pub mode: GameMode,
    pub invulnerable: bool,
    pub alive: bool,
    pub crouching: bool,
    pub swimming: bool,
    pub invisible: bool,
    pub armor_cover: f64,
    /// Item ids in `EQUIPMENT` order.
    pub equipment: [Option<i32>; 6],
    /// Its known movement (what a lead it holds pulls with).
    pub movement: [f64; 3],
    pub velocity: [f64; 3],
    pub health: f64,
    /// Its active effects' ids, sorted.
    pub effects: Vec<u16>,
}

impl SensedPlayer {
    /// The item worn or held in `slot`.
    pub fn equipped(&self, slot: Slot) -> Option<i32> {
        EQUIPMENT
            .iter()
            .position(|&s| s == slot)
            .and_then(|i| self.equipment[i])
    }
}

/// A sensed item (`mob_world`'s items).
#[derive(Clone, Debug, PartialEq)]
pub struct SensedItem {
    pub uuid: Uuid,
    pub position: [f64; 3],
    pub item: i32,
    pub count: i32,
    pub pickup_delay: i32,
    /// Its last physics observation.
    pub in_water: bool,
}

impl SensedItem {
    pub const WIDTH: f64 = 0.25;
    pub const HEIGHT: f64 = 0.25;
    pub const EYE: f64 = 0.2125000059604645;
}

/// A sensed mob (`AI.sensed/1`); `X` is what families and brains read of
/// each other beyond the common part (their own data, memories).
#[derive(Clone, Debug, PartialEq)]
pub struct SensedMob<X = ()> {
    pub uuid: Uuid,
    /// Its network id.
    pub id: i32,
    pub type_id: u16,
    pub position: [f64; 3],
    pub yaw: f32,
    pub pitch: f32,
    pub eye: f64,
    pub width: f64,
    pub height: f64,
    /// A family's own bounding box (a shulker's lid), else None.
    pub own_box: Option<Aabb>,
    pub alive: bool,
    pub recent_mob_hurt: bool,
    pub baby: bool,
    pub huntable: bool,
    pub target: Option<Ref>,
    pub in_love: i32,
    pub age: i32,
    pub in_water: bool,
    /// Hidden from enemies (`canBeSeenAsEnemy`: an axolotl playing dead).
    pub invulnerable: bool,
    /// The player who last hurt it.
    pub killed_by: Option<Uuid>,
    pub panicking: bool,
    pub extra: X,
}

/// An entity as a mind reads it.
#[derive(Debug)]
pub enum Entity<'a, X = ()> {
    Player(&'a SensedPlayer),
    Mob(&'a SensedMob<X>),
    Item(&'a SensedItem),
}

impl<X> Clone for Entity<'_, X> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<X> Copy for Entity<'_, X> {}

impl<'a, X> Entity<'a, X> {
    pub fn kind(&self) -> Kind {
        match self {
            Entity::Player(_) => Kind::Player,
            Entity::Mob(_) => Kind::Mob,
            Entity::Item(_) => Kind::Item,
        }
    }

    pub fn uuid(&self) -> Uuid {
        match self {
            Entity::Player(p) => p.uuid,
            Entity::Mob(m) => m.uuid,
            Entity::Item(i) => i.uuid,
        }
    }

    /// `World.ref/1`.
    pub fn reference(&self) -> Ref {
        Ref {
            kind: self.kind(),
            uuid: self.uuid(),
        }
    }

    pub fn position(&self) -> [f64; 3] {
        match self {
            Entity::Player(p) => p.position,
            Entity::Mob(m) => m.position,
            Entity::Item(i) => i.position,
        }
    }

    pub fn eye(&self) -> f64 {
        match self {
            Entity::Player(p) => p.eye,
            Entity::Mob(m) => m.eye,
            Entity::Item(_) => SensedItem::EYE,
        }
    }

    /// `World.eye_y/1`.
    pub fn eye_y(&self) -> f64 {
        self.position()[1] + self.eye()
    }

    pub fn alive(&self) -> bool {
        match self {
            Entity::Player(p) => p.alive,
            Entity::Mob(m) => m.alive,
            Entity::Item(_) => true,
        }
    }

    pub fn mode(&self) -> Option<GameMode> {
        match self {
            Entity::Player(p) => Some(p.mode),
            _ => None,
        }
    }

    pub fn invulnerable(&self) -> bool {
        match self {
            Entity::Player(p) => p.invulnerable,
            Entity::Mob(m) => m.invulnerable,
            Entity::Item(_) => false,
        }
    }

    /// The entity type of a mob.
    pub fn type_id(&self) -> Option<u16> {
        match self {
            Entity::Mob(m) => Some(m.type_id),
            _ => None,
        }
    }

    /// `World.box/1`.
    pub fn bounding_box(&self) -> Aabb {
        match self {
            Entity::Player(p) => around(p.position, p.width, p.height),
            Entity::Mob(m) => m.bounding_box(),
            Entity::Item(i) => around(i.position, SensedItem::WIDTH, SensedItem::HEIGHT),
        }
    }
}

fn around(p: [f64; 3], width: f64, height: f64) -> Aabb {
    let half = width / 2.0;
    Aabb::new(
        [p[0] - half, p[1], p[2] - half],
        [p[0] + half, p[1] + height, p[2] + half],
    )
}

impl<X> SensedMob<X> {
    /// `World.box/1`: its family's own box, else its size's.
    pub fn bounding_box(&self) -> Aabb {
        self.own_box
            .unwrap_or_else(|| around(self.position, self.width, self.height))
    }
}

/// `AABB.intersects`.
pub fn intersects(a: &Aabb, b: &Aabb) -> bool {
    a.min[0] < b.max[0]
        && a.max[0] > b.min[0]
        && a.min[1] < b.max[1]
        && a.max[1] > b.min[1]
        && a.min[2] < b.max[2]
        && a.max[2] > b.min[2]
}

/// `AABB.inflate(x, y, z)`.
pub fn inflate(b: &Aabb, dx: f64, dy: f64, dz: f64) -> Aabb {
    Aabb::new(
        [b.min[0] - dx, b.min[1] - dy, b.min[2] - dz],
        [b.max[0] + dx, b.max[1] + dy, b.max[2] + dz],
    )
}

/// The line of sight a mind has tested this tick (`mind.sight`), cleared
/// as its AI step starts.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SightCache(pub Vec<(Ref, bool)>);

impl SightCache {
    pub fn get(&self, r: &Ref) -> Option<bool> {
        self.0.iter().find(|(k, _)| k == r).map(|&(_, v)| v)
    }

    pub fn put(&mut self, r: Ref, seen: bool) {
        self.0.push((r, seen));
    }

    pub fn clear(&mut self) {
        self.0.clear();
    }
}

/// The mob that senses: what `World` reads of the thinking `Self`.
pub trait Seer<X> {
    fn uuid(&self) -> Uuid;
    fn type_id(&self) -> u16;
    fn position(&self) -> [f64; 3];
    /// `getEyeY`.
    fn eye_y(&self) -> f64;
    /// The mind's sight cache.
    fn sight(&mut self) -> &mut SightCache;
    /// Its family's `can_attack?` hook (`Mobs.hook`): true where it has none.
    fn can_attack_hook(&self, _target: Entity<'_, X>) -> bool {
        true
    }
}

/// Which mob types a query takes (`World.mobs_in/3`'s `select`).
pub enum Select<'s> {
    Any,
    Types(&'s [u16]),
    Where(&'s dyn Fn(u16) -> bool),
}

impl Select<'_> {
    fn keeps(&self, type_id: u16) -> bool {
        match self {
            Select::Any => true,
            Select::Types(types) => types.contains(&type_id),
            Select::Where(f) => f(type_id),
        }
    }
}

/// A target predicate (`conditions.select`): the target and the seer.
pub type Selector<'f, X, S> = &'f dyn Fn(Entity<'_, X>, &S) -> bool;

/// `TargetingConditions` (`World.conditions/2`).
pub struct Conditions<'f, X, S> {
    /// `forCombat`.
    pub combat: bool,
    /// None below 0.
    pub range: f64,
    /// Line of sight.
    pub sight: bool,
    /// The visibility percent applies to the range.
    pub invisible: bool,
    pub select: Option<Selector<'f, X, S>>,
}

impl<X, S> Conditions<'_, X, S> {
    /// `forCombat()` / `forNonCombat()` with vanilla's defaults.
    pub fn new(combat: bool) -> Self {
        Conditions {
            combat,
            range: -1.0,
            sight: true,
            invisible: true,
            select: None,
        }
    }
}

/// The entities a section's mobs sense in one tick.
#[derive(Debug, Default)]
pub struct Sensing<X = ()> {
    pub players: Vec<SensedPlayer>,
    pub items: Vec<SensedItem>,
    /// In section order, as sensed now.
    mobs: Vec<SensedMob<X>>,
    index: HashMap<Uuid, usize>,
    by_type: HashMap<u16, Vec<usize>>,
    grid: Option<Grid>,
}

impl<X> Sensing<X> {
    /// The tick's sensing (`AI.prepare/2`): `mobs` in section order.
    pub fn new(
        players: Vec<SensedPlayer>,
        items: Vec<SensedItem>,
        mobs: Vec<SensedMob<X>>,
    ) -> Sensing<X> {
        let mut index = HashMap::with_capacity(mobs.len());
        let mut by_type: HashMap<u16, Vec<usize>> = HashMap::new();
        for (i, m) in mobs.iter().enumerate() {
            index.entry(m.uuid).or_insert(i);
            by_type.entry(m.type_id).or_default().push(i);
        }
        let grid = (mobs.len() >= grid::THRESHOLD)
            .then(|| Grid::new(mobs.iter().map(SensedMob::bounding_box)));
        Sensing {
            players,
            items,
            mobs,
            index,
            by_type,
            grid,
        }
    }

    /// `World.mob_list/1`: the section's mobs as sensed now.
    pub fn mobs(&self) -> &[SensedMob<X>] {
        &self.mobs
    }

    /// `World.mobs_of/2`.
    pub fn mobs_of(&self, type_id: u16) -> impl Iterator<Item = &SensedMob<X>> {
        self.by_type
            .get(&type_id)
            .into_iter()
            .flatten()
            .map(|&i| &self.mobs[i])
    }

    /// The section-order index of mob `uuid`.
    pub fn position_of(&self, uuid: &Uuid) -> Option<usize> {
        self.index.get(uuid).copied()
    }

    pub fn mob(&self, uuid: &Uuid) -> Option<&SensedMob<X>> {
        self.position_of(uuid).map(|i| &self.mobs[i])
    }

    /// `World.entity/2`: the entity a reference names, if still there.
    pub fn entity(&self, r: &Ref) -> Option<Entity<'_, X>> {
        match r.kind {
            Kind::Player => self
                .players
                .iter()
                .find(|p| p.uuid == r.uuid)
                .map(Entity::Player),
            Kind::Mob => self.mob(&r.uuid).map(Entity::Mob),
            Kind::Item => self
                .items
                .iter()
                .find(|i| i.uuid == r.uuid)
                .map(Entity::Item),
        }
    }

    /// `World.resense/3`: mob `uuid` sensed as `change` changes it, for the
    /// rest of the tick (false where it is not sensed).
    pub fn resense(&mut self, uuid: &Uuid, change: impl FnOnce(&mut SensedMob<X>)) -> bool {
        let Some(i) = self.position_of(uuid) else {
            return false;
        };
        change(&mut self.mobs[i]);
        if let Some(grid) = &mut self.grid {
            grid.put(i, &self.mobs[i].bounding_box());
        }
        true
    }

    /// `World.mobs_in/3`: the indexes of the mobs `select` takes whose box
    /// meets `b`, in section order.
    pub fn mobs_in(&self, select: &Select, b: &Aabb) -> Vec<usize> {
        let meets = |i: &usize| {
            let m = &self.mobs[*i];
            select.keeps(m.type_id) && intersects(&m.bounding_box(), b)
        };
        let candidates = self.grid.as_ref().and_then(|g| g.candidates(b));
        match candidates {
            Some(c) => c.into_iter().filter(meets).collect(),
            None => (0..self.mobs.len()).filter(meets).collect(),
        }
    }

    /// The mob at a section-order index.
    pub fn mob_at(&self, i: usize) -> &SensedMob<X> {
        &self.mobs[i]
    }

    /// `World.target/1`: the mind's target while valid (`asValidTarget`):
    /// not a creative or spectator player, one the mob can attack.
    pub fn target<S: Seer<X>>(
        &self,
        level: &Level,
        seer: &S,
        target: Option<&Ref>,
    ) -> Option<Entity<'_, X>> {
        let entity = self.entity(target?)?;
        if matches!(
            entity.mode(),
            Some(GameMode::Creative | GameMode::Spectator)
        ) {
            return None;
        }
        can_attack(level, seer, entity).then_some(entity)
    }
}

/// `canBeSeenByAnyone`: alive and not a spectator.
fn seen<X>(target: Entity<'_, X>) -> bool {
    target.alive() && target.mode() != Some(GameMode::Spectator)
}

/// `Mob.canAttack` (`World.can_attack?/2`): players only while not peaceful,
/// one seen as an enemy, never a ghast, and the family's own rule.
pub fn can_attack<X, S: Seer<X>>(level: &Level, seer: &S, target: Entity<'_, X>) -> bool {
    let ghast = level.facts.entities.id("minecraft:ghast");
    !(target.kind() == Kind::Player && level.difficulty == Difficulty::Peaceful)
        && !target.invulnerable()
        && seen(target)
        && (target.type_id().is_none() || target.type_id() != ghast)
        && seer.can_attack_hook(target)
}

/// `LivingEntity.getVisibilityPercent` of `target` for a mob of type
/// `type_id` (`World.visibility/2`): crouching, invisibility under its armor
/// cover, and worn items that hide their wearer from the type.
pub fn visibility<X>(level: &Level, target: Entity<'_, X>, type_id: u16) -> f64 {
    let Entity::Player(p) = target else {
        return 1.0;
    };
    let mut v = 1.0f64;
    if p.crouching {
        v *= 0.8;
    }
    if p.invisible {
        v = v * 0.7 * p.armor_cover.max(0.1f32 as f64);
    }
    for (slot, item) in EQUIPMENT.iter().zip(&p.equipment) {
        if let Some(hidden) = item.and_then(|i| level.facts.ai.visibility.get(&i)) {
            if hidden.slot == *slot && hidden.types.contains(&type_id) {
                v *= hidden.visibility;
            }
        }
    }
    v.clamp(0.0, 10.0)
}

/// `distanceToSqr` from the seer's feet to a point.
pub fn distance_sq(from: [f64; 3], to: [f64; 3]) -> f64 {
    let d = [from[0] - to[0], from[1] - to[1], from[2] - to[2]];
    d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
}

/// `World.sees?/2`: line of sight from the seer's eye to the target's,
/// cached in its mind for the tick.
pub fn sees<X, S: Seer<X>>(level: &Level, seer: &mut S, target: Entity<'_, X>) -> bool {
    let key = target.reference();
    if let Some(seen) = seer.sight().get(&key) {
        return seen;
    }
    let seen = line_of_sight(level, seer, target);
    seer.sight().put(key, seen);
    seen
}

/// `World.line_of_sight?/2` (uncached).
pub fn line_of_sight<X, S: Seer<X>>(level: &Level, seer: &S, target: Entity<'_, X>) -> bool {
    let p = seer.position();
    let t = target.position();
    sight::line_of_sight(
        level,
        [p[0], seer.eye_y(), p[2]],
        [t[0], target.eye_y(), t[2]],
    )
}

/// `TargetingConditions.test(level, self, target)` (`World.test/3`).
pub fn test<X, S: Seer<X>>(
    level: &Level,
    seer: &mut S,
    target: Entity<'_, X>,
    conditions: &Conditions<X, S>,
) -> bool {
    if target.uuid() == seer.uuid() || !seen(target) {
        return false;
    }
    if let Some(select) = conditions.select {
        if !select(target, seer) {
            return false;
        }
    }
    if conditions.combat && !can_attack(level, &*seer, target) {
        return false;
    }
    if conditions.range > 0.0 {
        let modifier = if conditions.invisible {
            visibility(level, target, seer.type_id())
        } else {
            1.0
        };
        let reach = (conditions.range * modifier).max(2.0);
        if distance_sq(seer.position(), target.position()) > reach * reach {
            return false;
        }
    }
    if conditions.sight {
        return sees(level, seer, target);
    }
    true
}

/// `getNearestEntity` over `candidates` to `point`: the first nearest that
/// passes (`World.nearest/6`).
pub fn nearest<'a, X: 'a, S: Seer<X>>(
    level: &Level,
    seer: &mut S,
    candidates: impl IntoIterator<Item = Entity<'a, X>>,
    conditions: &Conditions<X, S>,
    point: [f64; 3],
) -> Option<Entity<'a, X>> {
    let mut best = None;
    let mut distance = -1.0f64;
    for candidate in candidates {
        if test(level, seer, candidate, conditions) {
            let c = candidate.position();
            let d = [c[0] - point[0], c[1] - point[1], c[2] - point[2]];
            let d = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
            if distance == -1.0 || d < distance {
                best = Some(candidate);
                distance = d;
            }
        }
    }
    best
}

/// `ServerLevel.getNearestPlayer(conditions, self, x, y, z)`.
pub fn nearest_player<'a, X, S: Seer<X>>(
    level: &Level,
    sensing: &'a Sensing<X>,
    seer: &mut S,
    conditions: &Conditions<X, S>,
    point: [f64; 3],
) -> Option<&'a SensedPlayer> {
    let players = sensing.players.iter().map(Entity::Player);
    match nearest(level, seer, players, conditions, point)? {
        Entity::Player(p) => Some(p),
        _ => None,
    }
}

/// `World.nearest_mob/6`: the nearest of the section's mobs `select` takes
/// whose box meets `b`.
pub fn nearest_mob<'a, X, S: Seer<X>>(
    level: &Level,
    sensing: &'a Sensing<X>,
    seer: &mut S,
    select: &Select,
    b: &Aabb,
    conditions: &Conditions<X, S>,
    point: [f64; 3],
) -> Option<&'a SensedMob<X>> {
    let candidates = sensing
        .mobs_in(select, b)
        .into_iter()
        .map(|i| Entity::Mob(sensing.mob_at(i)));
    match nearest(level, seer, candidates, conditions, point)? {
        Entity::Mob(m) => Some(m),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
