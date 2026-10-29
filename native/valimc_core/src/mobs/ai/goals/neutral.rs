//! Vanilla's `NeutralMob` (`Valimc.AI.Neutral`): a mob that stays angry for
//! a while at whoever it targets, and forgives. Its state is the mind's
//! `own.anger`: the game time the anger ends (-1 for none) and whom it is
//! angry at. A type passes its persistent anger range (`{min, max}` ticks).
//! `ResetUniversalAngerTargetGoal` is its goal.

use crate::mobs::ai::goal::Goal;
use crate::mobs::ai::mind::Anger;
use crate::mobs::ai::turn::{Eyes, Seen, Turn};
use crate::mobs::ai::Extra;
use crate::mobs::level::{Difficulty, Level};
use crate::mobs::sensing::{self, Entity, GameMode, Kind, Ref};

fn own(t: &Turn) -> Anger {
    t.mind.own.anger.unwrap_or_default()
}

fn put(t: &mut Turn, f: impl FnOnce(&mut Anger)) {
    let mut anger = own(t);
    f(&mut anger);
    t.mind.own.anger = Some(anger);
}

/// `isAngry`: its anger ends later than now.
pub fn angry(t: &Turn) -> bool {
    let end = own(t).end;
    end > 0 && end - t.level.time > 0
}

/// `startPersistentAngerTimer`: angry for a uniform draw of `range` ticks.
pub fn start_timer(t: &mut Turn, (min, max): (i64, i64)) {
    let n = t.int((max - min + 1) as i32) as i64;
    let end = t.level.time + min + n;
    put(t, |a| a.end = end);
}

/// `stopBeingAngry`: no attacker, no anger, no target.
pub fn stop(t: &mut Turn) {
    t.mind.hurt_by = None;
    put(t, |a| {
        a.target = None;
        a.end = -1;
    });
    t.set_target(None);
}

fn valid_player(level: &Level, target: &Seen) -> bool {
    target.kind() == Kind::Player
        && !super::exempt(target.mode)
        && level.difficulty != Difficulty::Peaceful
}

/// `updatePersistentAnger` (`stay`: renew the timer every tick).
pub fn update(t: &mut Turn, stay: bool, range: (i64, i64)) {
    let previous = t.entity(t.mind.target.as_ref());
    let angry_at = own(t).target;
    if let Some(p) = previous {
        if !p.alive && angry_at == Some(p.reference) && p.kind() == Kind::Mob {
            stop(t);
            return;
        }
    }
    let target = t.target();
    if let Some(target) = target {
        let fresh = angry_at != Some(target.reference);
        if fresh {
            put(t, |a| a.target = Some(target.reference));
        }
        if fresh || stay {
            start_timer(t, range);
        }
    }
    if angry_at.is_some()
        && !angry(t)
        && (target.is_none_or(|tg| !valid_player(t.level, &tg)) || !stay)
    {
        stop(t);
    }
    match t.entity(angry_at.as_ref()) {
        Some(e) if e.kind() == Kind::Player && super::exempt(e.mode) => stop(t),
        Some(e) if e.kind() == Kind::Player && t.level.difficulty == Difficulty::Peaceful => {
            stop(t)
        }
        _ => {}
    }
}

/// `isAngryAt`: a target it can attack that it is angry at, or any player
/// while universally angry (`Neutral.angry_at?/2` as a target selector).
pub fn angry_at(level: &Level, eyes: &Eyes, target: Entity<'_, Extra>) -> bool {
    let anger = eyes.own.anger.unwrap_or_default();
    let angry = anger.end > 0 && anger.end - level.time > 0;
    let all = level.rules.universal_anger && angry && anger.target.is_none();
    let player = match target {
        Entity::Player(p) => {
            !matches!(p.mode, GameMode::Creative | GameMode::Spectator)
                && level.difficulty != Difficulty::Peaceful
        }
        _ => false,
    };
    sensing::can_attack(level, eyes, target)
        && ((player && all) || (anger.target.is_some() && anger.target == Some(target.reference())))
}

/// `forgetCurrentTargetAndRefreshUniversalAnger`.
pub fn refresh(t: &mut Turn, range: (i64, i64)) {
    stop(t);
    start_timer(t, range);
}

/// `ResetUniversalAngerTargetGoal`: under universal anger, a hurt by a
/// player makes a neutral mob forget its target and be angry at every
/// player.
#[derive(Clone, Debug, PartialEq)]
pub struct ResetUniversalAnger {
    pub range: (i64, i64),
    pub last: i64,
}

impl ResetUniversalAnger {
    pub fn new(range: (i64, i64)) -> ResetUniversalAnger {
        ResetUniversalAnger { range, last: 0 }
    }
}

impl Goal for ResetUniversalAnger {
    fn can_use(&mut self, t: &mut Turn) -> bool {
        match t.mind.hurt_by {
            Some((
                Ref {
                    kind: Kind::Player, ..
                },
                at,
            )) => t.level.rules.universal_anger && at > self.last,
            _ => false,
        }
    }

    fn start(&mut self, t: &mut Turn) {
        if let Some((_, at)) = t.mind.hurt_by {
            self.last = at;
        }
        refresh(t, self.range);
    }

    fn name(&self) -> &'static str {
        "Valimc.AI.Goals.ResetUniversalAnger"
    }
}
