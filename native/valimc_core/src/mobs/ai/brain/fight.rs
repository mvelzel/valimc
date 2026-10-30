//! Brain behaviours of fighting and of the memories around it
//! (`Valimc.AI.Behaviors.Fight`), as vanilla's `ai.behavior` classes build
//! them: `StartAttacking`, `StopAttackingIfTargetInvalid`,
//! `SetWalkTargetFromAttackTargetIfTargetOutOfReach`, `MeleeAttack` (a hit
//! through `doHurtTarget`, an `Attack` effect with a main-hand swing),
//! `CopyMemoryWithExpiry`, `EraseMemoryIf`, `SetWalkTargetAwayFrom`,
//! `GoToTargetLocation`, `StartCelebratingIfTargetDead` and
//! `StopBeingAngryIfTargetDead`.

use super::behavior::{one_shot, Behavior, Trigger};
use super::behaviors::{
    distance_sq, flee, leading, look_at_entity, position, walk, walk_to_entity, Speed, Test,
};
use super::sensors::visible_contains;
use super::{Cond, Conds, Mem, MemValue, Tracker};
use crate::mobs::ai::fmath::{self, f};
use crate::mobs::ai::goals::melee_attack::within_reach;
use crate::mobs::ai::hooks::item_id;
use crate::mobs::ai::turn::{Seen, Turn};
use crate::mobs::ai::Effect;
use crate::mobs::model::{Hand, Slot};

use Cond::{Absent, Present, Registered};

/// `StartAttacking.create(condition, finder)`: with no attack target, a
/// target the finder (its family's, `tag`) gives that the mob can attack.
#[derive(Clone, Debug, PartialEq)]
pub struct StartAttacking {
    pub condition: Test,
    pub finder: u32,
}

pub fn start_attacking(condition: Test, finder: u32) -> Box<dyn Behavior> {
    one_shot(StartAttacking { condition, finder })
}

impl Trigger for StartAttacking {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Absent),
            (Mem::CantReachWalkTargetSince, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if !self.condition.holds(t) {
            return false;
        }
        let Some(target) = t.family().and_then(|fam| fam.find(t, self.finder)) else {
            return false;
        };
        if t.can_attack(&target.reference) {
            t.remember(Mem::AttackTarget, MemValue::Ref(target.reference));
            t.forget(Mem::CantReachWalkTargetSince);
            true
        } else {
            false
        }
    }
}

/// `StopAttackingIfTargetInvalid.create(stopWhen)`: the target is dropped
/// when it cannot be attacked, has not been reached for 200 ticks (when
/// `tired`), is dead or gone, or its family's stop test (`stop_when`) says
/// so; its family's `on_stop` runs first.
#[derive(Clone, Debug, PartialEq)]
pub struct StopIfInvalid {
    pub stop_when: Option<u32>,
    pub tired: bool,
    pub on_stop: Option<u32>,
}

pub fn stop_if_invalid(
    stop_when: Option<u32>,
    tired: bool,
    on_stop: Option<u32>,
) -> Box<dyn Behavior> {
    one_shot(StopIfInvalid {
        stop_when,
        tired,
        on_stop,
    })
}

fn tired(t: &Turn) -> bool {
    t.mem_int(Mem::CantReachWalkTargetSince)
        .is_some_and(|since| t.level.time - since > 200)
}

impl Trigger for StopIfInvalid {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Present),
            (Mem::CantReachWalkTargetSince, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let target = t.remembered(Mem::AttackTarget);
        let keep = match &target {
            None => false,
            Some(e) if !t.can_attack(&e.reference) => false,
            Some(_) if self.tired && tired(t) => false,
            Some(e) if !e.alive => false,
            Some(e) => match self.stop_when {
                None => true,
                Some(tag) => !t.family().is_some_and(|fam| fam.stop_when(t, tag, e)),
            },
        };
        if !keep {
            if let Some(tag) = self.on_stop {
                if let Some(fam) = t.family() {
                    fam.on_stop(t, tag, target.as_ref());
                }
            }
            t.forget(Mem::AttackTarget);
        }
        true
    }
}

