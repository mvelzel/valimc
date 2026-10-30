//! A mob drinking (`Valimc.AI.Consume`, a wandering trader's potion and
//! milk): the `Consumable` of the item it uses. Every fourth tick after the
//! first fifth of its use it plays its consume sound (`onUseTick`,
//! `emitParticlesAndSounds`, whose volume and pitch draw on the mob's random
//! whatever the item); when its use is up it is consumed
//! (`finishUsingItem`): the sound again, a potion's effects added
//! (`PotionContents.onConsume`) or milk's clearing them, and its remainder
//! (a glass bottle, a bucket) in the hand. A family may play its own
//! consume sound (`Kind::consume_sound`, `OverrideConsumeSound`). Eating,
//! with its item particles, is not modelled for mobs (as in the Elixir).
//!
//! An item's consumable is its defaults (`FoodItems.defaults/1`, the facts'
//! `food`) unless the stack removes it; the consume listeners are the
//! defaults' not removed, with `minecraft:potion_contents` where the stack
//! carries one (`FoodItems.properties/1`). Mobs only drink the fixed stacks
//! their goals give them, which patch no consumable of their own.

use super::fmath::f;
use super::turn::Turn;
use crate::mobs::facts::{Consumable, MobFacts};
use crate::mobs::kinds::Kind;
use crate::mobs::living::{effects, items};
use crate::mobs::model::{Rung, Slot};
use crate::mobs::term::Value;

const POTION_CONTENTS: &str = "minecraft:potion_contents";

/// What `FoodItems.properties/1` gives of a stack: its consumable, its
/// remainder and its other consume listeners.
struct Properties<'a> {
    consumable: Option<&'a Consumable>,
    remainder: Option<(i32, i32)>,
    listeners: usize,
}

fn properties<'a>(facts: &'a MobFacts, stack: &Value) -> Option<Properties<'a>> {
    let id = items::item_id(stack)?;
    let defaults = facts.food.get(&id);
    let mut listeners = defaults.map_or(0, |d| {
        d.other_listeners
            .iter()
            .filter(|l| !items::removed(stack, l))
            .count()
    });
    let listed = defaults.is_some_and(|d| {
        d.other_listeners
            .iter()
            .any(|l| l == POTION_CONTENTS && !items::removed(stack, l))
    });
    if items::component(stack, POTION_CONTENTS).is_some() && !listed {
        listeners += 1;
    }
    let consumable = if items::removed(stack, "minecraft:consumable") {
        None
    } else {
        defaults.and_then(|d| d.consumable.as_ref())
    };
    let remainder = if items::removed(stack, "minecraft:use_remainder") {
        None
    } else {
        defaults.and_then(|d| d.remainder)
    };
    Some(Properties {
        consumable,
        remainder,
        listeners,
    })
}

/// `Consume.tick/4`: one tick of using `stack` in `slot` after `used` ticks
/// of use (its count already advanced): its sound, and its consumption when
/// its use is up.
pub fn tick(kind: &dyn Kind, t: &mut Turn, slot: Slot, stack: &Value, used: i32) {
    let facts = t.level.facts;
    let Some(props) = properties(facts, stack) else {
        return;
    };
    let Some(consumable) = props.consumable else {
        return;
    };
    let duration = consumable.ticks;
    if consumable.animation != "drink" || duration <= 0 {
        return;
    }
    let remaining = duration - used;
    if emits(duration, remaining) {
        sound(kind, t, consumable, stack);
    }
    if remaining - 1 == 0 {
        finish(kind, t, slot, stack, &props, consumable);
    }
}

/// `shouldEmitParticlesAndSounds`.
fn emits(duration: i32, remaining: i32) -> bool {
    let used = duration - remaining;
    used > (duration as f32 * 0.21875f32) as i32 && remaining % 4 == 0
}

/// `emitParticlesAndSounds`: an eat's volume and pitch, then a drink's, of
/// which a drink plays its own (0.5, 0.9 to 1.0).
fn sound(kind: &dyn Kind, t: &mut Turn, consumable: &Consumable, stack: &Value) {
    t.boolean();
    t.float();
    t.float();
    let c = t.float();
    let range = f(f(1.0) - f(0.9));
    let pitch = f(f(c * range) + f(0.9));
    let own = items::item_id(stack).and_then(|id| kind.consume_sound(id));
    match own {
        Some(id) => t.sound_id(id, 0.5, pitch),
        None => t.sound(&consumable.sound, 0.5, pitch),
    }
}

