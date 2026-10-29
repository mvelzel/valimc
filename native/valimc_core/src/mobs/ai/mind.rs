//! The live part of a mob's mind (`Valimc.AI.Mind` beyond its random and
//! saved memories): what vanilla's `Mob` keeps between ticks. A record never
//! holds it; a restored mob starts with fresh selectors drawing on.

use super::navigation::Navigation;
use super::selector::Selector;
use super::Opaque;
use crate::mobs::sensing::{Ref, SightCache};

/// `LookControl.setLookAt`'s wanted look: the point, the turn limits and
/// the ticks it lasts.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LookAt {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub y_max: f64,
    pub x_max: f64,
    pub cooldown: i32,
}

/// `LivingEntity.SwingState`: `{duration, ticks}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Swing {
    pub duration: i32,
    pub ticks: i32,
}

/// What the last hurt was (`getLastDamageSource`): the damage type's
/// registry id, the tick after it and who dealt it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Damage {
    pub source: u16,
    pub tick: i64,
    pub attacker: Option<Ref>,
}

/// `NeutralMob`'s anger (`Valimc.AI.Neutral`): the game time it ends (-1
/// for none) and whom it is angry at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Anger {
    pub end: i64,
    pub target: Option<Ref>,
}

impl Default for Anger {
    fn default() -> Anger {
        Anger {
            end: -1,
            target: None,
        }
    }
}

/// `Mind.own`: what a family keeps beyond the common state (nil in the
/// Elixir while both parts are empty): a neutral mob's anger and a family's
/// own fields.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Own {
    pub anger: Option<Anger>,
    pub family: Option<Box<dyn Opaque>>,
}

impl Own {
    /// Nothing kept (the Elixir's nil).
    pub fn is_empty(&self) -> bool {
        self.anger.is_none() && self.family.is_none()
    }

    /// A family's own fields of type `T`.
    pub fn family<T: 'static>(&self) -> Option<&T> {
        self.family.as_deref()?.as_any().downcast_ref()
    }

    pub fn family_mut<T: 'static>(&mut self) -> Option<&mut T> {
        self.family.as_deref_mut()?.as_any_mut().downcast_mut()
    }
}

/// What a brain mob reacts to before its section thinks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pending {
    /// `{:hurt_by, ref}`.
    HurtBy(Ref),
}

/// The live, unsaved state of a mind.
#[derive(Clone, Debug, PartialEq)]
pub struct MindState {
    /// `tickCount`.
    pub tick: i64,
    /// `noActionTime`.
    pub no_action: i64,
    /// `ambientSoundTime`.
    pub ambient: i64,
    pub goals: Selector,
    pub targets: Selector,
    pub target: Option<Ref>,
    pub aggressive: bool,
    pub look: Option<LookAt>,
    /// `yBodyRot`.
    pub body_yaw: f64,
    /// Where a teleport this tick left it (`{x, z}`): its body turns from
    /// there.
    pub snapped: Option<[f64; 2]>,
    pub swing: Option<Swing>,
    /// `wasTouchingWater` at its last base tick.
    pub wet: bool,
    pub stable_head: f64,
    pub stable_time: i32,
    pub navigation: Navigation,
    /// `JumpControl.jump()` this tick.
    pub jump: bool,
    /// A blaze's lift this tick.
    pub rise: bool,
    /// Who last hurt it and the tick it did.
    pub hurt_by: Option<(Ref, i64)>,
    pub damage: Option<Damage>,
    /// Lines of sight tested this tick.
    pub sight: SightCache,
    /// A brain mob's brain (memories, sensors, activities): its machinery
    /// moves with the brain families.
    pub brain: Option<Box<dyn Opaque>>,
    /// The second of a pair of gaussian draws.
    pub gaussian: Option<f64>,
    /// An animal's particle timers.
    pub forced_age_timer: i32,
    pub age_lock_timer: i32,
    /// The goal selector's disabled control flags (`goal::MOVE` ...).
    pub disabled: u8,
    pub own: Own,
    pub pending: Vec<Pending>,
}

impl Default for MindState {
    /// `%Mind{}`'s live part.
    fn default() -> MindState {
        MindState {
            tick: 0,
            no_action: 0,
            ambient: 0,
            goals: Selector::default(),
            targets: Selector::default(),
            target: None,
            aggressive: false,
            look: None,
            body_yaw: 0.0,
            snapped: None,
            swing: None,
            wet: false,
            stable_head: 0.0,
            stable_time: 0,
            navigation: Navigation::default(),
            jump: false,
            rise: false,
            hurt_by: None,
            damage: None,
            sight: SightCache::default(),
            brain: None,
            gaussian: None,
            forced_age_timer: 0,
            age_lock_timer: 0,
            disabled: 0,
            own: Own::default(),
            pending: Vec::new(),
        }
    }
}

impl MindState {
    /// A fresh mind's state with its selectors and navigation
    /// (`AI.mind/5`'s; a brain is the brain families').
    pub fn new(goals: Selector, targets: Selector, navigation: Navigation) -> MindState {
        MindState {
            goals,
            targets,
            navigation,
            ..MindState::default()
        }
    }

    /// `AI.hurt/3`: not idle, the attacker that angers it with the tick it
    /// hit, and the damage type the next tick reads.
    pub fn hurt(&mut self, attacker: Option<Ref>, source: u16) {
        self.no_action = 0;
        self.damage = Some(Damage {
            source,
            tick: self.tick + 1,
            attacker,
        });
        if let Some(a) = attacker {
            if self.brain.is_some() {
                self.pending.push(Pending::HurtBy(a));
            }
            self.hurt_by = Some((a, self.tick));
        }
    }
}
