//! The target goals (`Goals.Target`, `Goals.NearestAttackableTarget`,
//! `Goals.HurtByTarget`). `TargetGoal`'s common part keeps a target while it
//! can be attacked, within the follow range and, for a goal that must see
//! it, seen at least once every `unseen` ticks (halved: target goals update
//! every other tick).

use super::{MobTypes, TargetTest};
use crate::mobs::ai::effect::Effect;
use crate::mobs::ai::fmath::reduced;
use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::hooks::Tag;
use crate::mobs::ai::turn::{Eyes, Kinds, Seen, Targeting, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::level::{Difficulty, Level};
use crate::mobs::sensing::{inflate, intersects, Entity, Kind, Ref};
use crate::physics::Aabb;

/// The fields every target goal's state has.
#[derive(Clone, Debug, PartialEq)]
pub struct TargetFields {
    pub must_see: bool,
    pub target: Option<Ref>,
    pub unseen_ticks: i64,
    pub unseen: i64,
}

impl TargetFields {
    pub fn new(must_see: bool) -> TargetFields {
        TargetFields {
            must_see,
            target: None,
            unseen_ticks: 0,
            unseen: 60,
        }
    }

    /// `TargetGoal.canContinueToUse`.
    pub fn can_continue(&mut self, t: &mut Turn) -> bool {
        let target = t.target().or_else(|| t.entity(self.target.as_ref()));
        let Some(target) = target else {
            return false;
        };
        if !t.can_attack(&target.reference) {
            return false;
        }
        let follow = follow(t);
        if t.distance_sq(target.position) > follow * follow {
            return false;
        }
        if self.must_see {
            if t.sees(&target.reference) {
                self.unseen_ticks = 0;
            } else {
                self.unseen_ticks += 1;
                if self.unseen_ticks > reduced(self.unseen) {
                    return false;
                }
            }
        }
        t.set_target(Some(target.reference));
        true
    }

    /// `TargetGoal.start`.
    pub fn start(&mut self) {
        self.unseen_ticks = 0;
    }

    /// `TargetGoal.stop`.
    pub fn stop(&mut self, t: &mut Turn) {
        self.target = None;
        t.set_target(None);
    }
}

/// `getFollowDistance`: the mob's follow range.
pub fn follow(t: &Turn) -> f64 {
    t.attribute("minecraft:follow_range")
}

/// What a nearest-attackable-target goal looks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TargetKind {
    Player,
    Mob,
    /// Either (a guardian's): its players within the search box.
    Living,
}

/// `NearestAttackableTargetGoal`: by chance (one in five updates by
/// default), the nearest attackable entity within the follow range, in
/// sight, measured from the mob's eye.
#[derive(Clone, Debug, PartialEq)]
pub struct NearestAttackableTarget {
    pub fields: TargetFields,
    pub kind: TargetKind,
    pub select: Option<MobTypes>,
    pub selector: Option<TargetTest>,
    pub interval: i64,
    pub peaceful: bool,
    /// A condition on the mob before it looks at all.
    pub when: Option<Tag>,
    pub found: Option<Ref>,
}

/// `NearestAttackableTarget.new/4`'s options.
#[derive(Clone, Debug, PartialEq)]
pub struct TargetOptions {
    pub selector: Option<TargetTest>,
    pub interval: i64,
    pub peaceful: bool,
    pub when: Option<Tag>,
}

impl Default for TargetOptions {
    fn default() -> TargetOptions {
        TargetOptions {
            selector: None,
            interval: 10,
            peaceful: true,
            when: None,
        }
    }
}

impl NearestAttackableTarget {
    pub fn new(
        kind: TargetKind,
        select: Option<MobTypes>,
        must_see: bool,
        o: TargetOptions,
    ) -> NearestAttackableTarget {
        NearestAttackableTarget {
            fields: TargetFields::new(must_see),
            kind,
            select,
            selector: o.selector,
            interval: reduced(o.interval),
            peaceful: o.peaceful,
            when: o.when,
            found: None,
        }
    }