/// `SetWalkTargetFromAttackTargetIfTargetOutOfReach.create(speed)`: a target
/// in sight within reach needs no walk; else look at it and walk to it.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkToTarget {
    pub speed: Speed,
}

pub fn walk_to_target(speed: Speed) -> Box<dyn Behavior> {
    one_shot(WalkToTarget { speed })
}

impl Trigger for WalkToTarget {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::WalkTarget, Registered),
            (Mem::LookTarget, Registered),
            (Mem::AttackTarget, Present),
            (Mem::NearestVisibleLivingEntities, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(target) = t.remembered(Mem::AttackTarget) else {
            return true;
        };
        let visible =
            t.has(Mem::NearestVisibleLivingEntities) && visible_contains(t, &target.reference);
        if visible && within_attack_range(t, &target, 1) {
            t.forget(Mem::WalkTarget);
        } else {
            look_at_entity(t, target.reference);
            let speed = self.speed.get(t);
            walk_to_entity(t, target.reference, speed, 0);
        }
        true
    }
}

fn held(t: &Turn) -> [Option<i32>; 2] {
    let e = &t.mob.body.mob.equipment;
    [
        e.get(Slot::Mainhand).and_then(item_id),
        e.get(Slot::Offhand).and_then(item_id),
    ]
}

fn item(t: &Turn, name: &str) -> Option<i32> {
    t.level.facts.items.names.id(name).map(|i| i as i32)
}

/// `BehaviorUtils.isWithinAttackRange(body, target, buffer)`: a mob holding
/// a projectile weapon within its range less `buffer`, else within melee
/// reach.
pub fn within_attack_range(t: &Turn, target: &Seen, buffer: i32) -> bool {
    let hands = held(t);
    let holds = |name: &str| {
        let id = item(t, name);
        id.is_some() && hands.contains(&id)
    };
    // `ProjectileWeaponItem.getDefaultProjectileRange`.
    let range = if holds("minecraft:crossbow") {
        Some(8)
    } else if holds("minecraft:bow") {
        Some(15)
    } else {
        None
    };
    match range {
        None => within_reach(t, target),
        Some(range) => {
            let r = (range - buffer) as f64;
            distance_sq(t, target) <= r * r
        }
    }
}

/// `isHoldingUsableNonMeleeWeapon`: a hand holds what its type can use
/// that way (`canUseNonMeleeWeapon`): a piglin's crossbow or a weapon with
/// the kinetic weapon component (a spear); none for other mobs.
pub(crate) fn non_melee(t: &Turn) -> bool {
    if t.mob.body.entity_type != "minecraft:piglin" {
        return false;
    }
    let crossbow = item(t, "minecraft:crossbow");
    let equipment = &t.mob.body.mob.equipment;
    [Slot::Mainhand, Slot::Offhand].iter().any(|&slot| {
        let Some(stack) = equipment.get(slot) else {
            return false;
        };
        let id = item_id(stack);
        id.is_some() && (id == crossbow || kinetic(t, stack))
    })
}

/// `ItemStack.has(DataComponents.KINETIC_WEAPON)`: its own component, else
/// its item's stock one, unless the stack removes it.
fn kinetic(t: &Turn, stack: &crate::mobs::term::Value) -> bool {
    use crate::mobs::living::items;
    const KINETIC: &str = "minecraft:kinetic_weapon";
    if items::removed(stack, KINETIC) {
        return false;
    }
    items::component(stack, KINETIC).is_some()
        || t.ctx
            .as_ref()
            .zip(items::item_id(stack))
            .is_some_and(|(ctx, id)| ctx.rules.living.item(id).kinetic_default)
}

/// `MeleeAttack.create(predicate, cooldown)`: a target in sight within
/// reach, while not holding a weapon it shoots with: a main-hand swing, the
/// hit, and `cooldown` ticks before the next.
#[derive(Clone, Debug, PartialEq)]
pub struct Melee {
    pub test: Test,
    pub cooldown: i64,
}

pub fn melee(test: Test, cooldown: i64) -> Box<dyn Behavior> {
    one_shot(Melee { test, cooldown })
}

