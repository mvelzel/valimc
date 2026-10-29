//! `Valimc.Living.Burning` as mobs use it: the burning counter
//! (`remainingFireTicks`), ignition by fire and lava scaled by the burning
//! time attribute, its second-by-second damage and the ordered fire, lava
//! and extinguish operations of a move's contacts.

use super::f;
use crate::physics::player::contacts::Contact;

const MAXIMUM: i64 = i32::MAX as i64;

/// `Burning.assign/2`.
pub fn assign(ticks: i32, invulnerable: bool) -> i32 {
    if invulnerable {
        ticks.min(1)
    } else {
        ticks
    }
}

/// `Burning.clear/1`: put out (a cooldown is kept).
pub fn clear(ticks: i32) -> i32 {
    ticks.min(0)
}

/// `Burning.ignite_ticks/4`: at least `ticks` scaled by `factor`.
pub fn ignite_ticks(current: i32, ticks: i64, factor: f64, invulnerable: bool) -> i32 {
    let scaled = ((ticks as f64 * factor).ceil() as i64).min(MAXIMUM);
    if scaled > current as i64 {
        assign(scaled as i32, invulnerable)
    } else {
        current
    }
}

/// `Burning.ignite_seconds/4`.
pub fn ignite_seconds(current: i32, seconds: f64, factor: f64, invulnerable: bool) -> i32 {
    let product = f(seconds) * 20.0;
    let ticks = if product >= MAXIMUM as f64 {
        MAXIMUM
    } else {
        (f(product).floor() as i64).min(MAXIMUM)
    };
    ignite_ticks(current, ticks, factor, invulnerable)
}

/// `Burning.tick/4` (`Entity.baseTick`'s burning): the next counter and a
/// second's damage (not in lava).
pub fn tick(ticks: i32, immune: bool, lava: bool) -> (i32, f64) {
    if ticks <= 0 {
        (ticks, 0.0)
    } else if immune {
        (0, 0.0)
    } else {
        let damage = if ticks % 20 == 0 && !lava { 1.0 } else { 0.0 };
        (ticks - 1, damage)
    }
}

/// `Burning.lava/4`'s ignition: fifteen seconds (none for the immune).
pub fn lava(current: i32, immune: bool, factor: f64) -> i32 {
    if immune {
        current
    } else {
        ignite_seconds(current, 15.0, factor, false)
    }
}

/// `Burning.entity_fire/3` (`BaseFireBlock.fireIgnite` for an entity that is
/// not a player): a negative counter steps toward zero, then eight seconds
/// at least.
pub fn entity_fire(current: i32, immune: bool, factor: f64) -> i32 {
    if immune {
        return current;
    }
    let increment = if current < 0 { 1 } else { 0 };
    let next = current.wrapping_add(increment);
    if next >= 0 {
        ignite_seconds(next, 8.0, factor, false)
    } else {
        next
    }
}

/// `Burning.settle/3`: the end of `applyEffectsFromBlocks` for an entity
/// that is not a player: a counter that is not burning and was not raised
/// this tick goes back to 0.
pub fn settle(ticks: i32, before: i32, immune: bool) -> i32 {
    if (ticks > 0 && !immune) || ticks > before {
        ticks
    } else {
        0
    }
}

/// An ordered operation of a move's contacts (`Burning.plan/1`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Operation {
    ClearFreeze,
    FireIgnite,
    /// `in_fire` damage of 1 (fire) or 2 (soul fire).
    InFire(f64),
    LavaIgnite,
    LavaHurt,
    Extinguish,
}

/// `Burning.plan/1`: each crossing step's operations in order.
pub fn plan(steps: &[Vec<Contact>]) -> Vec<Operation> {
    let mut out = Vec::new();
    for contacts in steps {
        let fire: Vec<f64> = contacts
            .iter()
            .filter_map(|c| match c {
                Contact::Fire => Some(1.0),
                Contact::SoulFire => Some(2.0),
                _ => None,
            })
            .collect();
        let lava = contacts.iter().filter(|c| **c == Contact::Lava).count();
        if !fire.is_empty() || lava > 0 {
            out.push(Operation::ClearFreeze);
        }
        if !fire.is_empty() {
            out.push(Operation::FireIgnite);
            out.extend(fire.into_iter().map(Operation::InFire));
        }
        if lava > 0 {
            out.push(Operation::LavaIgnite);
            out.extend(std::iter::repeat_n(Operation::LavaHurt, lava));
        }
        if contacts
            .iter()
            .any(|c| matches!(c, Contact::Water | Contact::PowderSnow))
        {
            out.push(Operation::Extinguish);
        }
    }
    out
}