/// `Consumable.onConsume` and the use remainder in its hand
/// (`completeUsingItem`), then `stopUsingItem`.
fn finish(
    kind: &dyn Kind,
    t: &mut Turn,
    slot: Slot,
    stack: &Value,
    props: &Properties,
    consumable: &Consumable,
) {
    sound(kind, t, consumable, stack);
    let facts = t.level.facts;
    let living = &mut t.mob.body.mob.living;
    match items::component(stack, POTION_CONTENTS) {
        Some(contents) => {
            for (id, rung) in potion_effects(facts, contents) {
                effects::add(&mut living.effects, id, rung);
            }
        }
        // Milk (and every drink that only clears) clears them all; an item
        // with listeners takes its default potion contents' effects, which
        // no item's defaults hold.
        None if consumable.effects > 0 && props.listeners == 0 => {
            living.effects.0.clear();
        }
        None => {}
    }
    let remainder = props
        .remainder
        .map(|(id, count)| items::new_stack(id, count, None));
    t.mob.body.mob.equipment.set(slot, remainder);
    t.stop_using();
}

/// `PotionContents.effects/1` at scale 1: the potion's effects then its
/// own, each its first rung with its ticks scaled.
fn potion_effects(facts: &MobFacts, contents: &Value) -> Vec<(i32, Rung)> {
    let Some(map) = contents.as_map() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if let Some(potion) = map.get_atom("potion").and_then(Value::as_int) {
        if let Some(p) = facts.potions.get(potion as usize) {
            for (id, rungs) in &p.effects {
                if let Some(&rung) = rungs.first() {
                    out.push((*id, rung));
                }
            }
        }
    }
    if let Some(list) = map.get_atom("effects").and_then(Value::as_list) {
        for entry in list {
            if let Some(e) = custom_effect(entry) {
                out.push(e);
            }
        }
    }
    out.into_iter()
        .map(|(id, rung)| {
            (
                id,
                Rung {
                    ticks: scaled_ticks(rung.ticks),
                    ..rung
                },
            )
        })
        .collect()
}

// `{id, [{ticks, amplifier, ambient, particles, icon} | _]}`.
fn custom_effect(entry: &Value) -> Option<(i32, Rung)> {
    let [id, rungs] = entry.as_tuple()? else {
        return None;
    };
    let first = rungs.as_list()?.first()?.as_tuple()?;
    let [ticks, amplifier, ambient, particles, icon] = first else {
        return None;
    };
    Some((
        id.as_int()? as i32,
        Rung {
            ticks: ticks.as_int()? as i32,
            amplifier: amplifier.as_int()? as u8,
            ambient: ambient.as_bool()?,
            particles: particles.as_bool()?,
            icon: icon.as_bool()?,
        },
    ))
}

/// `scaled_ticks/2` at scale 1.0: infinite and none stay, other negatives
/// are 1, the rest through a float, floored, at least 1.
fn scaled_ticks(ticks: i32) -> i32 {
    match ticks {
        -1 | 0 => ticks,
        t if t < 0 => 1,
        t => ((t as f32) as f64).floor().max(1.0).min(i32::MAX as f64) as i32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_drink_sounds_every_fourth_tick_after_its_first_fifth() {
        // A 32-tick drink: from 8 ticks used, every fourth remaining.
        let sounded: Vec<i32> = (0..32).filter(|&u| emits(32, 32 - u)).collect();
        assert_eq!(sounded, vec![8, 12, 16, 20, 24, 28]);
    }

    #[test]
    fn potion_ticks_scale_as_floats() {
        assert_eq!(scaled_ticks(-1), -1);
        assert_eq!(scaled_ticks(0), 0);
        assert_eq!(scaled_ticks(-5), 1);
        assert_eq!(scaled_ticks(3600), 3600);
        assert_eq!(scaled_ticks(16_777_217), 16_777_216);
    }
}