impl Trigger for Melee {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::LookTarget, Registered),
            (Mem::AttackTarget, Present),
            (Mem::AttackCoolingDown, Absent),
            (Mem::NearestVisibleLivingEntities, Present),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some(target) = t.remembered(Mem::AttackTarget) else {
            return false;
        };
        if !(self.test.holds(t) && !non_melee(t) && within_reach(t, &target)) {
            return false;
        }
        if !visible_contains(t, &target.reference) {
            return false;
        }
        let r = target.reference;
        look_at_entity(t, r);
        t.swing(Hand::MainHand);
        t.effect(Effect::Attack(r));
        let hooks = t.hooks;
        hooks.hit(t, &target);
        t.melee(&r);
        t.remember_for(Mem::AttackCoolingDown, MemValue::True, self.cooldown);
        true
    }
}

/// `BehaviorUtils.isOtherTargetMuchFurtherAwayThanCurrentAttackTarget`.
pub fn much_farther(t: &Turn, other: &Seen, by: f64) -> bool {
    match t.remembered(Mem::AttackTarget) {
        None => false,
        Some(current) => distance_sq(t, other) > distance_sq(t, &current) + by * by,
    }
}

/// `CopyMemoryWithExpiry.create(predicate, source, target, {min, max})`.
#[derive(Clone, Debug, PartialEq)]
pub struct CopyWithExpiry {
    pub test: Test,
    pub source: Mem,
    pub target: Mem,
    pub min: i32,
    pub max: i32,
}

pub fn copy_with_expiry(
    test: Test,
    source: Mem,
    target: Mem,
    min: i32,
    max: i32,
) -> Box<dyn Behavior> {
    one_shot(CopyWithExpiry {
        test,
        source,
        target,
        min,
        max,
    })
}