    fn find(&self, t: &mut Turn) -> Option<Seen> {
        let follow = follow(t);
        let selector = self.selector.as_ref();
        let pick = |level: &Level, eyes: &Eyes, e: Entity<'_, Extra>| {
            selector.is_none_or(|s| s.test(level, eyes, e))
        };
        let mut targeting = Targeting::new(true).range(follow);
        if self.selector.is_some() {
            targeting = targeting.select(&pick);
        }
        let point = [t.x(), t.eye_y(), t.z()];
        let b = inflate(&t.bbox(), follow, follow, follow);
        let kinds = self.select.as_ref().map_or(Kinds::Any, MobTypes::kinds);
        match self.kind {
            TargetKind::Player => t.nearest_player(&targeting, point),
            TargetKind::Mob => t.nearest_mob(kinds, &b, &targeting, point),
            TargetKind::Living => {
                let players = |_: &Level, e: Entity<'_, Extra>| intersects(&e.bounding_box(), &b);
                t.nearest_living(players, kinds, &b, &targeting, point)
            }
        }
    }

    fn usable(&mut self, t: &mut Turn) -> bool {
        let go = self.interval <= 0 || t.int(self.interval as i32) == 0;
        if !go {
            return false;
        }
        let found = self.find(t);
        self.found = found.map(|e| e.reference);
        found.is_some()
    }
}

impl Goal for NearestAttackableTarget {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        // Without `peaceful` (a shulker's) it looks for nothing on peaceful.
        if !self.peaceful && t.level.difficulty == Difficulty::Peaceful {
            return false;
        }
        if let Some(tag) = self.when {
            let hooks = t.hooks;
            if !hooks.test(t, tag) {
                return false;
            }
        }
        self.usable(t)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.fields.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        self.fields.start();
        t.set_target(self.found);
    }

    fn stop(&mut self, t: &mut Turn) {
        self.fields.stop(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.NearestAttackableTarget"
    }
}

/// `HurtByTargetGoal`: the living entity that last hurt the mob (within 100
/// ticks, once per hurt) becomes its target if it can be attacked, seen or
/// not; kept while seen at least every 300 ticks. With `alert`, the mob also
/// sets the target of each mob of `alert_types` within its follow range
/// (ten blocks up and down) that has none.
#[derive(Clone, Debug, PartialEq)]
pub struct HurtByTarget {
    pub fields: TargetFields,
    pub alert: bool,
    pub alert_types: Vec<u16>,
    pub ignore: Vec<u16>,
    pub timestamp: i64,
}

impl HurtByTarget {
    pub fn new(alert: bool, alert_types: Vec<u16>, ignore: Vec<u16>) -> HurtByTarget {
        HurtByTarget {
            fields: TargetFields::new(true),
            alert,
            alert_types,
            ignore,
            timestamp: 0,
        }
    }

    fn alert(&self, t: &mut Turn, attacker: Ref) {
        let within = follow(t);
        let [x, y, z] = t.pos();
        let b = Aabb {
            min: [x - within, y - 10.0, z - within],
            max: [x + 1.0 + within, y + 1.0 + 10.0, z + 1.0 + within],
        };
        for other in t.mobs_in(Kinds::Types(&self.alert_types), &b) {
            if other.uuid() != t.uuid && t.entity(other.target.as_ref()).is_none() {
                t.effect(Effect::Alert {
                    mob: other.uuid(),
                    target: attacker,
                });
            }
        }
    }
}

impl Goal for HurtByTarget {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        let Some((r, timestamp)) = t.mind.hurt_by else {
            return false;
        };
        if timestamp == self.timestamp {
            return false;
        }
        let Some(attacker) = t.entity(Some(&r)) else {
            return false;
        };
        if attacker.kind() == Kind::Player && t.level.rules.universal_anger {
            return false;
        }
        // Hurt by a mob of a type it ignores, it does not turn.
        if attacker.kind() == Kind::Mob
            && attacker.type_id.is_some_and(|ty| self.ignore.contains(&ty))
        {
            return false;
        }
        let targeting = Targeting::new(true).sight(false).invisible(false);
        t.test(&attacker.reference, &targeting)
    }

    fn can_continue(&mut self, t: &mut Turn) -> bool {
        self.fields.can_continue(t)
    }

    fn start(&mut self, t: &mut Turn) {
        let Some((r, timestamp)) = t.mind.hurt_by else {
            return;
        };
        t.set_target(Some(r));
        let target = t.target();
        self.fields.target = target.map(|e| e.reference);
        self.timestamp = timestamp;
        self.fields.unseen = 300;
        if self.alert {
            self.alert(t, r);
        }
        self.fields.start();
    }

    fn stop(&mut self, t: &mut Turn) {
        self.fields.stop(t);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.HurtByTarget"
    }
}
