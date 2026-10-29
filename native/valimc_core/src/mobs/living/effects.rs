//! `Valimc.Living.Effects` as mobs use it: an instance is a priority stack
//! of rungs (the active one first, then strictly weaker suppressed ones);
//! refreshing merges a dose in, ticking runs durations down and promotes a
//! suppressed rung; instant and periodic effects request heals and hurts.

use super::super::model::{Effects, Health, Rung};
use super::f;
use super::facts::LivingFacts;

fn remaining(rung: &Rung) -> bool {
    rung.ticks == -1 || rung.ticks > 0
}

/// `shorter?(a, b)`: `a` ends before `b` (-1 is infinite).
fn shorter(a: &Rung, b: &Rung) -> bool {
    a.ticks != -1 && (b.ticks == -1 || a.ticks < b.ticks)
}

fn decrement(rung: &mut Rung) {
    if rung.ticks != -1 && rung.ticks != 0 {
        rung.ticks -= 1;
    }
}

/// `merge/2` (`MobEffectInstance.update`): the refreshed instance and
/// whether the client is told.
pub fn merge(instance: &[Rung], incoming: Rung) -> (Vec<Rung>, bool) {
    let head = instance[0];
    let rest = &instance[1..];
    let (ticks, level, tail, notify) = if incoming.amplifier > head.amplifier {
        let tail = if shorter(&incoming, &head) {
            instance.to_vec()
        } else {
            rest.to_vec()
        };
        (incoming.ticks, incoming.amplifier, tail, true)
    } else if shorter(&head, &incoming) && incoming.amplifier == head.amplifier {
        (incoming.ticks, head.amplifier, rest.to_vec(), true)
    } else if shorter(&head, &incoming) {
        let updated = if rest.is_empty() {
            vec![incoming]
        } else {
            merge(rest, incoming).0
        };
        (head.ticks, head.amplifier, updated, false)
    } else {
        (head.ticks, head.amplifier, rest.to_vec(), false)
    };
    let ambient_changed = notify || (head.ambient && !incoming.ambient);
    let ambient = if ambient_changed {
        incoming.ambient
    } else {
        head.ambient
    };
    let notify =
        ambient_changed || head.particles != incoming.particles || head.icon != incoming.icon;
    let mut out = Vec::with_capacity(tail.len() + 1);
    out.push(Rung {
        ticks,
        amplifier: level,
        ambient,
        particles: incoming.particles,
        icon: incoming.icon,
    });
    out.extend(tail);
    (out, notify)
}

/// `Effects.add/3`: refresh effect `id` with a one-rung dose; whether the
/// client is told.
pub fn add(effects: &mut Effects, id: i32, incoming: Rung) -> bool {
    match effects.0.binary_search_by_key(&id, |(k, _)| *k) {
        Ok(i) => {
            let (next, changed) = merge(&effects.0[i].1, incoming);
            effects.0[i].1 = next;
            changed
        }
        Err(i) => {
            effects.0.insert(i, (id, vec![incoming]));
            true
        }
    }
}

/// `Map.put(effects, id, instance)`.
pub fn put(effects: &mut Effects, id: i32, instance: Vec<Rung>) {
    match effects.0.binary_search_by_key(&id, |(k, _)| *k) {
        Ok(i) => effects.0[i].1 = instance,
        Err(i) => effects.0.insert(i, (id, instance)),
    }
}

/// `Map.delete(effects, id)`: whether it was there.
pub fn remove(effects: &mut Effects, id: i32) -> bool {
    match effects.0.binary_search_by_key(&id, |(k, _)| *k) {
        Ok(i) => {
            effects.0.remove(i);
            true
        }
        Err(_) => false,
    }
}

/// `tick_instance/1`: one tick; `(remains, promoted)`.
pub fn tick_instance(instance: &mut Vec<Rung>) -> (bool, bool) {
    if !remaining(&instance[0]) {
        return (false, false);
    }
    instance.iter_mut().for_each(decrement);
    let promoted = instance[0].ticks == 0 && instance.len() > 1;
    if promoted {
        instance.remove(0);
    }
    (remaining(&instance[0]), promoted)
}

/// `Effects.tick/1`: every duration runs down in id order, an ended effect
/// goes (its notifications are a player's).
pub fn tick(effects: &mut Effects) {
    effects
        .0
        .retain_mut(|(_, instance)| tick_instance(instance).0);
}

/// What an effect asks of its owner.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    None,
    Heal(f64),
    /// A hurt of a damage type.
    Hurt(u16, f64),
}

/// The native instantaneous amount: a signed int shift, plus 0.5 truncated,
/// as a float.
fn instant_amount(base: i32, amplifier: u8) -> f64 {
    let signed = base.wrapping_shl((amplifier & 31) as u32);
    f((signed as f64 + 0.5).trunc())
}

/// `Effects.instant/2` for instant health and damage.
pub fn instant(facts: &LivingFacts, id: i32, amplifier: u8) -> Action {
    if id == facts.effects.instant_health {
        Action::Heal(instant_amount(4, amplifier))
    } else if id == facts.effects.instant_damage {
        Action::Hurt(facts.damage.indirect_magic, instant_amount(6, amplifier))
    } else {
        Action::None
    }
}

/// `Effects.periodic/4`: a periodic effect's request from its active head,
/// before the duration runs down; `age` is `tickCount`.
pub fn periodic(
    facts: &LivingFacts,
    id: i32,
    instance: &[Rung],
    age: i64,
    health: &Health,
) -> Action {
    let e = &facts.effects;
    let head = instance[0];
    let phase = if head.ticks == -1 {
        age
    } else {
        head.ticks as i64
    };
    let period = if id == e.regeneration {
        50
    } else if id == e.poison {
        25
    } else if id == e.wither {
        40
    } else {
        return Action::None;
    };
    if head.ticks == 0 {
        return Action::None;
    }
    // JVM ishr masks the distance even for amplifiers 32..255.
    let period = (period as i64) >> (head.amplifier & 31);
    if !(period <= 0 || phase % period == 0) {
        return Action::None;
    }
    if id == e.regeneration {
        if health.value < health.maximum {
            Action::Heal(1.0)
        } else {
            Action::None
        }
    } else if id == e.poison {
        if health.value > 1.0 {
            Action::Hurt(facts.damage.magic, 1.0)
        } else {
            Action::None
        }
    } else {
        Action::Hurt(facts.damage.wither, 1.0)
    }
}

/// The periodic effects in the native action order (`periodic_ids/0`:
/// sorted ids).
pub fn periodic_ids(facts: &LivingFacts) -> [i32; 4] {
    let e = &facts.effects;
    let mut ids = [e.regeneration, e.hunger, e.poison, e.wither];
    ids.sort_unstable();
    ids
}
