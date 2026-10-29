//! `Valimc.Living.Health` (and `Living.die`, `Freezing.tick`): health, its
//! hurt timers and the golden-heart absorption pool. Values are canonical
//! Java floats held as `f64`.

use super::super::model::{Freezing, Health, Living};
use super::{emax, emin, f};

/// `Health.tick/1`: the hurt and cooldown timers run down; a dead body's
/// death timer runs up to 20.
pub fn tick(h: &mut Health) {
    h.hurt_ticks = (h.hurt_ticks - 1).max(0);
    h.cooldown = (h.cooldown - 1).max(0);
    if h.value <= 0.0 {
        h.death_ticks = (h.death_ticks + 1).min(20);
    }
}

/// `Health.set/2`: the value as a float, within 0 and the maximum.
pub fn set(h: &mut Health, value: f64) {
    h.value = emin(emax(f(value), 0.0), f(h.maximum));
}

/// `Health.heal/2`: float healing (signed), never reviving the dead.
pub fn heal(h: &mut Health, amount: f64) {
    if h.value > 0.0 {
        let value = f(h.value + f(amount));
        set(h, value);
    }
}

/// `Health.reduce/2`: already resolved damage.
pub fn reduce(h: &mut Health, amount: f64) {
    let value = f(h.value - f(amount));
    set(h, value);
}

/// `Health.hurt_window/3`'s choice: whether it takes the hit, the damage
/// selected and whether it is a full hit (the hurt animation).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Selected {
    pub accepted: bool,
    pub damage: f64,
    pub notify: bool,
}

/// `Health.hurt_window/3`: the health state after selecting `amount`
/// (blocking already applied) and the selection.
pub fn hurt_window(h: &Health, amount: f64, bypass_cooldown: bool) -> (Health, Selected) {
    let amount = emax(0.0, f(amount));
    let protected = h.cooldown > 10 && !bypass_cooldown;
    if h.value <= 0.0 || (protected && amount <= h.last_hurt) {
        let none = Selected {
            accepted: false,
            damage: 0.0,
            notify: false,
        };
        (h.clone(), none)
    } else if protected {
        let damage = f(amount - h.last_hurt);
        let mut next = h.clone();
        next.last_hurt = amount;
        (
            next,
            Selected {
                accepted: true,
                damage,
                notify: false,
            },
        )
    } else {
        let mut next = h.clone();
        next.last_hurt = amount;
        next.cooldown = 20;
        next.hurt_ticks = 10;
        (
            next,
            Selected {
                accepted: true,
                damage: amount,
                notify: true,
            },
        )
    }
}

/// `Health.set_absorption/2`.
pub fn set_absorption(amount: f64, maximum: f64) -> f64 {
    emin(f(maximum), emax(0.0, f(amount)))
}

/// `Health.spend_absorption/2`: `(pool, damage left)`.
pub fn spend_absorption(pool: f64, damage: f64) -> (f64, f64) {
    let pool = f(pool);
    let damage = f(damage);
    let remaining = emax(0.0, f(damage - pool));
    let consumed = f(damage - remaining);
    (emax(0.0, f(pool - consumed)), remaining)
}

/// `Freezing.tick/2` (the body's clock).
pub fn freezing_tick(freezing: &mut Freezing, alive: bool) {
    if alive {
        let phase = (freezing.damage_phase + 1) % 40;
        freezing.damage_phase = phase;
        freezing.damage_due = freezing.damage_due || phase == 0;
    } else {
        freezing.damage_phase = 0;
        freezing.damage_due = false;
    }
}

/// `Living.die/1`: burning stops (a cooldown is kept) and the freezing
/// clock resets.
pub fn die(living: &mut Living) {
    living.fire_ticks = living.fire_ticks.min(0);
    freezing_tick(&mut living.freezing, false);
}