impl Trigger for CopyWithExpiry {
    fn conditions(&self) -> Conds {
        Conds::new(&[(self.source, Present), (self.target, Absent)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if !self.test.holds(t) {
            return false;
        }
        let n = t.level_int(self.max - self.min + 1);
        if let Some(v) = t.memory(self.source).cloned() {
            t.remember_for(self.target, v, (self.min + n) as i64);
        }
        true
    }
}

/// `EraseMemoryIf.create(predicate, memory)`.
#[derive(Clone, Debug, PartialEq)]
pub struct EraseIf {
    pub test: Test,
    pub memory: Mem,
}

pub fn erase_if(test: Test, memory: Mem) -> Box<dyn Behavior> {
    one_shot(EraseIf { test, memory })
}

impl Trigger for EraseIf {
    fn conditions(&self) -> Conds {
        Conds::new(&[(self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if self.test.holds(t) {
            t.forget(self.memory);
            true
        } else {
            false
        }
    }
}

/// What a walk away avoids: a remembered block's bottom center, or a
/// remembered entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Away {
    Pos,
    Entity,
}

/// `SetWalkTargetAwayFrom.pos` or `.entity`: within `distance` of what
/// `memory` holds, a land target 16 blocks away from it (ten tries), unless
/// walking already (`interrupt` false) or walking away at the same speed.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkAway {
    pub memory: Mem,
    pub kind: Away,
    pub speed: f64,
    pub distance: f64,
    pub interrupt: bool,
}

pub fn walk_away(
    memory: Mem,
    kind: Away,
    speed: f64,
    distance: i32,
    interrupt: bool,
) -> Box<dyn Behavior> {
    one_shot(walk_away_trigger(memory, kind, speed, distance, interrupt))
}

/// `walk_away/5`'s trigger (for `trigger_if`).
pub fn walk_away_trigger(
    memory: Mem,
    kind: Away,
    speed: f64,
    distance: i32,
    interrupt: bool,
) -> WalkAway {
    WalkAway {
        memory,
        kind,
        speed: f(speed),
        distance: distance as f64,
        interrupt,
    }
}

impl Trigger for WalkAway {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::WalkTarget, Registered), (self.memory, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let walk = t.mem_walk();
        let avoid = match self.kind {
            Away::Pos => t
                .mem_pos(self.memory)
                .map(|[x, y, z]| [x as f64 + 0.5, y as f64, z as f64 + 0.5]),
            Away::Entity => t.remembered(self.memory).map(|e| e.position),
        };
        let Some(avoid) = avoid else { return false };
        if walk.is_some() && !self.interrupt {
            return false;
        }
        if t.distance_sq(avoid) >= self.distance * self.distance {
            return false;
        }
        if let Some(w) = walk {
            if w.speed == self.speed && leading(t, &w, avoid) < 0.0 {
                return false;
            }
        }
        flee(t, avoid, self.speed, 10);
        true
    }
}

/// `GoToTargetLocation.create(memory, close, speed)`: unless close enough to
/// the location, walk and look at a block next to it (offsets from the
/// level's random).
#[derive(Clone, Debug, PartialEq)]
pub struct GoToLocation {
    pub memory: Mem,
    pub close: i32,
    pub speed: f64,
}

pub fn go_to_location(memory: Mem, close: i32, speed: f64) -> GoToLocation {
    GoToLocation {
        memory,
        close,
        speed: f(speed),
    }
}

impl Trigger for GoToLocation {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (self.memory, Present),
            (Mem::AttackTarget, Absent),
            (Mem::WalkTarget, Absent),
            (Mem::LookTarget, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        let Some([x, y, z]) = t.mem_pos(self.memory) else {
            return false;
        };
        let [bx, by, bz] = t.block();
        let d = (x - bx) * (x - bx) + (y - by) * (y - by) + (z - bz) * (z - bz);
        if d < self.close * self.close {
            return true;
        }
        let dx = t.level_int(3);
        let dz = t.level_int(3);
        let tracker = Tracker::block([x + dx - 1, y, z + dz - 1]);
        t.remember(Mem::WalkTarget, walk(tracker, self.speed, self.close));
        t.remember(Mem::LookTarget, MemValue::Tracker(tracker));
        true
    }
}

/// `StartCelebratingIfTargetDead.create(duration, dance)`: a dead attack
/// target is celebrated where it fell for `duration` ticks (dancing too if
/// its family's dance says so), and forgotten.
#[derive(Clone, Debug, PartialEq)]
pub struct CelebrateIfTargetDead {
    pub duration: i64,
}

pub fn celebrate_if_target_dead(duration: i64) -> Box<dyn Behavior> {
    one_shot(CelebrateIfTargetDead { duration })
}

impl Trigger for CelebrateIfTargetDead {
    fn conditions(&self) -> Conds {
        Conds::new(&[
            (Mem::AttackTarget, Present),
            (Mem::AngryAt, Registered),
            (Mem::CelebrateLocation, Absent),
            (Mem::Dancing, Registered),
        ])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        match t.remembered(Mem::AttackTarget) {
            Some(target) if !target.alive => {
                let dances = t.family().is_some_and(|fam| fam.dance(t, &target));
                if dances {
                    t.remember_for(Mem::Dancing, MemValue::True, self.duration);
                }
                let at = fmath::block(target.position);
                t.remember_for(Mem::CelebrateLocation, MemValue::Pos(at), self.duration);
                t.forget(Mem::AttackTarget);
                t.forget(Mem::AngryAt);
                true
            }
            _ => false,
        }
    }
}

/// `StopBeingAngryIfTargetDead.create()`: anger at a dead entity ends.
#[derive(Clone, Debug, PartialEq)]
pub struct StopAngryIfTargetDead;

pub fn stop_angry_if_target_dead() -> Box<dyn Behavior> {
    one_shot(StopAngryIfTargetDead)
}

impl Trigger for StopAngryIfTargetDead {
    fn conditions(&self) -> Conds {
        Conds::new(&[(Mem::AngryAt, Present)])
    }

    fn trigger(&mut self, t: &mut Turn) -> bool {
        if t.remembered(Mem::AngryAt).is_some_and(|e| !e.alive) {
            t.forget(Mem::AngryAt);
        }
        true
    }
}

/// The position a walk target leads to now (`Behaviors.position/2`).
pub fn walk_position(t: &Turn) -> Option<[f64; 3]> {
    t.mem_walk().and_then(|w| position(t, &w.target))
}
